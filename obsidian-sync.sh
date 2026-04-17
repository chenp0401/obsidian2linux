#!/usr/bin/env bash
# ============================================================================
# obsidian-sync.sh
#   Obsidian 本地与云端一键同步工具（基于 Syncthing）
#   单脚本、交互式向导、傻瓜化部署
#
#   模块分层：
#     ui            —— 终端交互与彩色输出
#     ssh           —— 远程命令执行 / 文件读写
#     local         —— 本地 Mac 端 Syncthing 安装与管理
#     remote        —— 服务器端 Syncthing 部署与管理
#     syncthing_api —— Syncthing REST API 封装
#     state         —— 运行状态持久化（last-run.json）
#
#   使用：./obsidian-sync.sh
# ============================================================================

set -o pipefail
# 注意：不设置 set -e，脚本大量使用条件判断与错误返回码；错误通过 die() 主动退出

# ---------------------------------------------------------------------------
# 全局常量与运行时变量
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="obsidian-sync"
readonly SCRIPT_VERSION="0.1.0"
readonly STATE_DIR="${HOME}/.obsidian-sync"
readonly STATE_FILE="${STATE_DIR}/last-run.json"
readonly LOG_FILE="${STATE_DIR}/run.log"
readonly REMOTE_API_LOCAL_PORT="18384"
# 注意：以下两个 URL 会在运行时根据 Syncthing config.xml 中 tls 配置自动切换 http/https
LOCAL_API_URL="http://127.0.0.1:8384"
REMOTE_API_URL="http://127.0.0.1:${REMOTE_API_LOCAL_PORT}"
readonly DEFAULT_OBSIDIAN_ROOT="${HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents"
readonly DEFAULT_REMOTE_ROOT="/data/obsidian"

# 运行时敏感变量（将在 trap 中被 unset）
SSH_HOST=""
SSH_USER="root"
SSH_PORT="22"
SSH_PASS=""           # 敏感：仅内存驻留
REMOTE_API_KEY=""     # 敏感：从服务器 config.xml 读取
LOCAL_API_KEY=""      # 从本地 config.xml 读取
REMOTE_DEVICE_ID=""
LOCAL_DEVICE_ID=""
SSH_TUNNEL_PID=""     # 本地端口转发进程 PID
REMOTE_GUI_USER=""
REMOTE_GUI_PASS=""    # 敏感：仅会话展示一次

# 回滚栈：记录本次运行新增的设备/文件夹，失败时反向清理
ROLLBACK_STACK=()

# ---------------------------------------------------------------------------
# 模块：ui —— 彩色日志与交互
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_MAGENTA=$'\033[0;35m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_GRAY=$'\033[0;90m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_GRAY="" C_BOLD="" C_DIM="" C_RESET=""
fi

# 日志函数（对新手友好：符号 + 颜色一眼可辨）
#   ℹ 信息（蓝）   ✔ 成功（绿）   ⚠ 警告（黄）   ✘ 失败（红）   ▶ 步骤（青加粗）
log_info()    { printf "%s%sℹ%s  %s\n"         "$C_BOLD" "$C_BLUE"   "$C_RESET" "$*"; _log_to_file "INFO"  "$*"; }
log_ok()      { printf "%s%s✔%s  %s%s%s\n"     "$C_BOLD" "$C_GREEN"  "$C_RESET" "$C_GREEN"  "$*" "$C_RESET"; _log_to_file "OK"    "$*"; }
log_warn()    { printf "%s%s⚠%s  %s%s%s\n"     "$C_BOLD" "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$*" "$C_RESET" >&2; _log_to_file "WARN" "$*"; }
log_error()   { printf "%s%s✘%s  %s%s%s\n"     "$C_BOLD" "$C_RED"    "$C_RESET" "$C_RED"    "$*" "$C_RESET" >&2; _log_to_file "ERR"  "$*"; }
log_step()    { printf "\n%s%s▶  %s%s\n"       "$C_BOLD" "$C_CYAN"   "$*" "$C_RESET"; _log_to_file "STEP" "$*"; }
log_hint()    { printf "%s   ↳ %s%s\n"         "$C_GRAY" "$*" "$C_RESET"; }

_log_to_file() {
    # 追加到日志文件；不含任何密码
    local level="$1"; shift
    [[ -d "$STATE_DIR" ]] || return 0
    printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# 致命错误：输出原因并退出（触发 trap EXIT 清理）
die() {
    local reason="$*"
    log_error "$reason"
    # 如果回滚栈非空，询问是否回滚
    if (( ${#ROLLBACK_STACK[@]} > 0 )); then
        echo
        log_warn "本次运行已新增以下配置项："
        local item
        for item in "${ROLLBACK_STACK[@]}"; do
            log_warn "  - $item"
        done
        if confirm "是否回滚撤销上述配置？" "Y"; then
            do_rollback
        else
            log_warn "保留已新增配置，可手动在 Syncthing GUI 中清理。"
        fi
    fi
    # 尝试抓取服务器端 syncthing 日志片段（便于排障）
    _capture_remote_logs || true

    # 最终醒目复述：避免被上面的远端日志输出刷屏后用户找不到真正的错误原因
    printf "\n" >&2
    printf "%s%s╔══════════════════════════════════════════════════════════╗%s\n" "$C_BOLD" "$C_RED" "$C_RESET" >&2
    printf "%s%s║                  ✘  本  次  失  败                       ║%s\n" "$C_BOLD" "$C_RED" "$C_RESET" >&2
    printf "%s%s╚══════════════════════════════════════════════════════════╝%s\n" "$C_BOLD" "$C_RED" "$C_RESET" >&2
    printf "   %s失败原因%s：%s%s%s\n" "$C_GRAY" "$C_RESET" "$C_RED" "$reason" "$C_RESET" >&2
    if [[ -n "$LOG_FILE" ]]; then
        printf "   %s完整日志%s：%s\n" "$C_GRAY" "$C_RESET" "$LOG_FILE" >&2
    fi
    printf "   %s排障提示%s：如需跳过远端日志抓取，可设置 %sOBSIDIAN_SYNC_SKIP_REMOTE_LOG=1%s 重跑\n" \
        "$C_GRAY" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
    printf "\n" >&2

    exit 1
}

# 回滚：按与添加相反的顺序删除本次新增的 device / folder
do_rollback() {
    log_info "开始回滚..."
    local i
    for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
        local entry="${ROLLBACK_STACK[$i]}"
        local kind="${entry%%:*}"
        local id="${entry#*:}"
        case "$kind" in
            local_device)
                log_info "  删除本地设备：${id:0:14}..."
                local_api_call DELETE "/rest/config/devices/${id}" >/dev/null 2>&1 || \
                    log_warn "  本地设备删除失败：$id"
                ;;
            remote_device)
                log_info "  删除远端设备：${id:0:14}..."
                remote_api_call DELETE "/rest/config/devices/${id}" >/dev/null 2>&1 || \
                    log_warn "  远端设备删除失败：$id"
                ;;
            local_folder)
                log_info "  删除本地文件夹：$id"
                local_api_call DELETE "/rest/config/folders/${id}" >/dev/null 2>&1 || \
                    log_warn "  本地文件夹删除失败：$id"
                ;;
            remote_folder)
                log_info "  删除远端文件夹：$id"
                remote_api_call DELETE "/rest/config/folders/${id}" >/dev/null 2>&1 || \
                    log_warn "  远端文件夹删除失败：$id"
                ;;
        esac
    done
    ROLLBACK_STACK=()
    log_ok "回滚完成"
}

# 失败时抓取服务器端 Syncthing 日志末尾以协助排障
_capture_remote_logs() {
    [[ -n "$SSH_HOST" && -n "$SSH_PASS" && -n "$REMOTE_RUN_USER" ]] || return 0
    # 允许用户用环境变量跳过远端日志抓取（排障/快速失败场景）
    if [[ "${OBSIDIAN_SYNC_SKIP_REMOTE_LOG:-0}" == "1" ]]; then
        log_warn "已设置 OBSIDIAN_SYNC_SKIP_REMOTE_LOG=1，跳过远端日志抓取"
        return 0
    fi
    log_info "抓取远端 Syncthing 日志末尾 30 行以供排障（最多等待 15s）..."
    local script="sudo_cmd=\"\"; [ \"\$(id -u)\" -ne 0 ] && sudo_cmd=\"sudo\"
\$sudo_cmd journalctl -u 'syncthing@${REMOTE_RUN_USER}.service' -n 30 --no-pager 2>/dev/null || echo '(journalctl 不可用)'"
    # 选择 timeout 命令（macOS 原生无 timeout，需 brew install coreutils 提供 gtimeout）
    local _to_cmd=""
    if command -v gtimeout >/dev/null 2>&1; then _to_cmd="gtimeout 15"
    elif command -v timeout  >/dev/null 2>&1; then _to_cmd="timeout 15"
    fi
    # 用独立的短超时 SSH 选项调用（不走 ControlMaster 复用，避免前一条 SSH 半死状态影响本次）
    local _tmp_log
    _tmp_log="$(mktemp -t obsidian-sync-remote-log.XXXXXX 2>/dev/null || echo "/tmp/obsidian-sync-remote-log.$$")"
    (
        SSHPASS="$SSH_PASS" $_to_cmd sshpass -e ssh \
            -o BatchMode=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o GSSAPIAuthentication=no \
            -o PreferredAuthentications=password,keyboard-interactive \
            -o PubkeyAuthentication=no \
            -o ConnectTimeout=8 \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=2 \
            -o LogLevel=ERROR \
            -p "$SSH_PORT" \
            "${SSH_USER}@${SSH_HOST}" "bash -s" <<< "$script"
    ) >"$_tmp_log" 2>/dev/null || true
    if [[ -s "$_tmp_log" ]]; then
        while IFS= read -r line; do
            printf "    %s%s%s\n" "$C_YELLOW" "$line" "$C_RESET" >&2
        done < "$_tmp_log"
    else
        log_warn "远端日志抓取超时或无输出（已忽略，不影响排障主流程）"
    fi
    rm -f "$_tmp_log" 2>/dev/null || true
    return 0
}

# 交互：y/N 确认，默认 N
confirm() {
    local prompt="${1:-是否继续？}"
    local default="${2:-N}"
    local hint="[y/N]"
    [[ "$default" == "Y" ]] && hint="[Y/n]"
    local reply

    # 把提示打印到 stdout（某些终端/IDE 环境会把 stderr 缓冲或隐藏，放 stdout 更稳）
    # 使用 printf 不带换行，read 接在同一行读输入。
    printf "%s%s?%s %s%s%s %s%s%s " \
        "$C_BOLD" "$C_MAGENTA" "$C_RESET" \
        "$C_BOLD" "$prompt" "$C_RESET" \
        "$C_GRAY" "$hint" "$C_RESET"

    # 读取策略：
    #   1) 如果 stdin 本身就是终端（正常交互），直接从 stdin 读；
    #   2) 否则（stdin 被管道/重定向接管）回退到 /dev/tty；
    #   3) 以上两条路都行不通，按默认值处理，并额外提示用户。
    if [[ -t 0 ]]; then
        IFS= read -r reply || reply=""
    elif [[ -r /dev/tty ]]; then
        IFS= read -r reply < /dev/tty || reply=""
    else
        reply=""
        printf "\n%s%s⚠ 未检测到可交互终端，按默认值 [%s] 继续%s\n" \
            "$C_BOLD" "$C_YELLOW" "$default" "$C_RESET"
    fi
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

# 交互：带默认值的普通读取
read_with_default() {
    local prompt="$1"
    local default="$2"
    local var
    if ! read -r -p "$(printf "%s%s?%s %s %s[默认 %s]%s: " \
            "$C_BOLD" "$C_MAGENTA" "$C_RESET" \
            "$prompt" \
            "$C_GRAY" "$default" "$C_RESET")" var; then
        # stdin 已关闭（EOF），非交互环境下直接终止，避免调用方死循环
        printf "\n" >&2
        die "读取输入失败：stdin 已关闭（非交互环境）。请在终端中直接运行本脚本。"
    fi
    echo "${var:-$default}"
}

# 交互：静默读取密码（不回显）
read_password() {
    local prompt="${1:-请输入密码}"
    local var
    printf "%s%s?%s %s %s(输入时不会显示)%s: " \
        "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$prompt" "$C_GRAY" "$C_RESET" >&2
    if ! read -r -s var; then
        printf "\n" >&2
        die "读取密码失败：stdin 已关闭（非交互环境）。请在终端中直接运行本脚本。"
    fi
    printf "\n" >&2
    echo "$var"
}

# ---------------------------------------------------------------------------
# 模块：依赖检查
# ---------------------------------------------------------------------------
# 检测命令是否存在
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 返回缺失依赖的可读安装指引（Mac 环境）
check_dependencies() {
    log_step "检查本地依赖"
    local missing=()
    local required=("ssh" "curl")
    local optional=("sshpass:非交互式 SSH 密码登录" "jq:JSON 解析" "fzf:目录多选 TUI")

    for c in "${required[@]}"; do
        if has_cmd "$c"; then
            log_ok  "已安装：$c"
        else
            log_error "缺少必需依赖：$c"
            missing+=("$c")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "请先安装缺失的必需依赖后再重试。"
    fi

    for item in "${optional[@]}"; do
        local c="${item%%:*}"
        local desc="${item##*:}"
        if has_cmd "$c"; then
            log_ok  "已安装：${c}（${desc}）"
        else
            log_warn "未检测到 ${c}（${desc}）"
            case "$c" in
                sshpass) log_warn "  → 安装命令：brew install hudochenkov/sshpass/sshpass" ;;
                jq)      log_warn "  → 安装命令：brew install jq" ;;
                fzf)     log_warn "  → 安装命令：brew install fzf" ;;
            esac
        fi
    done

    # sshpass 是密码登录必需的；此处给出强提示
    if ! has_cmd sshpass; then
        log_warn "sshpass 未安装 —— 脚本将无法自动使用密码登录 SSH。"
        if ! confirm "是否继续？（继续则后续 SSH 操作会卡在密码交互）" "N"; then
            die "请先安装 sshpass 后重试。"
        fi
    fi
    if ! has_cmd jq; then
        log_warn "jq 未安装 —— 将使用降级的文本解析，建议安装。"
    fi

    # fzf 可选：主动询问用户是否现在安装，提升后续多选体验
    if ! has_cmd fzf && has_cmd brew; then
        if confirm "是否现在自动执行 'brew install fzf' 以获得更好的多选体验？" "Y"; then
            if brew install fzf; then
                log_ok "fzf 安装完成"
            else
                log_warn "fzf 安装失败，将使用降级菜单（一次输入多个编号，空格分隔）"
            fi
        else
            log_info "跳过安装 fzf，后续将使用降级菜单（一次输入多个编号，空格分隔）"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 模块：通用 curl 封装（带超时与重试）
# ---------------------------------------------------------------------------
# http_call METHOD URL [API_KEY] [BODY_FILE]
#   输出 HTTP BODY 到 stdout；返回 HTTP 状态码到 stderr 无；非 2xx 返回非零
http_call() {
    local method="$1" url="$2" api_key="${3:-}" body_file="${4:-}"
    local tmp_body; tmp_body="$(mktemp)"
    # -k 允许自签证书；-L 跟随重定向（Syncthing 开启 tls 时 http 会 307 → https）
    local -a args=(-sS -k -L --connect-timeout 5 --max-time 30 \
                   -o "$tmp_body" -w '%{http_code}' -X "$method" "$url")
    [[ -n "$api_key" ]] && args+=(-H "X-API-Key: $api_key")
    [[ -n "$body_file" ]] && args+=(-H "Content-Type: application/json" --data-binary "@$body_file")

    local http_code
    local attempt=0
    while (( attempt < 3 )); do
        http_code="$(curl "${args[@]}" 2>/dev/null || echo "000")"
        if [[ "$http_code" =~ ^2 ]]; then
            cat "$tmp_body"
            rm -f "$tmp_body"
            return 0
        fi
        ((attempt++))
        sleep 1
    done
    log_error "HTTP $method $url 失败（状态码：${http_code}）"
    [[ -s "$tmp_body" ]] && log_error "响应：$(head -c 300 "$tmp_body")"
    rm -f "$tmp_body"
    return 1
}


