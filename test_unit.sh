#!/usr/bin/env bash
# obsidian-sync.sh 本地单元测试（方案 A）
# 仅测试纯函数 / 低副作用函数，不动任何 Syncthing 配置
set +e  # 测试过程允许单项失败

SCRIPT="/Users/chenp/制包培训demo/obsidian-sync.sh"

# 屏蔽主流程：source 时不触发 main
export OBSIDIAN_SYNC_TEST=1

# 提取所有函数定义（从第 1 行到 main 调用之前）——用临时法：source 并阻止 main 执行
# 方案：在子 shell 中 source，main 的调用由脚本末尾触发，我们改为只 source 函数部分。
# 简单处理：直接 source 整个脚本，把末尾 main "$@" 通过环境变量屏蔽。
# 实际脚本末尾是 `main "$@"`，这里我们把它包裹成可测模式：
# 做法：读出脚本内容，把 `main "$@"` 那行替换成 `return 0` 后再 source。
TMP_SCRIPT="$(mktemp)"
# 去掉最后一行的 main "$@" 调用
sed -E 's/^main[[:space:]]+"\$@".*$/: # main disabled for test/' "$SCRIPT" > "$TMP_SCRIPT"

# set -e 在 source 里可能终止；我们在子 shell 里做
# shellcheck disable=SC1090
source "$TMP_SCRIPT" 2>/tmp/source.err
SRC_RC=$?
if (( SRC_RC != 0 )); then
    echo "❌ source 失败（rc=$SRC_RC）："
    cat /tmp/source.err
    rm -f "$TMP_SCRIPT"
    exit 1
fi
rm -f "$TMP_SCRIPT"

# 测试计数
TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0
FAIL_DETAILS=()

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    ((TESTS_RUN++))
    if [[ "$expected" == "$actual" ]]; then
        ((TESTS_PASS++))
        printf "  ✓ %s\n" "$name"
    else
        ((TESTS_FAIL++))
        printf "  ✗ %s\n    expected: [%s]\n    actual:   [%s]\n" "$name" "$expected" "$actual"
        FAIL_DETAILS+=("$name")
    fi
}

assert_rc() {
    local name="$1" expected_rc="$2" actual_rc="$3"
    ((TESTS_RUN++))
    if [[ "$expected_rc" == "$actual_rc" ]]; then
        ((TESTS_PASS++))
        printf "  ✓ %s (rc=$actual_rc)\n" "$name"
    else
        ((TESTS_FAIL++))
        printf "  ✗ %s (expected rc=$expected_rc, got rc=$actual_rc)\n" "$name"
        FAIL_DETAILS+=("$name")
    fi
}

section() { printf "\n\033[1;36m━━━ %s ━━━\033[0m\n" "$*"; }

# ---------- 测试 1：validate_host ----------
section "T1. validate_host — IP/域名校验"
validate_host "192.168.1.1"          ; assert_rc "有效 IPv4 私网地址"     0 $?
validate_host "8.8.8.8"              ; assert_rc "有效公网 IP"            0 $?
validate_host "255.255.255.255"      ; assert_rc "边界 255.255.255.255"   0 $?
validate_host "0.0.0.0"              ; assert_rc "边界 0.0.0.0"           0 $?
validate_host "256.1.1.1"            ; assert_rc "非法 256 开头"          1 $?
validate_host "192.168.1"            ; assert_rc "不完整 IP"              1 $?
validate_host "example.com"          ; assert_rc "标准域名"               0 $?
validate_host "a.b.c.example.com"    ; assert_rc "多级子域名"             0 $?
validate_host "localhost"            ; assert_rc "单标签 localhost（应拒绝）" 1 $?
validate_host ""                     ; assert_rc "空字符串"               1 $?
validate_host "192.168.1.1;rm -rf /" ; assert_rc "注入尝试"               1 $?

# ---------- 测试 2：has_cmd ----------
section "T2. has_cmd — 命令存在判定"
has_cmd "bash"                       ; assert_rc "bash 存在"              0 $?
has_cmd "ls"                         ; assert_rc "ls 存在"                0 $?
has_cmd "definitely_not_a_command_xyz"; assert_rc "不存在命令"            1 $?

# ---------- 测试 3：check_dependencies ----------
section "T3. check_dependencies — 依赖检查"
# 必需：ssh curl；推荐：sshpass jq；可选：fzf；本机均已有 ssh/curl，应返回 0
(check_dependencies >/dev/null 2>&1); assert_rc "当前机器依赖应通过" 0 $?

# ---------- 测试 4：_local_locate_config ----------
section "T4. _local_locate_config — config.xml 定位"
LOCAL_CONFIG_XML=""
(_local_locate_config); LOC_RC=$?
assert_rc "能定位本地 config.xml" 0 $LOC_RC
# 显式再取一次（函数会设置全局变量）
_local_locate_config >/dev/null
if [[ -n "$LOCAL_CONFIG_XML" && -f "$LOCAL_CONFIG_XML" ]]; then
    echo "  ✓ LOCAL_CONFIG_XML 已赋值：$LOCAL_CONFIG_XML"
    ((TESTS_RUN++)); ((TESTS_PASS++))
else
    echo "  ✗ LOCAL_CONFIG_XML 为空或不存在"
    ((TESTS_RUN++)); ((TESTS_FAIL++))
    FAIL_DETAILS+=("LOCAL_CONFIG_XML 未正确设置")
fi

# ---------- 测试 5：_local_read_identity（含 TLS 探测） ----------
section "T5. _local_read_identity — 身份解析 + TLS 自动切换（本次修复核心）"
# 清空，重新探测
LOCAL_DEVICE_ID=""
LOCAL_API_KEY=""
LOCAL_API_URL="http://127.0.0.1:8384"
_local_read_identity >/tmp/identity.log 2>&1
IR_RC=$?
assert_rc "_local_read_identity 返回 0" 0 $IR_RC

# 校验解析出的 Device ID 格式（7 段 × 7 字母数字，中间用 - 分隔）
if [[ "$LOCAL_DEVICE_ID" =~ ^([A-Z0-9]{7}-){7}[A-Z0-9]{7}$ ]]; then
    echo "  ✓ Device ID 格式正确：${LOCAL_DEVICE_ID:0:14}...${LOCAL_DEVICE_ID: -7}"
    ((TESTS_RUN++)); ((TESTS_PASS++))
else
    echo "  ✗ Device ID 格式异常：[$LOCAL_DEVICE_ID]"
    ((TESTS_RUN++)); ((TESTS_FAIL++))
fi