# ---------------------------------------------------------------------------
# 模块：信号清理
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    # 关闭 SSH 端口转发
    if [[ -n "$SSH_TUNNEL_PID" ]] && kill -0 "$SSH_TUNNEL_PID" 2>/dev/null; then
        kill "$SSH_TUNNEL_PID" 2>/dev/null || true
        log_info "已关闭 SSH 端口转发（PID=${SSH_TUNNEL_PID}）"
    fi
    # 兜底：按端口/模式清理任何残留隧道
    pkill -f "ssh.*-L ${REMOTE_API_LOCAL_PORT}:127.0.0.1:8384" 2>/dev/null || true

    # 写 checkpoint（仅当已开始部署时）
    if [[ -n "$SSH_HOST" ]]; then
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        local cp="${STATE_DIR}/checkpoint.json"
        cat > "$cp" 2>/dev/null <<JSON
{
  "host": "${SSH_HOST}",
  "user": "${SSH_USER}",
  "port": ${SSH_PORT:-22},
  "exitCode": ${exit_code},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "rollbackPending": $([ ${#ROLLBACK_STACK[@]} -gt 0 ] && echo true || echo false)
}
JSON
        chmod 600 "$cp" 2>/dev/null || true
    fi

    # 清除敏感变量
    SSH_PASS=""
    REMOTE_API_KEY=""
    REMOTE_GUI_PASS=""
    unset SSH_PASS REMOTE_API_KEY REMOTE_GUI_PASS
    # 清除可能残留的 bash history（仅当前会话）
    history -c 2>/dev/null || true
    exit "$exit_code"
}
on_interrupt() {
    echo
    log_warn "收到中断信号，正在清理..."
    exit 130
}
trap cleanup EXIT
trap on_interrupt INT TERM

# ---------------------------------------------------------------------------
# 模块：ssh —— 远程命令执行 / 连通性校验
# ---------------------------------------------------------------------------
# SSH ControlMaster 相关的进程级临时资源
#   - 强制使用 /tmp 下短路径，规避 unix socket 路径长度限制（macOS ~104 字节）
#     注意：macOS 上 $TMPDIR 指向 /var/folders/../T/（80+ 字节），叠加 PID 和 %r@%h:%p 后会越界，
#     因此这里**不使用** $TMPDIR，而是直接写死 /tmp，再用 6 位随机后缀避免并发冲突。
#     文件名也改用 cm-%h.%p（不含用户名与 %C 长哈希），即使 ssh 再加随机后缀也远低于上限。
#   - 同一次脚本运行内复用一条 TCP 长连接，大幅缩短后续命令的握手耗时
SSH_CTRL_DIR="/tmp/obs-$(printf '%s' "$$-$(date +%s)" | shasum | cut -c1-6)"
SSH_CTRL_PATH="${SSH_CTRL_DIR}/cm-%h.%p"
SSH_KNOWN_HOSTS="${SSH_CTRL_DIR}/kh"
mkdir -p "${SSH_CTRL_DIR}" 2>/dev/null || true
chmod 700 "${SSH_CTRL_DIR}" 2>/dev/null || true
# 退出时自动清理（与已有 trap 协同：on_interrupt 会被保留，这里单独注册 EXIT）
_cleanup_ssh_ctrl() {
    # 关掉所有活跃的 master 连接
    if [[ -d "${SSH_CTRL_DIR}" ]]; then
        for sock in "${SSH_CTRL_DIR}"/cm-*; do
            [[ -S "$sock" ]] || continue
            ssh -o ControlPath="$sock" -O exit _ 2>/dev/null || true
        done
        rm -rf "${SSH_CTRL_DIR}" 2>/dev/null || true
    fi
}
trap _cleanup_ssh_ctrl EXIT

# SSH 基础选项（禁用交互、禁用 GSSAPI、60s 超时、首次自动信任、连接复用）
#   关键点：
#   - ConnectTimeout=60 覆盖大多数服务器的 sshd DNS/GSSAPI 等待窗口
#   - GSSAPIAuthentication=no 客户端不发起 GSSAPI，避免服务器端做 Kerberos 反查
#   - ControlMaster=auto + ControlPersist=10m 首次慢、后续所有命令秒连
#   - UserKnownHostsFile 指向临时目录，避免污染用户 ~/.ssh/known_hosts
_ssh_base_opts() {
    echo "-o BatchMode=no \
-o ConnectTimeout=60 \
-o ServerAliveInterval=15 \
-o ServerAliveCountMax=6 \
-o StrictHostKeyChecking=accept-new \
-o UserKnownHostsFile=${SSH_KNOWN_HOSTS} \
-o GSSAPIAuthentication=no \
-o PreferredAuthentications=password,keyboard-interactive \
-o PubkeyAuthentication=no \
-o ControlMaster=auto \
-o ControlPath=${SSH_CTRL_PATH} \
-o ControlPersist=10m \
-o LogLevel=ERROR \
-p ${SSH_PORT}"
}

# ssh_exec "remote command"
#   使用 SSH_PASS 非交互式执行远程命令，stdout/stderr 透传
ssh_exec() {
    local cmd="$1"
    if ! has_cmd sshpass; then
        die "未安装 sshpass，无法非交互登录。请先 brew install hudochenkov/sshpass/sshpass"
    fi
    # shellcheck disable=SC2086
    SSHPASS="$SSH_PASS" sshpass -e ssh $(_ssh_base_opts) "${SSH_USER}@${SSH_HOST}" "$cmd"
}

# ssh_exec_quiet "remote command"  —— 丢弃 stderr，仅返回 stdout 与退出码
ssh_exec_quiet() {
    local cmd="$1"
    # shellcheck disable=SC2086
    SSHPASS="$SSH_PASS" sshpass -e ssh $(_ssh_base_opts) "${SSH_USER}@${SSH_HOST}" "$cmd" 2>/dev/null
}

# IP / 域名格式校验
#   支持 IPv4 四段、或由字母数字+点+连字符组成的合法域名
validate_host() {
    local h="$1"
    [[ -z "$h" ]] && return 1
    # IPv4
    if [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'; local -a parts=($h)
        for p in "${parts[@]}"; do
            (( p >= 0 && p <= 255 )) || return 1
        done
        return 0
    fi
    # 显式拒绝"看起来像 IP 但不完整"的形式（纯数字 + 点，但段数不对）
    if [[ "$h" =~ ^[0-9.]+$ ]]; then
        return 1
    fi
    # 域名（最后一段必须含字母）
    if [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
        # 拒绝最后一段 TLD 为纯数字
        local tld="${h##*.}"
        [[ "$tld" =~ ^[0-9]+$ ]] && return 1
        return 0
    fi
    return 1
}

# SSH 连通性三段探测：网络 → 端口 → 认证
#   返回 0 成功；非零失败（已打印原因）
#   慢连接友好提示：握手持续超过 20 秒时，自动打印 sshd 慢响应说明，避免用户以为卡死
ssh_probe() {
    # 1) 端口可达性（不走 nc，统一用 bash /dev/tcp，免外部依赖）
    if ! (exec 3<>"/dev/tcp/${SSH_HOST}/${SSH_PORT}") 2>/dev/null; then
        log_error "无法连接到 ${SSH_HOST}:${SSH_PORT}（网络不通或端口关闭）"
        return 2
    fi
    exec 3<&- 3>&- 2>/dev/null || true

    # 2) 认证 + 执行一条无害命令（带慢连接提示）
    local probe_out_file; probe_out_file="$(mktemp -t obsidian-sync-probe.XXXXXX)"

    # 后台真正发起 SSH 握手
    (
        # shellcheck disable=SC2086
        SSHPASS="$SSH_PASS" sshpass -e ssh $(_ssh_base_opts) \
            "${SSH_USER}@${SSH_HOST}" 'echo __OBSIDIAN_SYNC_PROBE_OK__' >"$probe_out_file" 2>&1
        echo $? >>"$probe_out_file.rc"
    ) &
    local probe_pid=$!

    # 前台等待：20 秒仍未完成，则打印慢连接提示；最长再等 40 秒（合计 60s，与 ConnectTimeout 对齐）
    local waited=0
    local warned=0
    while kill -0 "$probe_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if (( waited == 20 && warned == 0 )); then
            log_warn "服务器响应较慢（sshd 可能在做 DNS 反查 / GSSAPI 等待），这是正常现象，请继续等待..."
            warned=1
        fi
        if (( waited >= 60 )); then
            break
        fi
    done
    # 若仍未结束（极少数情况，底层 ssh 没被 ConnectTimeout 杀掉），主动终止
    if kill -0 "$probe_pid" 2>/dev/null; then
        kill -TERM "$probe_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$probe_pid" 2>/dev/null || true
    fi
    wait "$probe_pid" 2>/dev/null || true

    local out rc
    out="$(cat "$probe_out_file" 2>/dev/null)"
    rc="$(cat "${probe_out_file}.rc" 2>/dev/null | tail -1)"
    rm -f "$probe_out_file" "${probe_out_file}.rc" 2>/dev/null || true
    [[ -z "$rc" ]] && rc=124  # 超时未回收到 rc

    if [[ "$rc" == "0" && "$out" == *"__OBSIDIAN_SYNC_PROBE_OK__"* ]]; then
        return 0
    fi

    # 分类错误
    if echo "$out" | grep -qiE 'permission denied|authentication failed'; then
        log_error "SSH 认证失败：用户名或密码错误"
        return 3
    elif echo "$out" | grep -qiE 'connection refused'; then
        log_error "SSH 连接被拒绝（端口 ${SSH_PORT} 未开放 sshd？）"
        return 4
    elif echo "$out" | grep -qiE 'banner exchange|kex_exchange_identification'; then
        log_error "SSH 握手超时（服务器 sshd 响应过慢或中间链路异常）"
        log_error "建议稍后重试；若持续存在，可联系服务器管理员检查 sshd 的 UseDNS / GSSAPIAuthentication 配置"
        return 5
    elif echo "$out" | grep -qiE 'connection timed out|timed out'; then
        log_error "SSH 连接超时（网络或防火墙问题）"
        return 5
    else
        log_error "SSH 探测失败："
        log_error "$(echo "$out" | head -5)"
        return 6
    fi
}

# ---------------------------------------------------------------------------
# 加载/保存上次的 SSH 连接配置（便于二次运行免输入）
# ---------------------------------------------------------------------------
# 从 last-run.json 回填 host/user/port 作为默认值
_load_last_ssh_config() {
    [[ -f "$STATE_FILE" ]] || return 0
    has_cmd jq || return 0
    local h u p
    h="$(jq -r '.server.host // ""' "$STATE_FILE" 2>/dev/null)"
    u="$(jq -r '.server.user // ""' "$STATE_FILE" 2>/dev/null)"
    p="$(jq -r '.server.port // ""' "$STATE_FILE" 2>/dev/null)"
    [[ -n "$h" ]] && SSH_HOST="$h"
    [[ -n "$u" ]] && SSH_USER="$u"
    [[ -n "$p" && "$p" != "null" ]] && SSH_PORT="$p"
    if [[ -n "$SSH_HOST" ]]; then
        log_info "已从上次运行记录加载：${SSH_USER}@${SSH_HOST}:${SSH_PORT}（直接回车即可复用）"
    fi
}

# macOS 钥匙串：保存 SSH 密码（系统级加密，仅当前用户可读）
# service = obsidian-sync-ssh，account = user@host:port
_keychain_service() { echo "obsidian-sync-ssh"; }
_keychain_account() { echo "${SSH_USER}@${SSH_HOST}:${SSH_PORT}"; }

_keychain_get_pass() {
    has_cmd security || return 1
    security find-generic-password -a "$(_keychain_account)" -s "$(_keychain_service)" -w 2>/dev/null
}

_keychain_set_pass() {
    has_cmd security || return 1
    # -U 表示更新已存在的条目
    security add-generic-password -a "$(_keychain_account)" -s "$(_keychain_service)" -w "$SSH_PASS" -U 2>/dev/null
}

_keychain_delete_pass() {
    has_cmd security || return 1
    security delete-generic-password -a "$(_keychain_account)" -s "$(_keychain_service)" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 主流程子步骤：采集用户输入并探测 SSH
# ---------------------------------------------------------------------------
collect_user_input() {
    log_step "步骤 1/8 ：采集服务器连接信息"

    # 从上次运行记录回填 host/user/port，并尝试从钥匙串取回密码
    _load_last_ssh_config
    local pass_from_keychain=""
    if [[ -n "$SSH_HOST" ]] && pass_from_keychain="$(_keychain_get_pass)" && [[ -n "$pass_from_keychain" ]]; then
        log_info "已从 macOS 钥匙串读取到 ${SSH_USER}@${SSH_HOST} 的密码（如需更换请按 Ctrl+C 重运行并选择更改）"
    fi

    local max_retry=3
    local attempt=0
    while (( attempt < max_retry )); do
        ((attempt++))

        # IP / 域名（内层最多重试 5 次，避免反复输错格式时刷屏死循环）
        local host_try=0
        local host_max=5
        while (( host_try < host_max )); do
            ((host_try++))
            SSH_HOST="$(read_with_default "服务器 IP 或域名" "${SSH_HOST}")"
            if [[ -z "$SSH_HOST" ]]; then
                log_warn "请输入服务器地址"
                continue
            fi
            if validate_host "$SSH_HOST"; then
                break
            else
                log_warn "地址格式不合法，请重新输入（示例：192.168.1.10 或 example.com）"
            fi
        done
        if [[ -z "$SSH_HOST" ]] || ! validate_host "$SSH_HOST"; then
            die "服务器地址输入无效已超过 ${host_max} 次，退出。"
        fi

        # SSH 用户名（改用内联 read 以获得自定义的提示样式）
        local _ssh_user_default="${SSH_USER:-root}"
        local _ssh_port_default="${SSH_PORT:-22}"
        local _in
        if ! read -r -p "$(printf "SSH 用户名 [默认为 %s，如未修改，按 Enter 跳过]: " "$_ssh_user_default")" _in; then
            printf "\n" >&2
            die "读取输入失败：stdin 已关闭（非交互环境）。请在终端中直接运行本脚本。"
        fi
        SSH_USER="${_in:-$_ssh_user_default}"

        if ! read -r -p "$(printf "SSH 端口 [默认为 %s，如未修改，按 Enter 跳过]: " "$_ssh_port_default")" _in; then
            printf "\n" >&2
            die "读取输入失败：stdin 已关闭（非交互环境）。请在终端中直接运行本脚本。"
        fi
        SSH_PORT="${_in:-$_ssh_port_default}"
        if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
            log_warn "端口不合法，使用默认 22"
            SSH_PORT=22
        fi
        # 密码：若钥匙串有缓存且与当前 user@host:port 匹配，提示用户是否复用
        local use_cached=0
        if [[ -n "$pass_from_keychain" ]]; then
            if confirm "检测到已保存的密码，直接使用？" "Y"; then
                SSH_PASS="$pass_from_keychain"
                use_cached=1
            fi
        fi
        if (( use_cached == 0 )); then
            SSH_PASS="$(read_password "SSH 密码")"
            if [[ -z "$SSH_PASS" ]]; then
                log_warn "密码不能为空"
                continue
            fi
        fi

        log_info "正在探测 SSH 连通性（首次握手最长 60 秒，请耐心等待）..."
        if ssh_probe; then
            log_ok "SSH 连接成功：${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
            # 新密码验证通过后，自动保存到 macOS 钥匙串（系统级加密，仅当前用户可读）
            # 如需清除：security delete-generic-password -s obsidian-sync-ssh
            if (( use_cached == 0 )) && has_cmd security; then
                if _keychain_set_pass; then
                    log_ok "密码已加密保存到钥匙串（service=obsidian-sync-ssh）"
                else
                    log_warn "保存到钥匙串失败（可继续使用，仅影响下次免输入）"
                fi
            fi
            return 0
        fi
        # 探测失败：如果这次用的是缓存密码，可能已失效，清掉让用户重新输入
        if (( use_cached == 1 )); then
            log_warn "使用缓存密码连接失败，可能密码已变更，下次将重新询问"
            _keychain_delete_pass
            pass_from_keychain=""
        fi

        # SSH 探测失败：提示用户手动在云服务商控制台放行端口
        printf "\n"
        printf "%s⚠ SSH 连接失败，可能是云服务器防火墙未放行 22 端口。%s\n" "$C_YELLOW" "$C_RESET"
        printf "\n%s请在云服务商控制台放行以下端口到你的本机公网 IP（或 0.0.0.0/0）后再重试：%s\n" "$C_BOLD" "$C_RESET"
        printf "  %s• 22/tcp%s       —— SSH 登录\n"       "$C_CYAN" "$C_RESET"
        printf "  %s• 8384/tcp%s     —— Syncthing Web UI（仅当需要直连远端 UI 时）\n" "$C_CYAN" "$C_RESET"
        printf "  %s• 22000/tcp%s    —— Syncthing 同步（TCP）\n" "$C_CYAN" "$C_RESET"
        printf "  %s• 22000/udp%s    —— Syncthing 同步（QUIC）\n" "$C_CYAN" "$C_RESET"
        printf "  %s• 21027/udp%s    —— Syncthing 局域网发现\n\n" "$C_CYAN" "$C_RESET"
        printf "%s腾讯云控制台参考入口：%s\n" "$C_BOLD" "$C_RESET"
        printf "  • CVM 安全组：     https://console.cloud.tencent.com/cvm/securitygroup\n"
        printf "  • 轻量应用防火墙： https://console.cloud.tencent.com/lighthouse/instance/index\n\n"

        if (( attempt < max_retry )); then
            if ! confirm "放行后是否重新输入连接信息并重试？" "Y"; then
                die "用户取消输入。"
            fi
        fi
    done
    die "已达到最大重试次数（${max_retry}），请在云控制台放行 22 端口后重试。"
}

# ---------------------------------------------------------------------------
# 模块：remote —— 服务器端部署
# ---------------------------------------------------------------------------
# 远程 Syncthing 运行用户（默认复用 SSH 登录用户，root 登录时强烈建议改为专用账号
# 但在"傻瓜化"前提下，这里直接使用登录用户，由用户自行感知）
REMOTE_RUN_USER=""
REMOTE_HOME=""
REMOTE_CONFIG_DIR=""
REMOTE_CONFIG_XML=""

# 下发一个 heredoc 形式的远程 bash 脚本并执行，保留标准输出
ssh_exec_script() {
    local script="$1"
    # shellcheck disable=SC2086
    SSHPASS="$SSH_PASS" sshpass -e ssh $(_ssh_base_opts) \
        "${SSH_USER}@${SSH_HOST}" "bash -s" <<< "$script"
}

# 探测服务器基本信息：发行版、Syncthing 是否已安装
_remote_probe_env() {
    local script='
set -e
. /etc/os-release 2>/dev/null || true
ID_LIKE_STR="${ID_LIKE:-}"
printf "OS_ID=%s\n"        "${ID:-unknown}"
printf "OS_LIKE=%s\n"      "$ID_LIKE_STR"
printf "VERSION_ID=%s\n"   "${VERSION_ID:-unknown}"
if command -v apt-get >/dev/null 2>&1; then printf "PKG_MGR=apt\n"
elif command -v dnf >/dev/null 2>&1; then   printf "PKG_MGR=dnf\n"
elif command -v yum >/dev/null 2>&1; then   printf "PKG_MGR=yum\n"
else                                        printf "PKG_MGR=unknown\n"
fi
if command -v syncthing >/dev/null 2>&1; then
    printf "SYNCTHING_INSTALLED=1\n"
    printf "SYNCTHING_VERSION=%s\n" "$(syncthing --version 2>/dev/null | head -1 | awk "{print \$2}")"
else
    printf "SYNCTHING_INSTALLED=0\n"
fi
printf "WHOAMI=%s\n"       "$(whoami)"
printf "HOME=%s\n"         "$HOME"
printf "HAS_SYSTEMD=%s\n"  "$(command -v systemctl >/dev/null 2>&1 && echo 1 || echo 0)"
'
    ssh_exec_script "$script"
}

# 远程安装 Syncthing
# 策略：统一从 syncthing GitHub releases 下载 v2.x 官方 Linux 二进制安装，
#      不再走 apt.syncthing.net / dnf repo —— 因为这些渠道的 stable 通道
#      当前仍提供 v1.x，会和本地 Mac 的 v2.x 客户端产生协议不兼容。
_remote_install_syncthing() {
    local pkg_mgr="$1"
    log_info "使用 GitHub release 二进制方式安装 Syncthing（保证 v2.x 与本地 Mac 兼容）..."

    local install_script='
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"

# 1) 如果已经装了 syncthing 且版本为 v2.x，直接跳过；否则先卸载旧版本
if command -v syncthing >/dev/null 2>&1; then
    cur_ver="$(syncthing --version 2>/dev/null | head -1 | awk "{print \$2}")"
    cur_major="${cur_ver#v}"; cur_major="${cur_major%%.*}"
    if [ -n "$cur_major" ] && [ "$cur_major" -ge 2 ] 2>/dev/null; then
        echo "syncthing already >= v2.x ($cur_ver)，跳过"
        exit 0
    fi
    echo "卸载旧版 syncthing ($cur_ver)..."
    # 停服务（忽略失败）
    $sudo_cmd systemctl stop "syncthing@*" 2>/dev/null || true
    pkill -9 -f "syncthing serve" 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1 && dpkg -l syncthing 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get purge -y syncthing syncthing-discosrv syncthing-relaysrv 2>&1 | tail -3 || true
        $sudo_cmd rm -f /etc/apt/sources.list.d/syncthing*.list \
                        /etc/apt/keyrings/syncthing-archive-keyring.gpg \
                        /etc/apt/keyrings/syncthing-archive-keyring.asc
    elif command -v dnf >/dev/null 2>&1 && dnf list installed syncthing >/dev/null 2>&1; then
        $sudo_cmd dnf remove -y syncthing || true
        $sudo_cmd rm -f /etc/yum.repos.d/syncthing.repo
    elif command -v yum >/dev/null 2>&1 && yum list installed syncthing >/dev/null 2>&1; then
        $sudo_cmd yum remove -y syncthing || true
        $sudo_cmd rm -f /etc/yum.repos.d/syncthing.repo
    fi
    $sudo_cmd rm -f /usr/bin/syncthing /usr/local/bin/syncthing
fi

# 2) 确保有依赖工具
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y -q curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    $sudo_cmd dnf install -y curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
    $sudo_cmd yum install -y curl tar ca-certificates >/dev/null 2>&1 || true
fi

# 3) 识别架构
uname_m="$(uname -m)"
case "$uname_m" in
    x86_64|amd64)   arch="amd64" ;;
    aarch64|arm64)  arch="arm64" ;;
    armv7l|armv7*)  arch="arm" ;;
    i386|i686)      arch="386" ;;
    *) echo "ERROR: 不支持的 CPU 架构：$uname_m" >&2; exit 1 ;;
esac

# 4) 查询 GitHub 最新 v2.x 版本号（若 API 不可用，降级用固定已知版本）
latest_tag=""
if command -v curl >/dev/null 2>&1; then
    latest_tag="$(curl -fsSL --max-time 15 https://api.github.com/repos/syncthing/syncthing/releases/latest 2>/dev/null \
                  | grep -oE "\"tag_name\"[[:space:]]*:[[:space:]]*\"v[^\"]+\"" \
                  | head -1 \
                  | sed -E "s/.*\"(v[^\"]+)\".*/\\1/")"
fi
if [ -z "$latest_tag" ]; then
    latest_tag="v2.0.16"
    echo "WARN: 无法从 GitHub API 获取最新版本号，回退使用 $latest_tag"
fi
echo "将安装 Syncthing $latest_tag ($arch)"

# 5) 下载 tarball
tmpdir="$(mktemp -d)"
tarball="syncthing-linux-${arch}-${latest_tag}.tar.gz"
url="https://github.com/syncthing/syncthing/releases/download/${latest_tag}/${tarball}"
echo "下载：$url"
if ! curl -fsSL --max-time 180 -o "$tmpdir/$tarball" "$url"; then
    # 国内服务器直连 GitHub 可能慢/失败，尝试 ghproxy 镜像
    echo "WARN: 直连 GitHub 失败，尝试镜像 ghproxy..."
    if ! curl -fsSL --max-time 180 -o "$tmpdir/$tarball" "https://ghproxy.com/$url"; then
        rm -rf "$tmpdir"
        echo "ERROR: 从 GitHub 及镜像下载均失败" >&2
        exit 1
    fi
fi

# 6) 解压 + 安装
cd "$tmpdir"
tar xzf "$tarball"
extracted_dir="$(find . -maxdepth 1 -type d -name "syncthing-linux-*" | head -1)"
if [ -z "$extracted_dir" ] || [ ! -x "$extracted_dir/syncthing" ]; then
    echo "ERROR: tarball 解压后未找到 syncthing 二进制" >&2
    rm -rf "$tmpdir"
    exit 1
fi
$sudo_cmd install -m 0755 "$extracted_dir/syncthing" /usr/local/bin/syncthing
# 让 /usr/bin 下也能找到（有些 systemd unit 硬编码 /usr/bin/syncthing）
[ -e /usr/bin/syncthing ] || $sudo_cmd ln -sf /usr/local/bin/syncthing /usr/bin/syncthing
cd /
rm -rf "$tmpdir"

# 7) 安装 systemd unit（apt 包会自带 syncthing@.service；二进制方式要自己放一份）
if [ ! -f /etc/systemd/system/syncthing@.service ] && [ ! -f /lib/systemd/system/syncthing@.service ]; then
    echo "写入 /etc/systemd/system/syncthing@.service"
    $sudo_cmd tee /etc/systemd/system/syncthing@.service >/dev/null <<UNIT
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization for %I
Documentation=man:syncthing(1)
After=network.target

[Service]
User=%i
ExecStart=/usr/local/bin/syncthing serve --no-browser --no-restart --logflags=0
Restart=on-failure
RestartSec=5
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

# 以下系统调用沙盒配置与 apt 包提供的 unit 保持一致
ProtectSystem=full
PrivateTmp=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
    $sudo_cmd systemctl daemon-reload
fi

# 8) 验证
echo "INSTALLED: $(syncthing --version 2>&1 | head -1)"
'
    if ! ssh_exec_script "$install_script"; then
        die "Syncthing 安装失败（GitHub 二进制安装流程出错，请查看上方日志）"
    fi
    log_ok "Syncthing 安装完成（v2.x GitHub 二进制）"
}

# 远程首次启动 Syncthing 以生成配置
# 关键：让 syncthing 自己决定写入路径（--paths 报告的位置），脚本被动读取
_remote_init_config() {
    log_info "初始化 Syncthing 配置（首次启动以生成 config.xml）..."
    local script='
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
RUN_USER="'"$REMOTE_RUN_USER"'"
RUN_HOME="'"$REMOTE_HOME"'"

as_user() {
    if [ "$(whoami)" = "$RUN_USER" ]; then
        env HOME="$RUN_HOME" "$@"
    else
        $sudo_cmd -u "$RUN_USER" env HOME="$RUN_HOME" "$@"
    fi
}

# 1) 向 syncthing 本身问"你会把 config 写到哪"
#    v1.20+ 起为子命令 `syncthing paths`，v1.19- 为 flag `syncthing --paths`
CFG_PATH="$(as_user syncthing paths 2>/dev/null | awk "/^Configuration file:/ {getline; gsub(/^[ \t]+/, \"\", \$0); print; exit}")"
if [ -z "$CFG_PATH" ]; then
    CFG_PATH="$(as_user syncthing --paths 2>/dev/null | awk "/^Configuration file:/ {getline; gsub(/^[ \t]+/, \"\", \$0); print; exit}")"
fi
if [ -z "$CFG_PATH" ]; then
    # 最后兜底：v2 默认 ~/.local/state/syncthing，v1.19- 默认 ~/.config/syncthing
    if [ -d "$RUN_HOME/.local/state/syncthing" ]; then
        CFG_PATH="$RUN_HOME/.local/state/syncthing/config.xml"
    else
        CFG_PATH="$RUN_HOME/.config/syncthing/config.xml"
    fi
fi
CFG_DIR="$(dirname "$CFG_PATH")"
echo "DETECTED_CFG_PATH=$CFG_PATH"

# 2) 已存在则跳过
if [ -f "$CFG_PATH" ]; then
    echo "CONFIG_READY=1 (existing)"
    exit 0
fi

# 3) 确保目录存在 + 权限
mkdir -p "$CFG_DIR"
[ "$(whoami)" = "$RUN_USER" ] || $sudo_cmd chown -R "$RUN_USER":"$RUN_USER" "$CFG_DIR" 2>/dev/null || true

# 4) 优先用 generate 子命令（按版本从新到旧尝试）
#    v2.x:  syncthing generate --home=<dir>
#           （注意：v2 中 --no-default-folder 已移除；且 --config 必须与 --data 同时给）
#    v1.20~1.29: syncthing generate --home=<dir> [--no-default-folder]  或裸调用
#    v1.19-: syncthing -generate=PATH -no-default-folder
gen_out="$(as_user syncthing generate --home="$CFG_DIR" 2>&1)" && gen_rc=0 || gen_rc=$?
echo "---- generate(v2 --home) rc=$gen_rc ----"
echo "$gen_out" | tail -10

if [ ! -f "$CFG_PATH" ]; then
    gen_out2="$(as_user syncthing generate --home="$CFG_DIR" --no-default-folder 2>&1)" || true
    echo "---- generate(v1.20-1.29 --home + --no-default-folder) ----"
    echo "$gen_out2" | tail -10
fi

if [ ! -f "$CFG_PATH" ]; then
    gen_out3="$(as_user syncthing generate --no-default-folder 2>&1)" || true
    echo "---- generate(legacy subcommand) ----"
    echo "$gen_out3" | tail -10
fi

if [ ! -f "$CFG_PATH" ]; then
    gen_out4="$(as_user syncthing -generate="$CFG_DIR" -no-default-folder 2>&1)" || true
    echo "---- generate(very-old flag) ----"
    echo "$gen_out4" | tail -10
fi

# 5) 仍不行则前台启动一次让它自行初始化，抓到 config.xml 立即杀掉
if [ ! -f "$CFG_PATH" ]; then
    echo "---- fallback: foreground bootstrap ----"
    tmplog="$(mktemp)"
    # v2.x: syncthing serve --home=<dir> --no-browser （v2 无 --no-default-folder）
    as_user syncthing serve --home="$CFG_DIR" --no-browser >"$tmplog" 2>&1 &
    pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        # v1.20-1.29 兜底
        as_user syncthing serve --no-browser --no-default-folder >"$tmplog" 2>&1 &
        pid=$!
        sleep 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        # v1.19- 兜底
        as_user syncthing -no-browser -no-default-folder >"$tmplog" 2>&1 &
        pid=$!
    fi
    for i in $(seq 1 30); do
        [ -f "$CFG_PATH" ] && break
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tail -15 "$tmplog" 2>/dev/null
    rm -f "$tmplog"
fi

if [ -f "$CFG_PATH" ]; then
    echo "CONFIG_READY=1"
else
    echo "CONFIG_READY=0"
    ls -la "$CFG_DIR" 2>&1
fi
'
    local out; out="$(ssh_exec_script "$script" 2>&1)"
    if ! echo "$out" | grep -q "CONFIG_READY=1"; then
        printf "%s%s──── 服务器端初始化输出 ────%s\n" "$C_BOLD" "$C_YELLOW" "$C_RESET" >&2
        printf "%s\n" "$out" >&2
        printf "%s%s──────────────────────────%s\n" "$C_BOLD" "$C_YELLOW" "$C_RESET" >&2
        die "Syncthing 配置初始化失败，详见上方服务器输出"
    fi
    # 用 syncthing 报告的真实路径覆盖脚本全局变量（兼容 1.19 ~/.config/syncthing 与 1.20+ ~/.local/state/syncthing）
    local detected; detected="$(echo "$out" | awk -F= '/^DETECTED_CFG_PATH=/{print $2}' | tail -1)"
    if [[ -n "$detected" ]]; then
        REMOTE_CONFIG_XML="$detected"
        REMOTE_CONFIG_DIR="$(dirname "$detected")"
    fi
    log_ok "Syncthing 配置已生成：$REMOTE_CONFIG_XML"
}

# 创建同步根目录并赋权
_remote_prepare_sync_dir() {
    log_info "准备同步根目录 ${DEFAULT_REMOTE_ROOT}..."
    local script='
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
$sudo_cmd mkdir -p "'"$DEFAULT_REMOTE_ROOT"'"
$sudo_cmd chown -R "'"$REMOTE_RUN_USER"'":"'"$REMOTE_RUN_USER"'" "'"$DEFAULT_REMOTE_ROOT"'" || true
ls -ld "'"$DEFAULT_REMOTE_ROOT"'"
'
    ssh_exec_script "$script" | while read -r line; do log_info "  $line"; done
    log_ok "同步目录已就绪"
}

# 注册 systemd 服务并启动
_remote_enable_service() {
    log_info "配置 systemd 服务并启动..."
    local script='
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
RUN_USER="'"$REMOTE_RUN_USER"'"
# 官方包已自带 syncthing@.service 模板
$sudo_cmd systemctl daemon-reload || true
$sudo_cmd systemctl enable "syncthing@${RUN_USER}.service" >/dev/null 2>&1 || true
$sudo_cmd systemctl restart "syncthing@${RUN_USER}.service"
sleep 2
$sudo_cmd systemctl is-active "syncthing@${RUN_USER}.service"
'
    local out; out="$(ssh_exec_script "$script" 2>&1)"
    if echo "$out" | tail -1 | grep -q "^active$"; then
        log_ok "syncthing@${REMOTE_RUN_USER}.service 已启动并设置开机自启"
    else
        die "systemd 服务启动失败：\n$out"
    fi
}

# 开放防火墙端口
_remote_open_firewall() {
    log_info "尝试放通防火墙端口（22000/tcp, 22000/udp, 21027/udp）..."
    local script='
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
if command -v ufw >/dev/null 2>&1 && $sudo_cmd ufw status 2>/dev/null | grep -q "Status: active"; then
    $sudo_cmd ufw allow 22000/tcp >/dev/null 2>&1 || true
    $sudo_cmd ufw allow 22000/udp >/dev/null 2>&1 || true
    $sudo_cmd ufw allow 21027/udp >/dev/null 2>&1 || true
    echo "FIREWALL=ufw"
elif command -v firewall-cmd >/dev/null 2>&1 && $sudo_cmd firewall-cmd --state 2>/dev/null | grep -q running; then
    $sudo_cmd firewall-cmd --permanent --add-port=22000/tcp >/dev/null 2>&1 || true
    $sudo_cmd firewall-cmd --permanent --add-port=22000/udp >/dev/null 2>&1 || true
    $sudo_cmd firewall-cmd --permanent --add-port=21027/udp >/dev/null 2>&1 || true
    $sudo_cmd firewall-cmd --reload >/dev/null 2>&1 || true
    echo "FIREWALL=firewalld"
else
    echo "FIREWALL=none"
fi
'
    local out; out="$(ssh_exec_script "$script" 2>&1)"
    case "$out" in
        *FIREWALL=ufw*)       log_ok "已通过 ufw 放通端口" ;;
        *FIREWALL=firewalld*) log_ok "已通过 firewalld 放通端口" ;;
        *)                    log_warn "未检测到活动防火墙（或未开启）；请自行确认云厂商安全组已放通 22000、21027 端口" ;;
    esac
}