# 校验 API Key 非空
if [[ -n "$LOCAL_API_KEY" && ${#LOCAL_API_KEY} -ge 10 ]]; then
    echo "  ✓ API Key 已解析（长度 ${#LOCAL_API_KEY}）"
    ((TESTS_RUN++)); ((TESTS_PASS++))
else
    echo "  ✗ API Key 未解析或过短：[$LOCAL_API_KEY]"
    ((TESTS_RUN++)); ((TESTS_FAIL++))
fi

# 校验 TLS 自动切换到 https
echo "  ℹ 探测到的 LOCAL_API_URL = $LOCAL_API_URL"
assert_eq "TLS=true 时自动切换 HTTPS" "https://127.0.0.1:8384" "$LOCAL_API_URL"

# ---------- 测试 6：http_call 对 HTTPS/307 的兼容 ----------
section "T6. http_call — HTTPS 自签 + 重定向跟随（本次修复核心）"
# 此时 LOCAL_API_URL 已是 https
ping_resp="$(http_call GET "${LOCAL_API_URL}/rest/system/ping" "$LOCAL_API_KEY" 2>/tmp/http.err)"
HC_RC=$?
assert_rc "http_call GET /rest/system/ping 成功" 0 $HC_RC
if [[ "$ping_resp" == *"pong"* ]]; then
    echo "  ✓ 响应包含 pong：$ping_resp"
    ((TESTS_RUN++)); ((TESTS_PASS++))
else
    echo "  ✗ 响应异常：$ping_resp"
    cat /tmp/http.err
    ((TESTS_RUN++)); ((TESTS_FAIL++))
fi

# 再测对 http://（应被 -L 自动重定向到 https）
http_resp="$(http_call GET "http://127.0.0.1:8384/rest/system/ping" "$LOCAL_API_KEY" 2>/tmp/http2.err)"
HC2_RC=$?
assert_rc "http_call 对 HTTP 自动跟随 307 重定向" 0 $HC2_RC
[[ "$http_resp" == *"pong"* ]] && { echo "  ✓ 重定向后仍能拿到 pong"; ((TESTS_RUN++)); ((TESTS_PASS++)); } \
                               || { echo "  ✗ 重定向后响应异常：$http_resp"; ((TESTS_RUN++)); ((TESTS_FAIL++)); }

# ---------- 测试 7：_local_verify_api ----------
section "T7. _local_verify_api — 综合验证"
(_local_verify_api >/tmp/verify.log 2>&1); assert_rc "_local_verify_api 通过" 0 $?

# ---------- 测试 8：Vault 目录发现 ----------
section "T8. iCloud Obsidian Vault 发现"
ICLOUD_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"
if [[ -d "$ICLOUD_DIR" ]]; then
    VAULTS=()
    while IFS= read -r line; do VAULTS+=("$line"); done < <(find "$ICLOUD_DIR" -mindepth 1 -maxdepth 1 -type d ! -name ".*" -print | sort)
    echo "  发现 ${#VAULTS[@]} 个 Vault："
    for v in "${VAULTS[@]}"; do echo "    - $(basename "$v")"; done
    if (( ${#VAULTS[@]} > 0 )); then
        ((TESTS_RUN++)); ((TESTS_PASS++))
        echo "  ✓ Vault 枚举成功"
    else
        ((TESTS_RUN++)); ((TESTS_FAIL++))
        echo "  ✗ 未发现任何 Vault"
    fi
else
    echo "  ⚠ iCloud 目录不存在，跳过"
fi

# ---------- 测试 9：_rand_str ----------
section "T9. _rand_str — 随机字符串生成"
s1="$(_rand_str 24)"
s2="$(_rand_str 24)"
((TESTS_RUN++))
if [[ ${#s1} -eq 24 && ${#s2} -eq 24 && "$s1" != "$s2" ]]; then
    ((TESTS_PASS++)); echo "  ✓ 两次生成长度=24 且不相同：$s1 / $s2"
else
    ((TESTS_FAIL++)); echo "  ✗ 随机串异常：[$s1] [$s2]"
fi

# ---------- 测试 10：_make_device_json ----------
section "T10. _make_device_json — 设备 JSON 构造（调用方必须自行带引号）"
fake_id="AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
# 按照主脚本真实用法：addresses 参数必须是已经带 JSON 引号的字符串
json="$(_make_device_json "$fake_id" "test-dev" '"tcp://1.2.3.4:22000", "dynamic"' "false")"
((TESTS_RUN++))
if echo "$json" | jq -e '.deviceID == "'"$fake_id"'" and .name == "test-dev" and (.addresses | length == 2)' >/dev/null 2>&1; then
    ((TESTS_PASS++)); echo "  ✓ JSON 结构正确（含 2 个 addresses）"
    echo "$json" | jq -c '{deviceID, name, addresses}'
else
    ((TESTS_FAIL++)); echo "  ✗ JSON 结构错误：$json"
fi

# ---------- 总结 ----------
section "测试总结"
printf "  运行: %d  通过: %d  失败: %d\n" "$TESTS_RUN" "$TESTS_PASS" "$TESTS_FAIL"
if (( TESTS_FAIL > 0 )); then
    echo "  失败项："
    for n in "${FAIL_DETAILS[@]}"; do echo "    - $n"; done
    exit 1
fi
echo "  🎉 全部通过"
exit 0