# 从远端 config.xml 读取 Device ID 与 API Key
_remote_read_identity() {
    log_info "读取服务器 Device ID 与 API Key..."
    local script='
set -e
CFG="'"$REMOTE_CONFIG_XML"'"
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
# device ID：<device id="XXX" name="...">
DID=$($sudo_cmd grep -oE "<device id=\"[A-Z0-9-]+\"" "$CFG" | head -1 | sed -E "s/.*id=\"([A-Z0-9-]+)\".*/\1/")
# api key：<apikey>...</apikey>
AKEY=$($sudo_cmd grep -oE "<apikey>[^<]+</apikey>" "$CFG" | sed -E "s/<\\/?apikey>//g")
printf "DEVICE_ID=%s\n" "$DID"
printf "API_KEY=%s\n"   "$AKEY"
'
    local out; out="$(ssh_exec_script "$script")"
    REMOTE_DEVICE_ID="$(echo "$out" | awk -F= '/^DEVICE_ID=/{print $2}')"
    REMOTE_API_KEY="$(echo "$out" | awk -F= '/^API_KEY=/{print $2}')"
    if [[ -z "$REMOTE_DEVICE_ID" || -z "$REMOTE_API_KEY" ]]; then
        die "无法解析服务器 config.xml 中的 Device ID / API Key"
    fi
    log_ok "服务器 Device ID：${REMOTE_DEVICE_ID:0:14}...${REMOTE_DEVICE_ID: -7}"
}

deploy_remote_syncthing() {
    log_step "步骤 2/8 ：服务器端 Syncthing 部署"

    log_info "探测服务器环境..."
    local env_out; env_out="$(_remote_probe_env)" || die "探测服务器环境失败"
    # 解析 KV
    local os_id pkg_mgr installed whoami_out has_sd sync_ver
    os_id="$(echo "$env_out"     | awk -F= '/^OS_ID=/{print $2}')"
    pkg_mgr="$(echo "$env_out"   | awk -F= '/^PKG_MGR=/{print $2}')"
    installed="$(echo "$env_out" | awk -F= '/^SYNCTHING_INSTALLED=/{print $2}')"
    sync_ver="$(echo "$env_out"  | awk -F= '/^SYNCTHING_VERSION=/{print $2}')"
    whoami_out="$(echo "$env_out"| awk -F= '/^WHOAMI=/{print $2}')"
    REMOTE_HOME="$(echo "$env_out" | awk -F= '/^HOME=/{print $2}')"
    has_sd="$(echo "$env_out"    | awk -F= '/^HAS_SYSTEMD=/{print $2}')"

    REMOTE_RUN_USER="$whoami_out"
    REMOTE_CONFIG_DIR="${REMOTE_HOME}/.config/syncthing"
    REMOTE_CONFIG_XML="${REMOTE_CONFIG_DIR}/config.xml"

    log_info "OS=${os_id}  包管理器=${pkg_mgr}  运行用户=${REMOTE_RUN_USER}  systemd=${has_sd}"

    [[ "$has_sd" == "1" ]] || die "服务器未安装 systemd，目前脚本仅支持基于 systemd 的发行版"

    # 版本策略：强制要求 v2.x —— 因为本地 Mac (brew) 一般会装最新 v2.x，
    # 服务器若留 v1.x 会导致协议不兼容（日志表现为 EOF / TLS handshake 不匹配 / unknown device）。
    local need_install="0"
    if [[ "$installed" != "1" ]]; then
        need_install="1"
    else
        # 取主版本号；syncthing --version 形如 "v2.0.16" 或 "v1.30.0"
        local major="${sync_ver#v}"
        major="${major%%.*}"
        if [[ -z "$major" || "$major" -lt 2 ]]; then
            log_warn "服务器已安装 Syncthing ${sync_ver}，但版本过旧（需要 v2.x 以兼容本地 Mac），将强制升级"
            need_install="1"
        else
            log_ok "Syncthing 已安装（版本：${sync_ver}），跳过安装步骤（幂等）"
        fi
    fi

    if [[ "$need_install" == "1" ]]; then
        _remote_install_syncthing "$pkg_mgr"
    fi

    _remote_init_config
    _remote_prepare_sync_dir
    _remote_enable_service
    _remote_open_firewall
    _remote_read_identity
}

# ---------------------------------------------------------------------------
# 模块：local —— 本地 Mac 端安装与管理
# ---------------------------------------------------------------------------
# macOS Syncthing 配置文件可能的路径（按优先级探测）：
#   - ~/Library/Application Support/Syncthing/config.xml  （brew --cask / Syncthing.app 桌面版）
#   - ~/Library/Application Support/Syncthing/config.xml  （brew formula）
#   - 某些版本：~/Library/Application Support/Syncthing/config.xml
LOCAL_CONFIG_XML=""

_local_detect_syncthing() {
    # 1) 命令是否存在（brew formula 场景）
    # 2) Syncthing.app 是否存在（brew cask 场景）
    if has_cmd syncthing; then return 0; fi
    [[ -d "/Applications/Syncthing.app" ]] && return 0
    return 1
}

# 从 GitHub 官方 Release 下载最新 Syncthing 二进制（自带 WebUI）
# 适用于未安装 Homebrew 的环境
_local_install_syncthing_from_github() {
    log_info "未检测到 Homebrew，将从官方 GitHub Release 下载最新 Syncthing..."

    # 1) 识别架构
    local arch_raw arch
    arch_raw="$(uname -m)"
    case "$arch_raw" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64)  arch="amd64" ;;
        *) die "不支持的 CPU 架构：$arch_raw（仅支持 arm64/amd64）" ;;
    esac

    # 2) 查询最新版本号
    log_info "查询最新版本..."
    local latest_tag
    latest_tag="$(curl -fsSL --max-time 15 \
        'https://api.github.com/repos/syncthing/syncthing/releases/latest' 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9][^"]*"' \
        | head -1 \
        | sed -E 's/.*"(v[0-9][^"]*)".*/\1/')"
    if [[ -z "$latest_tag" ]]; then
        die "无法从 GitHub 获取 Syncthing 最新版本号（请检查网络，或手动安装 Homebrew 后重试）"
    fi
    log_ok "最新版本：$latest_tag"

    # 3) 下载 macOS 压缩包
    local version="${latest_tag#v}"
    local pkg="syncthing-macos-${arch}-${latest_tag}.tar.gz"
    local url="https://github.com/syncthing/syncthing/releases/download/${latest_tag}/${pkg}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    log_info "下载：$url"
    if ! curl -fL --max-time 180 --progress-bar -o "${tmp_dir}/${pkg}" "$url"; then
        rm -rf "$tmp_dir"
        die "下载 Syncthing 失败（URL：$url）"
    fi

    # 4) 解压
    log_info "解压到临时目录..."
    if ! tar -xzf "${tmp_dir}/${pkg}" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        die "解压失败"
    fi
    local src_bin
    src_bin="$(find "$tmp_dir" -type f -name syncthing -perm -u+x | head -1)"
    [[ -x "$src_bin" ]] || { rm -rf "$tmp_dir"; die "解压后未找到 syncthing 可执行文件"; }

    # 5) 安装到 /usr/local/bin（PATH 里最通用的位置）；无权限则退回 ~/.local/bin
    local dest_dir dest_bin
    if [[ -w /usr/local/bin ]]; then
        dest_dir="/usr/local/bin"
    elif sudo -n true >/dev/null 2>&1; then
        dest_dir="/usr/local/bin"
    else
        log_warn "无法直接写入 /usr/local/bin，将安装到 ~/.local/bin"
        dest_dir="${HOME}/.local/bin"
        mkdir -p "$dest_dir"
    fi
    dest_bin="${dest_dir}/syncthing"

    if [[ "$dest_dir" == "/usr/local/bin" && ! -w /usr/local/bin ]]; then
        log_info "需要 sudo 权限写入 $dest_dir"
        sudo install -m 0755 "$src_bin" "$dest_bin" || { rm -rf "$tmp_dir"; die "安装到 $dest_bin 失败"; }
    else
        install -m 0755 "$src_bin" "$dest_bin" || { rm -rf "$tmp_dir"; die "安装到 $dest_bin 失败"; }
    fi

    # 6) macOS Gatekeeper：去隔离属性，避免首次运行被拦截
    xattr -dr com.apple.quarantine "$dest_bin" 2>/dev/null || true

    rm -rf "$tmp_dir"
    log_ok "Syncthing ${version} 已安装至：$dest_bin"

    # 若安装到 ~/.local/bin，提醒 PATH
    if [[ "$dest_dir" == "${HOME}/.local/bin" ]] && ! echo ":$PATH:" | grep -q ":${HOME}/.local/bin:"; then
        log_warn "请将 ${HOME}/.local/bin 加入 PATH（可写入 ~/.zshrc）："
        log_warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        export PATH="${HOME}/.local/bin:$PATH"
    fi

    # 验证
    if ! has_cmd syncthing; then
        hash -r 2>/dev/null || true
        if ! has_cmd syncthing; then
            die "安装后仍无法在 PATH 中找到 syncthing，请检查 $dest_bin"
        fi
    fi
    log_ok "syncthing 命令验证通过：$(command -v syncthing)"
}

_local_install_syncthing() {
    # 优先使用 Homebrew（cask 带菜单栏 GUI，体验最好）
    if has_cmd brew; then
        log_info "使用 Homebrew 安装 Syncthing（带 GUI）..."
        # 优先 cask（带原生 macOS 菜单栏 GUI）；失败则回退 formula
        if brew install --cask syncthing 2>&1 | tail -5; then
            log_ok "Syncthing.app 安装完成（cask）"
            return 0
        elif brew install syncthing 2>&1 | tail -5; then
            log_ok "Syncthing 安装完成（formula）"
            return 0
        else
            log_warn "Homebrew 安装失败，将尝试从 GitHub 直接下载..."
        fi
    fi

    # 未安装 Homebrew 或 brew 安装失败 → 直接从 GitHub Release 下载官方二进制
    # 该二进制自带完整 WebUI（默认 http://127.0.0.1:8384）
    _local_install_syncthing_from_github
}

_local_start_syncthing() {
    # 如果已在监听 8384 则认为已运行（用 -k -L 兼容 HTTPS/307）
    if curl -skSL --max-time 2 "${LOCAL_API_URL}/rest/noauth/health" >/dev/null 2>&1; then
        log_ok "本地 Syncthing 已在运行"
        return 0
    fi

    log_info "启动本地 Syncthing 服务..."
    if [[ -d "/Applications/Syncthing.app" ]]; then
        open -g -a "Syncthing" 2>/dev/null || open -a "Syncthing" 2>/dev/null || true
    elif has_cmd brew && brew services list 2>/dev/null | grep -q "^syncthing"; then
        brew services start syncthing >/dev/null 2>&1 || true
    elif has_cmd syncthing; then
        # 后台启动
        nohup syncthing -no-browser >/dev/null 2>&1 &
        disown
    else
        die "无法定位 Syncthing 可执行文件或 Syncthing.app"
    fi

    # 等待 REST API
    log_info "等待本地 Syncthing REST API 就绪（最多 30s）..."
    local waited=0
    while (( waited < 30 )); do
        if curl -skSL --max-time 2 "${LOCAL_API_URL}/rest/noauth/health" >/dev/null 2>&1; then
            log_ok "本地 Syncthing 已就绪"
            return 0
        fi
        sleep 1; ((waited++))
    done
    die "本地 Syncthing 在 30 秒内未启动成功"
}

_local_locate_config() {
    local candidates=(
        "${HOME}/Library/Application Support/Syncthing/config.xml"
        "${HOME}/.config/syncthing/config.xml"
        "${HOME}/.local/state/syncthing/config.xml"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && LOCAL_CONFIG_XML="$f" && return 0
    done
    return 1
}

_local_read_identity() {
    if ! _local_locate_config; then
        die "未找到本地 config.xml（预期位置：~/Library/Application Support/Syncthing/config.xml）"
    fi
    log_info "读取本地 config：$LOCAL_CONFIG_XML"

    # API Key 必须从 config.xml 读（REST 调用鉴权必需）
    LOCAL_API_KEY="$(grep -oE '<apikey>[^<]+</apikey>' "$LOCAL_CONFIG_XML" \
                    | sed -E 's/<\/?apikey>//g')"
    [[ -n "$LOCAL_API_KEY" ]] || die "无法解析本地 API Key"

    # 检测 GUI TLS，动态调整 LOCAL_API_URL
    if grep -qE '<gui[^>]+tls="true"' "$LOCAL_CONFIG_XML"; then
        LOCAL_API_URL="https://127.0.0.1:8384"
        log_info "检测到本地 GUI 启用了 TLS，切换为 HTTPS 访问"
    fi

    # Device ID 权威来源是 REST API 的 myID；
    # 严禁再从 config.xml 用 "head -1" 猜测——因为 <folder> 里会先引用 <device id=…>，
    # head -1 会命中远端设备的引用而不是本机自己的顶层 <device> 节点。
    local sys_status
    sys_status="$(curl -skSL --max-time 5 -H "X-API-Key: $LOCAL_API_KEY" \
                  "${LOCAL_API_URL}/rest/system/status" 2>/dev/null)"
    LOCAL_DEVICE_ID="$(echo "$sys_status" | sed -nE 's/.*"myID"[[:space:]]*:[[:space:]]*"([A-Z0-9-]+)".*/\1/p')"

    # 回退：API 暂不可用时，从 config.xml 里**仅**顶层 <device> 节点抓（有 name= 属性的才是顶层定义，
    # folder 子节点的 <device id=…> 只有 id 和 introducedBy，没有 name；再用 myID 元素二次定位）
    if [[ -z "$LOCAL_DEVICE_ID" ]]; then
        log_warn "REST API 未返回 myID，回退从 config.xml 解析"
        # syncthing v1.x/v2.x 的 config.xml 里本机 deviceID 会同时出现在 <defaults> 之外的顶层 <device ...> 块；
        # 这里只匹配同时带 id= 和 name= 的完整 device 声明，且排除 folder 内的引用
        LOCAL_DEVICE_ID="$(grep -oE '<device id="[A-Z0-9-]+" name="[^"]*"' "$LOCAL_CONFIG_XML" \
                          | head -1 \
                          | sed -E 's/.*id="([A-Z0-9-]+)".*/\1/')"
    fi
    [[ -n "$LOCAL_DEVICE_ID" ]] || die "无法解析本地 Device ID"

    log_ok "本地 Device ID：${LOCAL_DEVICE_ID:0:14}...${LOCAL_DEVICE_ID: -7}"
}

_local_verify_api() {
    log_info "验证本地 Syncthing API..."
    local ping_out
    ping_out="$(curl -skSL --max-time 3 -H "X-API-Key: $LOCAL_API_KEY" \
                "${LOCAL_API_URL}/rest/system/ping" 2>/dev/null)"
    if [[ "$ping_out" == *"pong"* ]]; then
        log_ok "本地 API 响应正常"
        return 0
    fi
    die "本地 API 未能响应"
}

# ---------------------------------------------------------------------------
# 远端卸载后，同步清理本地 Syncthing 配置中关联该远端设备的条目：
#   1) 找到被卸载的远端设备 ID（优先 last-run.json 的 server.deviceID，
#      退一步从本地 config 里按 address 包含 SSH_HOST 来匹配）；
#   2) 遍历所有 folder：
#      - 如果 folder.devices 里包含这个远端设备 → 把它摘掉；
#      - 摘完之后只剩本机自己 → 整个 folder 删除（否则留个"孤儿"folder 也没意义）；
#      - 还剩其他设备 → PUT 回去，保留与其他设备的共享关系；
#   3) 最后 DELETE 该远端 device；
#   4) 同时把 last-run.json 里的 .server 段清空，避免"追加模式"还指向不存在的服务器。
#
# 本函数是"尽力而为（best effort）"：任何步骤失败都只打印 warn，不 die，
# 不影响主卸载流程的返回值。
# ---------------------------------------------------------------------------
_local_prune_after_remote_uninstall() {
    echo
    log_step "同步清理本地 Syncthing 配置中与该远端相关的条目"

    # ---- 1) 本地 Syncthing 是否可用（没装 / 没启动 → 直接跳过，纯信息） ----
    if ! _local_locate_config 2>/dev/null; then
        log_info "本地未检测到 Syncthing 配置，跳过本地配置清理。"
        return 0
    fi

    # 软加载 API Key（不要 die，失败就跳过）
    if [[ -z "${LOCAL_API_KEY:-}" ]]; then
        LOCAL_API_KEY="$(grep -oE '<apikey>[^<]+</apikey>' "$LOCAL_CONFIG_XML" 2>/dev/null \
                        | sed -E 's/<\/?apikey>//g')"
    fi
    if [[ -z "$LOCAL_API_KEY" ]]; then
        log_warn "未能从本地 config.xml 读取 API Key，跳过本地配置清理。"
        log_warn "可在 Syncthing WebUI 里手动移除远端设备及对应的共享 folder。"
        return 0
    fi

    # 检测 TLS
    if grep -qE '<gui[^>]+tls="true"' "$LOCAL_CONFIG_XML" 2>/dev/null; then
        LOCAL_API_URL="https://127.0.0.1:8384"
    fi

    # ping 本地 API
    local ping_out
    ping_out="$(curl -skSL --max-time 3 -H "X-API-Key: $LOCAL_API_KEY" \
                "${LOCAL_API_URL}/rest/system/ping" 2>/dev/null)"
    if [[ "$ping_out" != *"pong"* ]]; then
        log_warn "本地 Syncthing 未响应（可能未启动），跳过本地配置清理。"
        log_warn "待 Syncthing 启动后，可在 WebUI 里手动移除远端设备及对应共享。"
        return 0
    fi

    # 取本机 deviceID（用于判定 folder 是否只剩本机）
    local my_id
    my_id="$(curl -skSL --max-time 5 -H "X-API-Key: $LOCAL_API_KEY" \
             "${LOCAL_API_URL}/rest/system/status" 2>/dev/null \
             | sed -nE 's/.*"myID"[[:space:]]*:[[:space:]]*"([A-Z0-9-]+)".*/\1/p')"

    # ---- 2) 定位被卸载的远端 device id ----
    local target_id=""
    if has_cmd jq && [[ -f "$STATE_FILE" ]]; then
        target_id="$(jq -r '.server.deviceID // ""' "$STATE_FILE" 2>/dev/null)"
    fi

    # 拉一次本地设备列表备用
    local devices_json
    devices_json="$(curl -skSL --max-time 5 -H "X-API-Key: $LOCAL_API_KEY" \
                    "${LOCAL_API_URL}/rest/config/devices" 2>/dev/null)"

    # last-run.json 读不到就按 SSH_HOST 在 devices 的 addresses 里反查
    if [[ -z "$target_id" && -n "${SSH_HOST:-}" ]] && has_cmd jq; then
        target_id="$(echo "$devices_json" \
            | jq -r --arg h "$SSH_HOST" \
                '[.[] | select((.addresses // []) | map(tostring) | any(contains($h)))] | .[0].deviceID // ""' \
                2>/dev/null)"
    fi

    if [[ -z "$target_id" ]]; then
        log_warn "未能自动识别已卸载远端设备对应的本地 Device ID（既无 last-run.json 记录，也无法按主机名匹配）。"
        log_warn "请打开本地 Syncthing WebUI，手动移除 ${SSH_HOST} 对应的设备与共享。"
        return 0
    fi

    # 判断 device 是否真的存在于本地配置里（卸载前可能就被用户手动删过了）
    local exists="no"
    if has_cmd jq; then
        exists="$(echo "$devices_json" \
            | jq -r --arg id "$target_id" 'any(.[]; .deviceID == $id) | if . then "yes" else "no" end' \
              2>/dev/null)"
    else
        echo "$devices_json" | grep -q "\"deviceID\":\"${target_id}\"" && exists="yes"
    fi
    if [[ "$exists" != "yes" ]]; then
        log_info "本地配置里未找到该远端设备（${target_id:0:7}），无需清理。"
        _local_prune_state_server
        return 0
    fi

    log_info "目标远端设备：${target_id:0:7}... (${SSH_HOST:-未知主机})"

    # ---- 3) 处理 folders ----
    if ! has_cmd jq; then
        log_warn "未检测到 jq，无法精细处理 folder 的 devices 列表。"
        log_warn "将直接跳过 folder 清理，只删除设备本身（可能会留下引用该设备的 folder）。"
    else
        local folders_json
        folders_json="$(curl -skSL --max-time 5 -H "X-API-Key: $LOCAL_API_KEY" \
                        "${LOCAL_API_URL}/rest/config/folders" 2>/dev/null)"

        local affected_cnt
        affected_cnt="$(echo "$folders_json" \
            | jq --arg id "$target_id" '[.[] | select((.devices // []) | any(.deviceID == $id))] | length' \
              2>/dev/null)"
        affected_cnt="${affected_cnt:-0}"

        if (( affected_cnt == 0 )); then
            log_info "本地没有任何 folder 与该远端设备共享，无需调整 folder。"
        else
            log_info "发现 ${affected_cnt} 个 folder 与该远端设备共享，开始处理..."

            # 用 while 读 jq 输出而不是 for，避免 folder label/path 含空格
            while IFS=$'\t' read -r fid flabel fpath; do
                [[ -z "$fid" ]] && continue

                # 取出该 folder 的 devices，剔除目标 id
                local new_devs_json rem_ids rem_count
                new_devs_json="$(echo "$folders_json" \
                    | jq -c --arg fid "$fid" --arg id "$target_id" \
                        '.[] | select(.id==$fid) | .devices |= map(select(.deviceID != $id))')"

                rem_ids="$(echo "$new_devs_json" \
                    | jq -r '[.devices[].deviceID] | join(",")' 2>/dev/null)"
                rem_count="$(echo "$new_devs_json" | jq '.devices | length' 2>/dev/null)"
                rem_count="${rem_count:-0}"

                # 只剩本机（或彻底没了）→ 整个 folder 删掉
                local only_self="no"
                if (( rem_count == 0 )); then
                    only_self="yes"
                elif (( rem_count == 1 )) && [[ -n "$my_id" && ",$rem_ids," == *",${my_id},"* ]]; then
                    only_self="yes"
                fi

                if [[ "$only_self" == "yes" ]]; then
                    log_info "  └ 删除 folder：${flabel:-$fid}  (${fid})"
                    log_info "     原因：移除该远端设备后，此 folder 已无其他共享对象"
                    if curl -skSL --max-time 8 -X DELETE \
                         -H "X-API-Key: $LOCAL_API_KEY" \
                         "${LOCAL_API_URL}/rest/config/folders/${fid}" >/dev/null 2>&1; then
                        log_ok "     folder ${fid} 已删除"
                    else
                        log_warn "     folder ${fid} 删除失败（HTTP 错误），请在 WebUI 手动处理"
                    fi
                else
                    log_info "  └ 更新 folder：${flabel:-$fid}  (${fid})  — 仅移除该远端设备，保留其他共享"
                    local tmp_body; tmp_body="$(mktemp)"
                    echo "$new_devs_json" > "$tmp_body"
                    if curl -skSL --max-time 8 -X PUT \
                         -H "X-API-Key: $LOCAL_API_KEY" \
                         -H "Content-Type: application/json" \
                         --data-binary "@${tmp_body}" \
                         "${LOCAL_API_URL}/rest/config/folders/${fid}" >/dev/null 2>&1; then
                        log_ok "     folder ${fid} 已更新（剩余共享对象 ${rem_count} 个）"
                    else
                        log_warn "     folder ${fid} 更新失败（HTTP 错误），请在 WebUI 手动处理"
                    fi
                    rm -f "$tmp_body"
                fi
            done < <(echo "$folders_json" \
                     | jq -r --arg id "$target_id" \
                         '.[] | select((.devices // []) | any(.deviceID == $id))
                                | [.id, (.label // ""), (.path // "")] | @tsv')
        fi
    fi

    # ---- 4) 删除 device 自身 ----
    log_info "删除本地设备：${target_id:0:14}..."
    if curl -skSL --max-time 8 -X DELETE \
         -H "X-API-Key: $LOCAL_API_KEY" \
         "${LOCAL_API_URL}/rest/config/devices/${target_id}" >/dev/null 2>&1; then
        log_ok "本地已移除该远端设备"
    else
        log_warn "删除本地设备失败（HTTP 错误），请在 WebUI 手动移除：${target_id:0:14}..."
    fi

    # ---- 5) 更新 last-run.json：清掉 server 段 ----
    _local_prune_state_server

    log_ok "本地 Syncthing 配置已同步清理完成"
}

# 把 last-run.json 里的 .server 段清空（保留 local 段，以便后续追加其他服务器时仍能复用本机信息）
_local_prune_state_server() {
    [[ -f "$STATE_FILE" ]] || return 0
    if ! has_cmd jq; then
        # 没 jq → 整个文件删掉更稳妥，避免残留指向已卸载服务器的记录
        rm -f "$STATE_FILE" 2>/dev/null && \
            log_info "已删除状态文件：$STATE_FILE（无 jq 可用，整体清理）"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    if jq 'del(.server)' "$STATE_FILE" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE" 2>/dev/null || true
        log_info "已从 $STATE_FILE 中移除 .server 段"
    else
        rm -f "$tmp"
        log_warn "更新 $STATE_FILE 失败（已忽略）。下次部署前可手动删除该文件。"
    fi
}

install_local_syncthing() {
    log_step "步骤 4/8 ：本地 Mac 端 Syncthing 安装与启动"

    if _local_detect_syncthing; then
        log_ok "本地已安装 Syncthing，跳过安装（幂等）"
    else
        _local_install_syncthing
    fi

    _local_start_syncthing
    _local_read_identity
    _local_verify_api
}

# ---------------------------------------------------------------------------
# 模块：syncthing_api —— 本地/远端 Syncthing REST 封装
# ---------------------------------------------------------------------------
# 远端 API 调用：通过本地 SSH 端口转发（127.0.0.1:REMOTE_API_LOCAL_PORT）访问
#   用法：remote_api_call GET /rest/system/status
#        remote_api_call POST /rest/config/devices /tmp/body.json
remote_api_call() {
    local method="$1" path="$2" body_file="${3:-}"
    [[ -n "$REMOTE_API_KEY" ]] || { log_error "REMOTE_API_KEY 为空"; return 1; }
    http_call "$method" "${REMOTE_API_URL}${path}" "$REMOTE_API_KEY" "$body_file"
}

# 本地 API 调用
local_api_call() {
    local method="$1" path="$2" body_file="${3:-}"
    [[ -n "$LOCAL_API_KEY" ]] || { log_error "LOCAL_API_KEY 为空"; return 1; }
    http_call "$method" "${LOCAL_API_URL}${path}" "$LOCAL_API_KEY" "$body_file"
}

# 生成安全随机字符串（N 字符，字母数字）
_rand_str() {
    local n="${1:-16}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n"
}

# 远端：更新 GUI 用户名/密码（通过 REST API，避免直接编辑 config.xml 后需要重启）
#   设置：address=127.0.0.1:8384、user、password（Syncthing 会自动 bcrypt 哈希）
_remote_set_gui_credentials() {
    local user="$1" pass="$2"
    log_info "配置服务器 GUI 访问凭证（用户名：${user}）..."
    # 先取当前 gui 配置
    local gui_json
    gui_json="$(remote_api_call GET /rest/config/gui)" || die "无法获取远端 GUI 配置"

    local body_file; body_file="$(mktemp)"
    if has_cmd jq; then
        echo "$gui_json" | jq \
            --arg u "$user" --arg p "$pass" --arg addr "127.0.0.1:8384" \
            '.user=$u | .password=$p | .address=$addr' > "$body_file"
    else
        # 降级：不依赖 jq，直接构造一个最小合法 body（Syncthing 接受 PATCH 部分字段）
        printf '{"user":"%s","password":"%s","address":"127.0.0.1:8384"}' "$user" "$pass" > "$body_file"
    fi
    if ! remote_api_call PUT /rest/config/gui "$body_file" >/dev/null; then
        rm -f "$body_file"
        die "设置远端 GUI 凭证失败"
    fi
    rm -f "$body_file"
    log_ok "远端 GUI 凭证已更新"
}

# 建立 SSH 本地端口转发：127.0.0.1:18384 -> 远端 127.0.0.1:8384
_setup_ssh_tunnel() {
    log_info "建立 SSH 端口转发 127.0.0.1:${REMOTE_API_LOCAL_PORT} -> 远端 :8384 ..."

    # 如本地端口已被占用则换端口（简单重试）
    if lsof -nP -iTCP:"${REMOTE_API_LOCAL_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        log_warn "本地端口 ${REMOTE_API_LOCAL_PORT} 已占用；尝试结束旧隧道..."
        # 仅尝试结束本脚本可能遗留的
        pkill -f "ssh.*-L ${REMOTE_API_LOCAL_PORT}:127.0.0.1:8384.*${SSH_HOST}" 2>/dev/null || true
        sleep 1
    fi

    # shellcheck disable=SC2086
    SSHPASS="$SSH_PASS" sshpass -e ssh $(_ssh_base_opts) \
        -f -N \
        -L "${REMOTE_API_LOCAL_PORT}:127.0.0.1:8384" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        "${SSH_USER}@${SSH_HOST}"
    local rc=$?
    if (( rc != 0 )); then
        die "建立 SSH 端口转发失败（rc=${rc}）"
    fi

    # 找到后台隧道 PID（sshpass fork 的 ssh -f 进程）
    SSH_TUNNEL_PID="$(pgrep -f "ssh.*-L ${REMOTE_API_LOCAL_PORT}:127.0.0.1:8384.*${SSH_USER}@${SSH_HOST}" | head -1)"
    if [[ -z "$SSH_TUNNEL_PID" ]]; then
        log_warn "未能定位 SSH 隧道 PID（将依赖 cleanup 的 pkill 兜底）"
    else
        log_ok "SSH 隧道建立成功（PID=${SSH_TUNNEL_PID}）"
    fi

    # 探测远端 GUI 是否启用 TLS
    local tls_script='
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
if $sudo_cmd grep -qE "<gui[^>]+tls=\"true\"" "'"$REMOTE_CONFIG_XML"'" 2>/dev/null; then
    echo "TLS=1"
else
    echo "TLS=0"
fi
'
    local tls_out; tls_out="$(ssh_exec_script "$tls_script" 2>/dev/null | tr -d '\r')"
    if [[ "$tls_out" == *"TLS=1"* ]]; then
        REMOTE_API_URL="https://127.0.0.1:${REMOTE_API_LOCAL_PORT}"
        log_info "检测到远端 GUI 启用了 TLS，切换为 HTTPS 访问"
    fi

    # 等待端口可用
    local waited=0
    while (( waited < 15 )); do
        if curl -skSL --max-time 2 "${REMOTE_API_URL}/rest/noauth/health" >/dev/null 2>&1; then
            break
        fi
        sleep 1; ((waited++))
    done
}

# 验证远端 API 可达
_verify_remote_api() {
    log_info "验证远端 Syncthing API 可达..."
    local waited=0
    while (( waited < 30 )); do
        local ping_out
        ping_out="$(curl -skSL --max-time 3 -H "X-API-Key: $REMOTE_API_KEY" \
                    "${REMOTE_API_URL}/rest/system/ping" 2>/dev/null)"
        if [[ "$ping_out" == *"pong"* ]]; then
            log_ok "远端 API 响应正常"
            return 0
        fi
        sleep 1; ((waited++))
    done
    die "远端 API 在 30 秒内未能响应，请检查 syncthing 服务状态"
}

setup_remote_api_tunnel() {
    log_step "步骤 3/8 ：建立远端 API 通道与 GUI 凭证"

    _setup_ssh_tunnel
    _verify_remote_api

    # 生成随机 GUI 凭证并写入
    local gui_user="obsidian_sync"
    local gui_pass; gui_pass="$(_rand_str 20)"
    _remote_set_gui_credentials "$gui_user" "$gui_pass"

    # 保存明文到运行时变量（非敏感持久化：仅打印给用户参考，不写入 last-run.json 的密码字段）
    REMOTE_GUI_USER="$gui_user"
    REMOTE_GUI_PASS="$gui_pass"
    log_info "远端 GUI 凭证：user=${gui_user}  password=${gui_pass}"
    log_warn "该密码仅本次会话展示一次，请妥善保存（如需找回可通过 SSH 查看 config.xml）"
}

# ---------------------------------------------------------------------------
# 设备配对：双向 PATCH /rest/config/devices
# ---------------------------------------------------------------------------
# 判断设备是否已存在（scope: local/remote）
_device_exists() {
    local scope="$1" device_id="$2"
    local out
    if [[ "$scope" == "local" ]]; then
        out="$(local_api_call GET /rest/config/devices)" || return 2
    else
        out="$(remote_api_call GET /rest/config/devices)" || return 2
    fi
    echo "$out" | grep -q "\"deviceID\":\"${device_id}\"" && return 0
    return 1
}

# 构造一个 device 对象 JSON
_make_device_json() {
    local device_id="$1" name="$2" addresses="$3" auto_accept="${4:-false}"
    cat <<JSON
{
  "deviceID": "${device_id}",
  "name": "${name}",
  "addresses": [${addresses}],
  "compression": "metadata",
  "introducer": false,
  "skipIntroductionRemovals": false,
  "paused": false,
  "allowedNetworks": [],
  "autoAcceptFolders": ${auto_accept},
  "maxSendKbps": 0,
  "maxRecvKbps": 0,
  "ignoredFolders": [],
  "maxRequestKiB": 0
}
JSON
}

# 向本地添加服务器设备
_add_remote_device_to_local() {
    if _device_exists local "$REMOTE_DEVICE_ID"; then
        log_ok "本地已存在服务器设备（幂等跳过）"
        return 0
    fi
    log_info "向本地 Syncthing 添加服务器设备..."
    local body; body="$(mktemp)"
    _make_device_json \
        "$REMOTE_DEVICE_ID" \
        "cloud-${SSH_HOST}" \
        "\"tcp://${SSH_HOST}:22000\", \"dynamic\"" \
        "false" > "$body"
    if ! local_api_call POST /rest/config/devices "$body" >/dev/null; then
        rm -f "$body"
        die "本地添加远端设备失败"
    fi
    rm -f "$body"
    ROLLBACK_STACK+=("local_device:${REMOTE_DEVICE_ID}")
    log_ok "服务器设备已加入本地配置"
}

# 向服务器添加本地设备
_add_local_device_to_remote() {
    if _device_exists remote "$LOCAL_DEVICE_ID"; then
        log_ok "服务器已存在本地设备（幂等跳过）"
        return 0
    fi
    log_info "向服务器 Syncthing 添加本地设备..."
    local body; body="$(mktemp)"
    _make_device_json \
        "$LOCAL_DEVICE_ID" \
        "mac-$(hostname -s)" \
        "\"dynamic\"" \
        "true" > "$body"
    if ! remote_api_call POST /rest/config/devices "$body" >/dev/null; then
        rm -f "$body"
        die "服务器添加本地设备失败"
    fi
    rm -f "$body"
    ROLLBACK_STACK+=("remote_device:${LOCAL_DEVICE_ID}")
    log_ok "本地设备已加入服务器配置"
}

# 轮询连接状态
_wait_peer_connected() {
    local wait_timeout="${OBSIDIAN_SYNC_PEER_WAIT:-60}"
    log_info "等待双向 TCP 连接建立（最长 ${wait_timeout}s，可用 OBSIDIAN_SYNC_PEER_WAIT 覆盖）..."
    # 先做一次端口快速探测，给用户更明确的排障线索
    if has_cmd nc; then
        if nc -z -w 3 "$SSH_HOST" 22000 2>/dev/null; then
            log_ok "端口探测：${SSH_HOST}:22000 TCP 可达"
        else
            log_warn "端口探测：${SSH_HOST}:22000 TCP 不可达（大概率是云厂商安全组未放通）"
            log_warn "  → 请在云控制台放通 22000/tcp 与 22000/udp，然后再次运行脚本"
        fi
    fi
    local waited=0
    local status_out connected
    while (( waited < wait_timeout )); do
        status_out="$(local_api_call GET "/rest/system/connections" 2>/dev/null)" || status_out=""
        # 匹配 "<device_id>":{...,"connected":true,...}
        if echo "$status_out" | grep -q "\"${REMOTE_DEVICE_ID}\""; then
            connected="$(echo "$status_out" \
                | tr ',' '\n' \
                | grep -A0 '"connected"' \
                | head -1 \
                | grep -oE 'true|false')"
            # 更健壮的提取（当有 jq 时）
            if has_cmd jq; then
                connected="$(echo "$status_out" | jq -r ".connections[\"${REMOTE_DEVICE_ID}\"].connected // false")"
            fi
            if [[ "$connected" == "true" ]]; then
                log_ok "双向连接已建立（connected=true）"
                return 0
            fi
        fi
        sleep 2; ((waited+=2))
        printf "."
    done
    echo
    log_warn "${wait_timeout} 秒内未检测到 connected=true"
    log_warn "排障建议："
    log_warn "  1. 云厂商安全组是否放通 22000/tcp、22000/udp"
    log_warn "  2. 服务器本机防火墙是否放通（ufw/firewalld）"
    log_warn "  3. 确认 ${SSH_HOST}:22000 可达：nc -vz ${SSH_HOST} 22000"
    log_warn "将继续执行后续步骤（创建 folder 会主动触发握手，通常能加速连接建立）"
    # 注：不再在此阻断流程。Syncthing 在没连上时仍会接受 folder 配置，
    # 等对端上线后会自动协商同步。这样比卡在握手等待更友好。
    return 0
}

pair_devices() {
    log_step "步骤 5/8 ：双向 Device ID 配对"
    _add_remote_device_to_local
    _add_local_device_to_remote
    _wait_peer_connected
}

# ---------------------------------------------------------------------------
# 模块：vault 发现与 TUI 多选
# ---------------------------------------------------------------------------
# 用户最终选中的 Vault 绝对路径数组
SELECTED_VAULTS=()

# 用户最终选中的、要共享到的远端 Device ID 数组
# 默认至少包含本次目标服务器 REMOTE_DEVICE_ID，用户可追加勾选本地已配对的其他远端
SELECTED_REMOTE_DEVICES=()

# 探测某目录下是否存在 iCloud 未下载占位文件（.xxx.icloud）
_dir_has_icloud_placeholder() {
    local dir="$1"
    # -maxdepth 5 减少耗时
    find "$dir" -maxdepth 5 -name "*.icloud" -print -quit 2>/dev/null | grep -q .
}

# 返回 vault 根目录
_resolve_obsidian_root() {
    if [[ -d "$DEFAULT_OBSIDIAN_ROOT" ]]; then
        echo "$DEFAULT_OBSIDIAN_ROOT"
        return 0
    fi
    log_warn "未检测到默认 iCloud Obsidian 目录："
    log_warn "  $DEFAULT_OBSIDIAN_ROOT"
    local custom
    custom="$(read_with_default "请手动输入 Obsidian 根目录（包含多个 Vault）" "$HOME/Documents/Obsidian")"
    if [[ ! -d "$custom" ]]; then
        die "目录不存在：$custom"
    fi
    echo "$custom"
}

# 列出候选 Vault：一级子目录
#   输出格式（tab 分隔）：<path>\t<size>\t<icloud_flag(Y/N)>
_list_vault_candidates() {
    local root="$1"
    # 忽略隐藏目录
    while IFS= read -r -d '' d; do
        local size flag
        size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
        flag="N"
        _dir_has_icloud_placeholder "$d" && flag="Y"
        printf "%s\t%s\t%s\n" "$d" "$size" "$flag"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name ".*" -print0 2>/dev/null)
}

# 使用 fzf 或 bash select 进行多选
#   输入：候选行（tab 格式）
#   输出：选中路径（按行），写入 SELECTED_VAULTS
_multi_select() {
    local -a candidates=("$@")
    if (( ${#candidates[@]} == 0 )); then
        die "未发现任何 Vault 目录"
    fi

    # 展示：格式化每行
    local -a display_lines=()
    local i=1
    for line in "${candidates[@]}"; do
        local path size flag tag=""
        path="$(echo "$line" | awk -F'\t' '{print $1}')"
        size="$(echo "$line" | awk -F'\t' '{print $2}')"
        flag="$(echo "$line" | awk -F'\t' '{print $3}')"
        [[ "$flag" == "Y" ]] && tag=" [⚠ 含 iCloud 未下载占位]"
        display_lines+=("$(printf "%2d. %-50s  %6s%s" "$i" "$(basename "$path")" "$size" "$tag")")
        ((i++))
    done

    if has_cmd fzf; then
        log_info "请使用 TAB 多选，ENTER 确认（ESC 取消）"
        local selected
        selected="$(printf "%s\n" "${display_lines[@]}" \
            | fzf --multi --height=60% --reverse --border \
                  --header="选择要同步的 Obsidian Vault（TAB 多选）" \
                  --prompt="> ")"
        [[ -z "$selected" ]] && die "未选择任何 Vault"
        while IFS= read -r sel; do
            # 回取索引
            local idx
            idx="$(echo "$sel" | awk '{print $1}' | tr -d '.')"
            SELECTED_VAULTS+=("$(echo "${candidates[$((idx-1))]}" | awk -F'\t' '{print $1}')")
        done <<< "$selected"
    else
        # 降级：一次性输入多个编号（空格或逗号分隔），或 'a' 全选
        log_info "fzf 未安装，使用降级菜单"
        echo
        for line in "${display_lines[@]}"; do
            printf "  %s\n" "$line"
        done
        echo
        log_info "输入方式：多个编号用空格分隔，例如：1 3 5；输入 a 全选；直接回车取消"
        local -A picked
        local input
        input="$(read_with_default "请选择要同步的 Vault" "")"
        if [[ -z "$input" ]]; then
            die "未选择任何 Vault"
        fi
        if [[ "$input" == "a" || "$input" == "A" ]]; then
            local k; for ((k=1;k<=${#candidates[@]};k++)); do picked[$k]=1; done
        else
            # 允许逗号或空格分隔
            local token
            for token in ${input//,/ }; do
                if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#candidates[@]} )); then
                    picked[$token]=1
                else
                    log_warn "忽略无效输入：$token"
                fi
            done
        fi
        local k
        for k in "${!picked[@]}"; do
            SELECTED_VAULTS+=("$(echo "${candidates[$((k-1))]}" | awk -F'\t' '{print $1}')")
        done
    fi

    (( ${#SELECTED_VAULTS[@]} > 0 )) || die "未选择任何 Vault"
}

# 让用户选择本次新创建的 folder 要共享给哪些远端设备
# 行为：
#   - 默认勾选本次目标服务器（REMOTE_DEVICE_ID）
#   - 如果本地 Syncthing 只有一个远端设备（就是本次目标服务器），直接跳过交互
#   - 如果本地还有其他远端设备，列出来让用户按编号多选追加
_select_remote_devices() {
    # 至少包含本次目标服务器
    SELECTED_REMOTE_DEVICES=("$REMOTE_DEVICE_ID")

    # 没有 jq 的话不做多选交互，直接只用本次目标服务器（保持原有行为）
    has_cmd jq || return 0

    local devices_out
    devices_out="$(local_api_call GET /rest/config/devices 2>/dev/null)" || return 0

    # 其他远端设备（不含自己、不含本次目标服务器）
    local others_json
    others_json="$(echo "$devices_out" \
        | jq -c --arg me "$LOCAL_DEVICE_ID" --arg peer "$REMOTE_DEVICE_ID" \
             '[.[] | select(.deviceID != $me and .deviceID != $peer) | {id: .deviceID, name: .name}]' 2>/dev/null)"
    local cnt
    cnt="$(echo "$others_json" | jq 'length' 2>/dev/null)"
    [[ -z "$cnt" || "$cnt" == "0" ]] && return 0

    echo
    log_step "选择要共享到的远端设备"

    # 本次目标服务器在 Syncthing 里的显示名（从本地 devices 配置读取，读不到就用 "cloud-<host>"）
    local peer_name
    peer_name="$(echo "$devices_out" | jq -r --arg id "$REMOTE_DEVICE_ID" \
        '.[] | select(.deviceID == $id) | .name' 2>/dev/null | head -1)"
    [[ -z "$peer_name" ]] && peer_name="cloud-${SSH_HOST}"

    if has_cmd fzf; then
        # ─── fzf 多选交互 ─────────────────────────────────────────
        # 列表结构：第一项 = 本次目标服务器（默认勾选），其余为其他已配对远端
        # 每行格式：<deviceID>|<显示内容>，只用 --with-nth=2 展示第二列
        log_info "请按 TAB 勾选/取消勾选，回车确认；默认已勾选本次目标服务器"
        echo

        local fzf_input=""
        # 第一行：本次目标服务器
        fzf_input+="${REMOTE_DEVICE_ID}|${peer_name}  (${REMOTE_DEVICE_ID:0:7})  [本次目标服务器]"$'\n'
        # 其余行：其他已配对设备
        while IFS= read -r row; do
            local rname rid
            rname="$(echo "$row" | jq -r '.name')"
            rid="$(echo "$row"   | jq -r '.id')"
            fzf_input+="${rid}|${rname}  (${rid:0:7})"$'\n'
        done < <(echo "$others_json" | jq -c '.[]')

        local selected
        selected="$(printf "%s" "$fzf_input" | fzf \
            --multi \
            --height=40% \
            --layout=reverse \
            --border \
            --header=$'TAB 勾选/取消  ·  ENTER 确认  ·  ESC 取消\n（默认已勾选本次目标服务器）' \
            --prompt='共享到> ' \
            --delimiter='|' --with-nth=2 \
            --bind='load:pos(1)+toggle' \
            2>/dev/null || true)"

        # 用户按 ESC 或未选任何项 → 回退到"仅共享给本次目标服务器"
        if [[ -z "$selected" ]]; then
            log_warn "未勾选任何设备，将仅共享给本次目标服务器：${peer_name}"
            return 0
        fi

        # 重置数组：从 fzf 结果重新构造（保证本次目标服务器一定在内）
        SELECTED_REMOTE_DEVICES=()
        local has_target=0
        while IFS= read -r line; do
            local did="${line%%|*}"
            [[ -z "$did" ]] && continue
            SELECTED_REMOTE_DEVICES+=("$did")
            [[ "$did" == "$REMOTE_DEVICE_ID" ]] && has_target=1
        done <<< "$selected"

        # 容错：万一用户把默认勾选的本次目标服务器取消了，仍强制共享给它
        if (( has_target == 0 )); then
            log_warn "检测到你取消勾选了本次目标服务器，脚本仍会把它加入共享（否则本次部署没意义）"
            SELECTED_REMOTE_DEVICES+=("$REMOTE_DEVICE_ID")
        fi

        # 回显最终勾选结果
        local did
        for did in "${SELECTED_REMOTE_DEVICES[@]}"; do
            local dname
            dname="$(echo "$devices_out" | jq -r --arg id "$did" \
                '.[] | select(.deviceID == $id) | .name' 2>/dev/null | head -1)"
            [[ -z "$dname" ]] && dname="(未知)"
            if [[ "$did" == "$REMOTE_DEVICE_ID" ]]; then
                log_ok "已选择：${dname}  (${did:0:7})  ← 本次目标服务器"
            else
                log_ok "已选择：${dname}  (${did:0:7})"
            fi
        done
        return 0
    fi

    # ─── 降级方案：fzf 未安装时使用数字菜单 ─────────────────────
    printf "   %s本次目标服务器（默认已勾选）%s：%s%s%s  %s(%s)%s\n" \
        "$C_GRAY" "$C_RESET" "$C_GREEN" "$peer_name" "$C_RESET" \
        "$C_GRAY" "${REMOTE_DEVICE_ID:0:7}" "$C_RESET"
    echo
    log_info "本地还有以下已配对的远端设备，如需同时共享本次 Vault，请按编号勾选："

    # 列出其他远端
    local i=1
    while IFS= read -r row; do
        local rname rid
        rname="$(echo "$row" | jq -r '.name')"
        rid="$(echo "$row"   | jq -r '.id')"
        printf "   %2d. %s%s%s  %s(%s)%s\n" "$i" "$C_BOLD" "$rname" "$C_RESET" "$C_GRAY" "${rid:0:7}" "$C_RESET"
        ((i++))
    done < <(echo "$others_json" | jq -c '.[]')

    echo
    log_info "输入方式：多个编号用空格/逗号分隔，例如 1 2；输入 a 全选；直接回车表示只共享给本次目标服务器"

    local input
    input="$(read_with_default "请选择额外要共享的远端设备" "")"

    if [[ -z "$input" ]]; then
        log_info "仅共享给本次目标服务器：${peer_name}"
        return 0
    fi

    local -A picked
    if [[ "$input" == "a" || "$input" == "A" ]]; then
        local k; for ((k=1; k<=cnt; k++)); do picked[$k]=1; done
    else
        local token
        for token in ${input//,/ }; do
            if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= cnt )); then
                picked[$token]=1
            else
                log_warn "忽略无效输入：$token"
            fi
        done
    fi

    # 把勾选的追加进 SELECTED_REMOTE_DEVICES
    local k picked_id picked_name
    for k in "${!picked[@]}"; do
        picked_id="$(echo "$others_json"   | jq -r ".[$((k-1))].id")"
        picked_name="$(echo "$others_json" | jq -r ".[$((k-1))].name")"
        SELECTED_REMOTE_DEVICES+=("$picked_id")
        log_ok "已追加远端设备：${picked_name}  (${picked_id:0:7})"
    done
}

select_obsidian_vaults() {
    log_step "步骤 6/8 ：选择要同步的 Obsidian Vault"

    local root; root="$(_resolve_obsidian_root)" || die "无法确定 Obsidian 根目录"
    log_info "扫描目录：$root"

    # 收集候选
    local -a candidates=()
    while IFS= read -r line; do candidates+=("$line"); done \
        < <(_list_vault_candidates "$root")

    if (( ${#candidates[@]} == 0 )); then
        die "$root 下未发现任何 Vault 子目录"
    fi

    _multi_select "${candidates[@]}"

    # 展示选择结果（不再二次确认，减少多余的回车）
    echo
    log_info "已选择 ${#SELECTED_VAULTS[@]} 个 Vault："
    local v
    for v in "${SELECTED_VAULTS[@]}"; do
        local icloud_warn=""
        if _dir_has_icloud_placeholder "$v"; then
            icloud_warn=" ${C_YELLOW}[⚠ 含未下载文件，建议先在 Finder 中右键 → 立即下载]${C_RESET}"
        fi
        printf "  • %s%s\n" "$v" "$icloud_warn"
    done
    echo
}

# ---------------------------------------------------------------------------
# 模块：创建双向共享文件夹
# ---------------------------------------------------------------------------
# 存储本次生成的 folder 映射：每项格式 "folderID<TAB>local_path<TAB>remote_path"
SHARED_FOLDERS=()

# folderID 清理：替换非法字符，限制长度
_sanitize_folder_id() {
    local name="$1"
    # 仅保留字母数字、连字符、下划线
    local clean
    clean="$(echo "$name" | tr ' ' '-' | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$clean" ]] && clean="vault"
    # 前缀限长
    clean="${clean:0:32}"
    local suffix
    suffix="$(_rand_str 5 | tr '[:upper:]' '[:lower:]')"
    echo "${clean}-${suffix}"
}

_folder_exists() {
    local scope="$1" folder_id="$2"
    local out
    if [[ "$scope" == "local" ]]; then
        out="$(local_api_call GET /rest/config/folders)" || return 2
    else
        out="$(remote_api_call GET /rest/config/folders)" || return 2
    fi
    echo "$out" | grep -q "\"id\":\"${folder_id}\"" && return 0
    return 1
}

# 构造 folder JSON（sendreceive + staggered 版本控制）
#   第 4 个参数 peer_device_ids：用换行分隔的远端 device ID 列表
#     - 在本地端调用时传入：SELECTED_REMOTE_DEVICES 全部（可能多台）
#     - 在服务器端调用时传入：仅 LOCAL_DEVICE_ID（服务器只认识 Mac 这一个对端）
_make_folder_json() {
    local folder_id="$1" label="$2" path="$3" peer_device_ids="$4"

    # 生成 devices JSON 数组：本机 + 逐个对端
    local devices_json
    devices_json="{\"deviceID\": \"${LOCAL_DEVICE_ID}\"}"
    local did
    while IFS= read -r did; do
        [[ -z "$did" ]] && continue
        # 防重复（比如传入列表里意外包含 LOCAL_DEVICE_ID）
        [[ "$did" == "$LOCAL_DEVICE_ID" ]] && continue
        devices_json+=", {\"deviceID\": \"${did}\"}"
    done <<< "$peer_device_ids"

    cat <<JSON
{
  "id": "${folder_id}",
  "label": "${label}",
  "path": "${path}",
  "type": "sendreceive",
  "rescanIntervalS": 60,
  "fsWatcherEnabled": true,
  "fsWatcherDelayS": 10,
  "ignorePerms": false,
  "autoNormalize": true,
  "devices": [
    ${devices_json}
  ],
  "versioning": {
    "type": "staggered",
    "params": {
      "cleanInterval": "3600",
      "maxAge": "2592000",
      "versionsPath": ""
    }
  },
  "copiers": 0,
  "puller": 0,
  "hashers": 0,
  "order": "random",
  "ignoreDelete": false,
  "scanProgressIntervalS": 0,
  "pullerPauseS": 0,
  "maxConflicts": 10,
  "disableSparseFiles": false,
  "disableTempIndexes": false,
  "paused": false,
  "weakHashThresholdPct": 25,
  "markerName": ".stfolder",
  "copyOwnershipFromParent": false,
  "modTimeWindowS": 0
}
JSON
}

# 在服务器上预创建目录并赋权
_remote_prepare_folder_dir() {
    local remote_path="$1"
    local script='
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
$sudo_cmd mkdir -p "'"$remote_path"'"
$sudo_cmd chown -R "'"$REMOTE_RUN_USER"'":"'"$REMOTE_RUN_USER"'" "'"$remote_path"'"
echo OK
'
    local out; out="$(ssh_exec_script "$script" 2>&1)"
    [[ "$out" == *OK* ]] || die "创建远端目录失败：$remote_path\n$out"
}

# 轮询首次扫描进度（以本地为准）
_wait_folder_scan() {
    local folder_id="$1"
    log_info "等待文件夹 [$folder_id] 完成首次扫描..."
    local waited=0 max_wait=300
    while (( waited < max_wait )); do
        local status; status="$(local_api_call GET "/rest/db/status?folder=${folder_id}" 2>/dev/null)" || status=""
        local state
        if has_cmd jq; then
            state="$(echo "$status" | jq -r '.state // "unknown"' 2>/dev/null)"
        else
            state="$(echo "$status" | grep -oE '"state":"[^"]+"' | head -1 | sed -E 's/"state":"([^"]+)"/\1/')"
        fi
        case "$state" in
            idle)    printf "\n"; log_ok "[$folder_id] 扫描完成（idle）"; return 0 ;;
            scanning|syncing) printf "." ;;
            *)       printf "?" ;;
        esac
        sleep 2; ((waited+=2))
    done
    printf "\n"
    log_warn "[$folder_id] 首次扫描在 ${max_wait}s 内未结束（可能是大 Vault，正常后台继续）"
}

_share_one_vault() {
    local local_path="$1"
    local name; name="$(basename "$local_path")"
    local folder_id; folder_id="$(_sanitize_folder_id "$name")"
    local remote_path="${DEFAULT_REMOTE_ROOT}/${name}"

    log_info "═ 共享 [$name] ═"
    log_info "  folderID     = $folder_id"
    log_info "  local path   = $local_path"
    log_info "  remote path  = $remote_path"

    # 幂等：若已存在同路径的本地文件夹，复用其 id
    local exist_id=""
    if has_cmd jq; then
        exist_id="$(local_api_call GET /rest/config/folders \
            | jq -r --arg p "$local_path" '.[] | select(.path == $p) | .id' | head -1)"
    fi
    if [[ -n "$exist_id" ]]; then
        log_ok "本地已存在同路径文件夹（id=${exist_id}），跳过本地添加"
        folder_id="$exist_id"
    else
        local body; body="$(mktemp)"
        # 本地端：把 SELECTED_REMOTE_DEVICES 里所有勾选的远端一起写进去
        local peer_ids=""
        local pid
        for pid in "${SELECTED_REMOTE_DEVICES[@]}"; do
            peer_ids+="${pid}"$'\n'
        done
        _make_folder_json "$folder_id" "$name" "$local_path" "$peer_ids" > "$body"
        if ! local_api_call POST /rest/config/folders "$body" >/dev/null; then
            rm -f "$body"
            die "本地添加 folder [$folder_id] 失败"
        fi
        rm -f "$body"
        ROLLBACK_STACK+=("local_folder:${folder_id}")
    fi

    # 服务器：先建目录，再调用 API
    _remote_prepare_folder_dir "$remote_path"

    if _folder_exists remote "$folder_id"; then
        log_ok "服务器已存在 folder [$folder_id]（幂等跳过）"
    else
        local body; body="$(mktemp)"
        _make_folder_json "$folder_id" "$name" "$remote_path" "$LOCAL_DEVICE_ID" > "$body"
        if ! remote_api_call POST /rest/config/folders "$body" >/dev/null; then
            rm -f "$body"
            die "服务器添加 folder [$folder_id] 失败"
        fi
        rm -f "$body"
        ROLLBACK_STACK+=("remote_folder:${folder_id}")
    fi

    SHARED_FOLDERS+=("${folder_id}	${local_path}	${remote_path}")

    _wait_folder_scan "$folder_id"
}

create_shared_folders() {
    log_step "步骤 7/8 ：建立双向文件夹共享"

    # 展示本次实际要共享到的所有远端设备（由 _select_remote_devices 在上一步确认）
    if (( ${#SELECTED_REMOTE_DEVICES[@]} > 0 )) && has_cmd jq; then
        local devices_out
        devices_out="$(local_api_call GET /rest/config/devices 2>/dev/null)" || devices_out=""
        log_info "本次将把新 Vault 共享给 ${#SELECTED_REMOTE_DEVICES[@]} 个远端设备："
        local did dname
        for did in "${SELECTED_REMOTE_DEVICES[@]}"; do
            if [[ -n "$devices_out" ]]; then
                dname="$(echo "$devices_out" | jq -r --arg d "$did" '.[] | select(.deviceID == $d) | .name' 2>/dev/null)"
            fi
            [[ -z "$dname" ]] && dname="(未命名)"
            printf "   %s▸%s %s  %s(%s)%s\n" "$C_GREEN" "$C_RESET" "$dname" "$C_GRAY" "${did:0:7}" "$C_RESET"
        done
    fi

    local v
    for v in "${SELECTED_VAULTS[@]}"; do
        _share_one_vault "$v"
    done
    log_ok "所有 ${#SELECTED_VAULTS[@]} 个 Vault 共享配置已提交"
}

# ---------------------------------------------------------------------------
# 模块：state —— 运行状态持久化
# ---------------------------------------------------------------------------
# 写入 last-run.json —— 严禁写入任何密码
save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    local folders_json="["
    local first=1
    local line
    for line in "${SHARED_FOLDERS[@]}"; do
        local fid lp rp
        fid="$(echo "$line" | awk -F'\t' '{print $1}')"
        lp="$(echo "$line"  | awk -F'\t' '{print $2}')"
        rp="$(echo "$line"  | awk -F'\t' '{print $3}')"
        [[ $first -eq 1 ]] || folders_json+=","
        first=0
        folders_json+=$(printf '{"folderID":"%s","localPath":"%s","remotePath":"%s"}' \
                        "$fid" "${lp//\"/\\\"}" "${rp//\"/\\\"}")
    done
    folders_json+="]"

    cat > "$STATE_FILE" <<JSON
{
  "version": "${SCRIPT_VERSION}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "server": {
    "host": "${SSH_HOST}",
    "user": "${SSH_USER}",
    "port": ${SSH_PORT},
    "deviceID": "${REMOTE_DEVICE_ID}",
    "runUser": "${REMOTE_RUN_USER}",
    "configPath": "${REMOTE_CONFIG_XML}"
  },
  "local": {
    "deviceID": "${LOCAL_DEVICE_ID}",
    "configPath": "${LOCAL_CONFIG_XML}"
  },
  "folders": ${folders_json}
}
JSON
    chmod 600 "$STATE_FILE"
    log_ok "运行配置已保存至：$STATE_FILE"
}

# 读取 last-run.json，用于幂等追加模式
_load_state_for_host() {
    local host="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    if has_cmd jq; then
        local saved_host
        saved_host="$(jq -r '.server.host // ""' "$STATE_FILE")"
        [[ "$saved_host" == "$host" ]]
    else
        grep -q "\"host\": \"${host}\"" "$STATE_FILE"
    fi
}

# 总结输出
print_summary() {
    log_step "步骤 8/8 ：完成"
    printf "\n"
    printf "%s%s╔══════════════════════════════════════════════════════════╗%s\n" "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf "%s%s║                  🎉  部  署  完  成                      ║%s\n" "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf "%s%s╚══════════════════════════════════════════════════════════╝%s\n" "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf "\n"

    # ── 连接信息 ────────────────────────────────
    printf "%s🔗  连接信息%s\n" "$C_BOLD" "$C_RESET"
    printf "   %s本地 Device ID%s    %s%s%s\n"   "$C_GRAY" "$C_RESET" "$C_CYAN" "$LOCAL_DEVICE_ID"  "$C_RESET"
    printf "   %s服务器 Device ID%s  %s%s%s\n"   "$C_GRAY" "$C_RESET" "$C_CYAN" "$REMOTE_DEVICE_ID" "$C_RESET"
    printf "   %s服务器地址%s        %s%s%s\n" \
        "$C_GRAY" "$C_RESET" "$C_BOLD" "$SSH_HOST" "$C_RESET"
    printf "\n"

    # ── 共享文件夹 ──────────────────────────────
    printf "%s📁  共享文件夹  %s(%d 个)%s\n" "$C_BOLD" "$C_GRAY" "${#SHARED_FOLDERS[@]}" "$C_RESET"
    local line
    for line in "${SHARED_FOLDERS[@]}"; do
        local fid lp rp
        fid="$(echo "$line" | awk -F'\t' '{print $1}')"
        lp="$(echo "$line"  | awk -F'\t' '{print $2}')"
        rp="$(echo "$line"  | awk -F'\t' '{print $3}')"
        printf "   %s▸%s %s%s%s\n"    "$C_GREEN" "$C_RESET" "$C_BOLD" "$fid" "$C_RESET"
        printf "       %s本地%s   %s\n" "$C_GRAY" "$C_RESET" "$lp"
        printf "       %s  ↕%s\n"       "$C_MAGENTA" "$C_RESET"
        printf "       %s远端%s   %s:%s\n" "$C_GRAY" "$C_RESET" "$SSH_HOST" "$rp"
    done
    printf "\n"

    # ── 访问入口 ────────────────────────────────
    printf "%s🌐  访问入口%s\n" "$C_BOLD" "$C_RESET"
    printf "   %s本地 Syncthing GUI%s   %s%s%s\n" \
        "$C_GRAY" "$C_RESET" "$C_CYAN" "$LOCAL_API_URL" "$C_RESET"
    printf "   %s远端 GUI（SSH 隧道转发，安全加密）%s\n" "$C_GRAY" "$C_RESET"
    printf "       %s第 1 步%s 在 Mac 另开一个终端窗口，执行：\n" "$C_BOLD" "$C_RESET"
    printf "         %s$ ssh -L 8385:127.0.0.1:8384 -p %s %s@%s%s\n" \
        "$C_DIM" "$SSH_PORT" "$SSH_USER" "$SSH_HOST" "$C_RESET"
    printf "       %s第 2 步%s 在 Mac 浏览器访问（下面的 127.0.0.1 指的是你这台 Mac，%s不是服务器%s）：\n" \
        "$C_BOLD" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf "         %shttp://127.0.0.1:8385%s\n" "$C_CYAN" "$C_RESET"
    printf "       %s说明%s 远端 Syncthing GUI 默认只监听 127.0.0.1:8384，公网无法直连；\n" \
        "$C_BOLD" "$C_RESET"
    printf "            通过 SSH 隧道把它安全转发到 Mac 本地的 8385 端口来访问。\n"
    if [[ -n "$REMOTE_GUI_USER" ]]; then
        printf "       %s登录账号%s  %s%s%s  /  %s%s%s\n" \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$REMOTE_GUI_USER" "$C_RESET" "$C_BOLD" "$REMOTE_GUI_PASS" "$C_RESET"
    fi
    printf "\n"

    # ── 下一步提示 ──────────────────────────────
    printf "%s💡  接下来%s\n" "$C_BOLD" "$C_RESET"
    printf "   %s•%s 在任一端新增 / 修改 / 删除笔记，另一端会自动同步\n" "$C_GREEN" "$C_RESET"
    printf "   %s•%s 如果看到冲突文件（%s.sync-conflict-*%s），保留你想要的版本即可\n" \
        "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf "   %s•%s 想新增同步目录？再次运行本脚本，选择 %s追加模式%s\n" \
        "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "\n"
}

save_state_and_summary() {
    save_state
    print_summary
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
print_banner() {
    printf "\n"
    printf "%s%s" "$C_BOLD" "$C_CYAN"
    cat <<'EOF'
 ╔══════════════════════════════════════════════════════════╗
 ║                                                          ║
 ║        📓  Obsidian 云端同步助手                         ║
 ║              —— 一键让笔记在 Mac 与云服务器之间自动同步  ║
 ║                                                          ║
 ╚══════════════════════════════════════════════════════════╝
EOF
    printf "%s" "$C_RESET"
    printf "   %s由 Syncthing 驱动  ·  端到端加密  ·  双向实时同步%s\n" "$C_GRAY" "$C_RESET"
    printf "\n"
}

# ---------------------------------------------------------------------------
# 动作选择菜单：由用户决定本次运行要做什么
#   1) install —— 全新部署（服务器装 Syncthing + 本地配对 + 共享目录）
#   2) append  —— 追加目录同步（复用既有部署，只新增要同步的 Vault）
#   3) uninstall —— 卸载（清理远端 Syncthing 服务/配置/数据 与本地状态）
#
# 注意：为不破坏既有逻辑，这里仅返回用户选择，实际流程由 main() 中的分支执行。
#       追加模式 vs 全新部署的"自动识别"逻辑（_load_state_for_host）仍保留，
#       当用户选择 install 时：如果状态文件里已有同一 host，会按原有流程询问是否走追加。
# ---------------------------------------------------------------------------
ACTION=""   # install | append | uninstall
choose_action() {
    local has_state=0
    [[ -f "$STATE_FILE" ]] && has_state=1

    printf "\n"
    printf "%s%s请选择本次要执行的操作：%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf "   %s1)%s 🆕  %s安装 Syncthing 并建立同步%s\n" \
        "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "       %s首次使用、或还没有部署过的服务器选这个。%s\n" "$C_GRAY" "$C_RESET"
    printf "   %s2)%s ➕  %s追加同步目录（复用已有部署）%s\n" \
        "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    if (( has_state == 1 )); then
        printf "       %s本机检测到过往部署记录，推荐选这个来新增同步目录。%s\n" \
            "$C_GRAY" "$C_RESET"
    else
        printf "       %s（本机暂无部署记录，选此项将无法复用，请优先选 1）%s\n" \
            "$C_GRAY" "$C_RESET"
    fi
    printf "   %s3)%s 🗑   %s卸载 Syncthing（远端 / 本地 / 两者）%s\n" \
        "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "       %s停止服务并清理配置与数据，仅保留 Syncthing 可执行程序本身。%s\n" \
        "$C_GRAY" "$C_RESET"
    printf "\n"

    local choice
    while :; do
        if ! read -r -p "$(printf "请输入编号 [1/2/3，默认 1]: ")" choice; then
            printf "\n" >&2
            die "读取输入失败：stdin 已关闭（非交互环境）。请在终端中直接运行本脚本。"
        fi
        choice="${choice:-1}"
        case "$choice" in
            1|install)    ACTION="install";   break ;;
            2|append|add) ACTION="append";    break ;;
            3|uninstall|remove|rm) ACTION="uninstall"; break ;;
            *) log_warn "无效输入：$choice（请输入 1 / 2 / 3）" ;;
        esac
    done
    log_info "已选择操作：$ACTION"
}

# ---------------------------------------------------------------------------
# 卸载流程：fzf 多选（TAB 勾选；默认勾选远端），降级时为数字菜单
#   · 远端   —— 停服务 + 禁用开机自启 + 删配置/数据（可选删二进制）
#   · 本地   —— 停本地 Syncthing + 删 ~/Library/Application Support/Syncthing
#                + 删 ~/.obsidian-sync/last-run.json + 钥匙串密码
# 每一步都显式二次确认，支持用户随时中止。
# ---------------------------------------------------------------------------
uninstall_syncthing() {
    log_step "卸载 Syncthing"

    printf "\n"
    printf "%s%s请选择卸载范围：%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

    local do_remote=0 do_local=0

    # 若已有历史部署记录，展示服务器 host 帮助用户识别
    local saved_host=""
    if has_cmd jq && [[ -f "$STATE_FILE" ]]; then
        saved_host="$(jq -r '.server.host // ""' "$STATE_FILE" 2>/dev/null)"
    fi
    local remote_label="远端服务器"
    [[ -n "$saved_host" ]] && remote_label="远端服务器（${saved_host}）"

    if has_cmd fzf; then
        # fzf 多选模式：TAB 勾选/取消，ENTER 确认，ESC 取消
        printf "   %s操作提示%s：%sTAB%s 勾选/取消  ·  %sENTER%s 确认  ·  %sESC%s 取消\n" \
            "$C_GRAY" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf "   %s默认已勾选 %s%s远端%s%s（直接回车即可卸载远端）%s\n\n" \
            "$C_GRAY" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET"

        local fzf_input
        fzf_input=$(printf "%s\n%s\n" \
            "remote|${remote_label}" \
            "local|本机（Mac）Syncthing 配置与脚本状态")

        local selected
        # --multi 多选；--bind "load:toggle" 让第一项默认选中（即 remote）
        selected="$(printf "%s" "$fzf_input" | fzf \
            --multi \
            --height=40% \
            --layout=reverse \
            --border \
            --header=$'请按 TAB 勾选要卸载的范围（默认已勾选远端），回车确认' \
            --prompt='卸载范围> ' \
            --delimiter='|' --with-nth=2 \
            --bind='load:pos(1)+toggle' \
            2>/dev/null || true)"

        if [[ -z "$selected" ]]; then
            log_info "未选择任何项，已取消卸载。"
            return 0
        fi

        while IFS= read -r line; do
            case "${line%%|*}" in
                remote) do_remote=1 ;;
                local)  do_local=1  ;;
            esac
        done <<< "$selected"
    else
        # 降级方案：数字菜单（fzf 未安装时）
        printf "   %s1)%s 仅卸载%s远端服务器%s上的 Syncthing（需提供 SSH）%s ← 默认%s\n" \
            "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET"
        printf "   %s2)%s 仅清理%s本机（Mac）%s的 Syncthing 配置与脚本状态\n" \
            "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf "   %s3)%s %s远端 + 本地%s 一起卸载（彻底恢复到部署前）\n" \
            "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf "   %s0)%s 取消\n" "$C_GRAY" "$C_RESET"
        printf "\n"

        local scope=""
        while :; do
            if ! read -r -p "$(printf "请输入编号 [1/2/3/0，默认 1]: ")" scope; then
                printf "\n" >&2
                die "读取输入失败：stdin 已关闭（非交互环境）。"
            fi
            scope="${scope:-1}"
            case "$scope" in
                1) do_remote=1; do_local=0; break ;;
                2) do_remote=0; do_local=1; break ;;
                3) do_remote=1; do_local=1; break ;;
                0) log_info "已取消卸载。"; return 0 ;;
                *) log_warn "无效输入：$scope" ;;
            esac
        done
    fi

    # 回显用户选择，便于在正式执行前再次核对
    local summary=""
    (( do_remote == 1 )) && summary+="远端 "
    (( do_local  == 1 )) && summary+="本地 "
    log_info "即将卸载：${summary% }"

    # ---------- 远端卸载 ----------
    if (( do_remote == 1 )); then
        log_step "远端 Syncthing 卸载"
        # 采集 SSH 信息（复用既有流程：会回填 last-run.json 里的 host/user/port）
        collect_user_input

        # 远端运行用户：优先读 last-run.json，其次默认使用 SSH_USER
        local remote_user="$SSH_USER"
        if has_cmd jq && [[ -f "$STATE_FILE" ]]; then
            local saved_user
            saved_user="$(jq -r '.server.runUser // ""' "$STATE_FILE" 2>/dev/null)"
            [[ -n "$saved_user" ]] && remote_user="$saved_user"
        fi
        log_info "将卸载的 systemd 服务：syncthing@${remote_user}.service"

        echo
        log_info "即将在 ${SSH_USER}@${SSH_HOST}:${SSH_PORT} 上执行以下操作："
        log_info "  - systemctl stop / disable syncthing@${remote_user}.service"
        log_info "  - 删除 /etc/systemd/system/syncthing@.service（如存在且由本脚本安装）"
        log_info "  - 删除 ~${remote_user}/.config/syncthing 与 /data/obsidian"
        echo

        local purge_bin="N"
        if confirm "是否同时卸载 Syncthing 二进制（apt 包 / 自行下载的 /usr/local/bin/syncthing）？" "N"; then
            purge_bin="Y"
            log_info "  (+) 额外：卸载 Syncthing 二进制（apt remove syncthing 或删除 /usr/local/bin/syncthing）"
        fi

        echo
        # 总确认默认改为 Y：用户已经从主菜单选了"卸载"，又勾选了"远端"，
        # 直接回车应该"继续执行"而不是"取消"（原先默认 N 容易让人误以为脚本卡住）。
        if ! confirm "以上操作不可恢复，直接回车即开始卸载。是否继续？" "Y"; then
            log_info "已取消远端卸载。"
        else
            local purge_bin_flag="$purge_bin"
            local uninstall_script='
set -u
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
RUN_USER="'"$remote_user"'"
PURGE_BIN="'"$purge_bin_flag"'"

echo "==> 停止并禁用 syncthing@${RUN_USER}.service"
$sudo_cmd systemctl stop    "syncthing@${RUN_USER}.service" 2>/dev/null || true
$sudo_cmd systemctl disable "syncthing@${RUN_USER}.service" 2>/dev/null || true
$sudo_cmd systemctl stop    "syncthing@*" 2>/dev/null || true

echo "==> 删除由脚本写入的 systemd unit（如存在）"
if [ -f /etc/systemd/system/syncthing@.service ]; then
    # 只删脚本自己写进 /etc/systemd/system 的那份；发行版自带的 /lib/systemd/... 保留
    $sudo_cmd rm -f /etc/systemd/system/syncthing@.service
fi
$sudo_cmd systemctl daemon-reload 2>/dev/null || true

echo "==> 删除配置目录 ~${RUN_USER}/.config/syncthing"
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6)"
[ -z "$RUN_HOME" ] && RUN_HOME="/root"
$sudo_cmd rm -rf "${RUN_HOME}/.config/syncthing"

echo "==> 删除数据目录 /data/obsidian"
$sudo_cmd rm -rf /data/obsidian

if [ "$PURGE_BIN" = "Y" ]; then
    echo "==> 卸载 Syncthing 二进制"
    if command -v apt-get >/dev/null 2>&1 && dpkg -l syncthing >/dev/null 2>&1; then
        $sudo_cmd apt-get remove -y syncthing 2>/dev/null || true
    fi
    if command -v yum >/dev/null 2>&1 && rpm -q syncthing >/dev/null 2>&1; then
        $sudo_cmd yum remove -y syncthing 2>/dev/null || true
    fi
    # 自行下载放到 /usr/local/bin 的二进制
    [ -f /usr/local/bin/syncthing ] && $sudo_cmd rm -f /usr/local/bin/syncthing
fi

echo "==> 完成"
'
            if ssh_exec_script "$uninstall_script"; then
                log_ok "远端卸载完成"
            else
                log_warn "远端卸载脚本返回非零，可能部分步骤未成功，请登录服务器手动复核。"
            fi

            # 远端已经被物理卸载了，本地 Syncthing 里保留的「该设备 + 共享给它的 folder」已经毫无意义。
            # 这里主动把本地配置同步清理掉：删除远端设备；对每个 folder 把该设备从 devices 列表里移除；
            # 如果某个 folder 移除后没有其他共享对象（只剩本机自己），就顺带把整个 folder 也删了。
            _local_prune_after_remote_uninstall
        fi
    fi

    # ---------- 本地清理 ----------
    if (( do_local == 1 )); then
        log_step "本地（Mac）清理"

        echo
        log_info "即将在本机执行以下操作："
        log_info "  - 停止本地 Syncthing（brew services stop / 关闭 Syncthing.app）"
        log_info "  - 删除 ~/Library/Application Support/Syncthing（包含 config.xml 与索引数据库）"
        log_info "  - 删除脚本状态文件：$STATE_FILE"
        log_info "  - 清除钥匙串中保存的 SSH 密码（service=obsidian-sync-ssh）"
        log_info "  · 不会删除 /Applications/Syncthing.app 或 brew 安装的 syncthing 可执行文件"
        log_info "  · 不会删除你的 Obsidian 笔记本目录"
        echo
        if ! confirm "确认执行以上本地清理？直接回车即开始执行。" "Y"; then
            log_info "已取消本地清理。"
        else
            log_info "停止本地 Syncthing..."
            # 1) brew services
            if has_cmd brew && brew services list 2>/dev/null | grep -q "^syncthing"; then
                brew services stop syncthing >/dev/null 2>&1 || true
            fi
            # 2) Syncthing.app
            if [[ -d "/Applications/Syncthing.app" ]]; then
                osascript -e 'tell application "Syncthing" to quit' >/dev/null 2>&1 || true
            fi
            # 3) 残余进程兜底
            pkill -f "syncthing( |$)" 2>/dev/null || true
            sleep 1
            if pgrep -f "syncthing( |$)" >/dev/null 2>&1; then
                log_warn "仍检测到 syncthing 进程，尝试强制结束..."
                pkill -9 -f "syncthing( |$)" 2>/dev/null || true
            fi
            log_ok "本地 Syncthing 已停止"

            # 删本地配置（这是保留笔记本、只删 Syncthing 状态的关键）
            local local_cfg_dir="${HOME}/Library/Application Support/Syncthing"
            if [[ -d "$local_cfg_dir" ]]; then
                rm -rf "$local_cfg_dir"
                log_ok "已删除：$local_cfg_dir"
            else
                log_info "未发现本地配置目录（可能从未启动或已清理）：$local_cfg_dir"
            fi
            # 个别版本会落到 ~/.config/syncthing
            if [[ -d "${HOME}/.config/syncthing" ]]; then
                rm -rf "${HOME}/.config/syncthing"
                log_ok "已删除：${HOME}/.config/syncthing"
            fi

            # 脚本状态
            if [[ -f "$STATE_FILE" ]]; then
                rm -f "$STATE_FILE"
                log_ok "已删除状态文件：$STATE_FILE"
            fi

            # 钥匙串
            if has_cmd security; then
                security delete-generic-password -s obsidian-sync-ssh >/dev/null 2>&1 \
                    && log_ok "已从钥匙串移除 SSH 密码（obsidian-sync-ssh）" \
                    || log_info "钥匙串中未找到 obsidian-sync-ssh 条目（跳过）"
            fi

            log_ok "本地清理完成"
        fi
    fi

    echo
    log_ok "卸载流程结束 ✔"
    printf "\n   %s提示%s：如需重新部署，再次运行本脚本并选择 %s1) 安装%s 即可。\n\n" \
        "$C_GRAY" "$C_RESET" "$C_BOLD" "$C_RESET"
}

main() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    print_banner
    log_info "版本：$SCRIPT_VERSION"

    check_dependencies

    # 先询问用户本次要做什么（install / append / uninstall）
    choose_action

    # 卸载是独立分支，完全不走部署与配对流程
    if [[ "$ACTION" == "uninstall" ]]; then
        uninstall_syncthing
        exit 0
    fi

    # append 模式：要求状态文件存在，否则退回 install
    if [[ "$ACTION" == "append" && ! -f "$STATE_FILE" ]]; then
        log_warn "未找到过往部署记录（$STATE_FILE），无法进入追加模式，自动切换为安装模式。"
        ACTION="install"
    fi

    collect_user_input

    # 幂等：如果同一服务器之前已部署，则询问进入"追加目录"模式
    local append_mode=0
    if _load_state_for_host "$SSH_HOST"; then
        # 用户在主菜单已经明确选了 append：直接进入追加模式，不再二次确认
        if [[ "$ACTION" == "append" ]]; then
            append_mode=1
            log_info "按用户选择，进入追加同步目录模式。"
        # 用户在主菜单明确选了 install：按"重新部署"处理，不再询问是否追加
        elif [[ "$ACTION" == "install" ]]; then
            log_info "按用户选择，执行重新部署（覆盖已有记录）。"
        else
            echo
            log_info "检测到 ${SSH_HOST} 已在 ${STATE_FILE} 记录中部署过。"
            log_info "你可以选择："
            printf "   %s•%s 进入 %s追加同步目录%s 模式：复用已有部署，只新增要同步的 Vault（推荐）\n" \
                "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
            printf "   %s•%s 或者 %s重新部署%s：覆盖重装一遍（用于修复异常）\n" \
                "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
            echo
            if confirm "是否进入'追加同步目录'模式（跳过服务器部署与本地安装）？" "Y"; then
                append_mode=1
            fi
        fi
        # append_mode=1 时从 last-run.json 恢复必要字段
        if (( append_mode == 1 )) && has_cmd jq; then
            REMOTE_DEVICE_ID="$(jq -r '.server.deviceID // ""' "$STATE_FILE")"
            REMOTE_RUN_USER="$(jq -r '.server.runUser // ""'  "$STATE_FILE")"
            REMOTE_CONFIG_XML="$(jq -r '.server.configPath // ""' "$STATE_FILE")"
            LOCAL_DEVICE_ID="$(jq -r '.local.deviceID // ""' "$STATE_FILE")"
            LOCAL_CONFIG_XML="$(jq -r '.local.configPath // ""' "$STATE_FILE")"
        fi
    elif [[ "$ACTION" == "append" ]]; then
        # 状态文件里找不到当前 SSH_HOST 的记录，追加模式无法进行
        log_warn "状态文件中未找到 ${SSH_HOST} 的部署记录，无法追加；自动切换为安装模式。"
        ACTION="install"
    fi

    if (( append_mode == 0 )); then
        deploy_remote_syncthing
        setup_remote_api_tunnel
        install_local_syncthing
        pair_devices
    else
        log_step "进入追加模式：跳过部署，建立 API 通道并沿用现有 Device ID"
        # 追加模式下仍需：读远端 API Key、建 SSH 隧道、读本地 API Key
        log_info "[1/6] 探测远端 HOME 目录..."
        REMOTE_HOME="$(ssh_exec_quiet 'echo $HOME' | tr -d '\r')"
        [[ -n "$REMOTE_HOME" ]] || die "追加模式：无法获取远端 HOME（SSH 连接异常？）"
        [[ -z "$REMOTE_CONFIG_XML" ]] && REMOTE_CONFIG_XML="${REMOTE_HOME}/.config/syncthing/config.xml"

        log_info "[2/6] 读取远端 Syncthing API Key：$REMOTE_CONFIG_XML"
        local akey_script='
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
if [ ! -f "'"$REMOTE_CONFIG_XML"'" ]; then
    echo "__CONFIG_NOT_FOUND__"
    exit 0
fi
$sudo_cmd grep -oE "<apikey>[^<]+</apikey>" "'"$REMOTE_CONFIG_XML"'" | sed -E "s/<\\/?apikey>//g"
'
        REMOTE_API_KEY="$(ssh_exec_script "$akey_script" | tr -d '\r\n')"
        if [[ "$REMOTE_API_KEY" == *__CONFIG_NOT_FOUND__* ]]; then
            die "追加模式：远端 config.xml 不存在（$REMOTE_CONFIG_XML）。可能服务器上的 Syncthing 配置已被清空，请删除 $STATE_FILE 后重新完整部署。"
        fi
        [[ -n "$REMOTE_API_KEY" ]] || die "追加模式：无法从服务器读取 API Key（config.xml 里没有 <apikey> 节点）。建议删除 $STATE_FILE 后重新完整部署。"

        log_info "[3/6] 建立本地到远端的 SSH 隧道..."
        _setup_ssh_tunnel
        log_info "[4/6] 校验远端 Syncthing API..."
        _verify_remote_api
        # 本地
        log_info "[5/6] 启动本地 Syncthing 并读取身份..."
        _local_start_syncthing
        _local_read_identity
        _local_verify_api
        # 确认 device id 与记录一致
        log_info "[6/6] 核对本地已配对的远端 Device..."
        if ! _device_exists local "$REMOTE_DEVICE_ID"; then
            log_warn "本地未发现记录中的服务器 Device，重新执行配对..."
            pair_devices
        fi
        log_ok "追加模式通道就绪"
    fi

    select_obsidian_vaults
    _select_remote_devices
    create_shared_folders
    save_state_and_summary

    log_ok "全流程完成 ✔"
}

main "$@"