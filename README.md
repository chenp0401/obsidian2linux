# obsidian2linux

> 基于 [Syncthing](https://syncthing.net/) 的 **Obsidian 本地 ↔ Linux 云端一键同步工具**。
> 单脚本 · 交互式向导 · 傻瓜化部署 · 端到端加密 · 双向实时同步。

在 macOS 本地终端跑一次 `./obsidian-sync.sh`，即可自动完成：

1. 远端 Linux 服务器上的 Syncthing 部署（下载二进制 / 写 systemd 服务 / 开启 GUI 与防火墙端口）
2. 本地 macOS 的 Syncthing 安装（优先 Homebrew Cask，带菜单栏 GUI）
3. 本地与远端的设备配对（Device ID 互加、双向确认）
4. 多个 Obsidian Vault 目录的共享与实时同步
5. 运行状态持久化到 `~/.obsidian-sync/last-run.json`，下次可直接追加新 Vault

---

## ✨ 特性

- **零配置上手**：整个过程只需要回答"服务器地址 / 用户名 / 密码"等几个问题。
- **三种运行模式**：
  - 🆕 **安装**：全新部署（服务器装 Syncthing + 本地配对 + 共享目录）
  - ➕ **追加**：复用既有部署，只新增要同步的 Vault（推荐日常使用）
  - 🗑 **卸载**：停服务、清配置与数据（远端 / 本地 / 两者皆可选）
- **安全**：敏感信息（SSH 密码、API Key）仅内存驻留，日志不落盘；退出时 `trap` 清理。
- **失败回滚**：任一阶段异常，询问是否撤销本次新增的 device / folder，配置不留残渣。
- **可排障**：彩色日志、结构化运行日志 (`~/.obsidian-sync/run.log`)、失败时自动抓取远端 Syncthing 日志片段。
- **幂等**：同一台服务器重复跑也安全 —— 自动识别已部署并提示进入追加模式。

---

## 🚀 快速开始

### 🍎 macOS / Linux 版本

```bash
# 1. 克隆项目
git clone https://github.com/chenp0401/obsidian2linux.git
cd obsidian2linux

# 2. 赋予执行权限
chmod +x obsidian-sync.sh

# 3. 运行交互式向导
./obsidian-sync.sh
```

### 🪟 Windows 版本

请查看 [Windows 版本文档](README-Windows.md) 获取完整的 PowerShell 使用说明。

```powershell
# 以管理员权限运行 PowerShell，然后执行：
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
```

首次运行示例流程：

```
▶  请选择本次要执行的操作：
   1) 🆕  安装 Syncthing 并建立同步    ← 首次选这个
   2) ➕  追加同步目录（复用已有部署）
   3) 🗑   卸载 Syncthing（远端 / 本地 / 两者）
请输入编号 [1/2/3，默认 1]:
```

之后依次输入：

- 服务器 IP / 域名、SSH 端口、用户名、密码
- 远端 Syncthing 数据根目录（默认 `/data/obsidian`）
- 本机 Obsidian Vault 所在目录（默认 `~/Library/Mobile Documents/iCloud~md~obsidian/Documents`）
- 勾选要同步的 Vault（`fzf` 多选；无 `fzf` 则数字多选）

结束后脚本会打印：

- 远端 Syncthing GUI 的访问地址与一次性密码
- 本地 Syncthing GUI 的访问地址
- 状态文件路径 `~/.obsidian-sync/last-run.json`

---

## ☁️ 还没有自己的服务器？一键部署 OpenClaw

如果你还没有部署自己的 **OpenClaw**（用于跑 Syncthing / 其它自托管服务的 Linux 云端），下面两条路径任选其一即可最快上手：

- 🚀 **CVM 一键部署**：通过 [腾讯云应用 · OpenClaw 一键部署镜像](https://app.cloud.tencent.com/detail/SPU_BHGJGAFIIJ7195) 在 CVM 上快速启动，免去手动环境配置，开机即用。
- 💡 **轻量云部署**：购买 [腾讯云轻量应用服务器 2 核 4G](https://cloud.tencent.com/act/cps/redirect?redirect=38185&cps_key=722b0c190220a288e06aff97161cdc4d) 来部署 OpenClaw，**性价比高、开箱即用**，个人自托管绰绰有余。

拿到服务器后，直接回到本 README 的 [🚀 快速开始](#-快速开始) 章节，跑一次 `./obsidian-sync.sh` 即可把 Obsidian 与这台服务器打通 ✅

---

## 🖥️ Windows 版本

现已提供 Windows 专用的 PowerShell 版本！

### 📁 Windows 版本文件
- **[obsidian-sync.ps1](obsidian-sync.ps1)** - Windows PowerShell 主脚本
- **[README-Windows.md](README-Windows.md)** - Windows 专用使用说明
- **[test-windows.ps1](test-windows.ps1)** - Windows 环境测试脚本

### 🚀 Windows 快速开始
```powershell
# 以管理员权限运行 PowerShell，然后执行：
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
```

### 🔧 Windows 特有功能
- **Chocolatey 包管理** - 自动安装依赖
- **Windows 服务管理** - sc.exe 服务控制
- **Windows 凭据管理器** - 安全存储密码
- **PowerShell 彩色输出** - 友好的交互界面

详细使用说明请查看：[Windows 版本文档](README-Windows.md)

---

## 📦 系统要求

### 本地（macOS）
| 依赖      | 必需 | 说明                                   | 安装命令                                             |
| --------- | ---- | -------------------------------------- | ---------------------------------------------------- |
| `ssh`     | ✅   | 系统自带                               | —                                                    |
| `curl`    | ✅   | 系统自带                               | —                                                    |
| `sshpass` | 🔶   | 非交互式 SSH 密码登录（强烈推荐）      | `brew install hudochenkov/sshpass/sshpass`           |
| `jq`      | 🔶   | 解析 Syncthing API 返回的 JSON         | `brew install jq`                                    |
| `fzf`     | 🟡   | Vault 目录多选 TUI（无则降级数字菜单） | `brew install fzf`                                   |

> 🔶 推荐安装；🟡 可选（没有时自动降级）。脚本首次运行会检查并给出安装提示。

### 远端（Linux 服务器）

- 支持 `apt` / `dnf` / `yum` 三大包管理器（Debian / Ubuntu / RHEL / CentOS / Rocky 等）
- 建议有 `systemd`（用于开机自启 Syncthing 服务）
- 可通过 SSH 密码或密钥登录，账户需具备 `sudo` 权限

#### 🔥 云厂商安全组 / 防火墙放行清单

脚本会尝试自动配置服务器内的 `ufw` / `firewalld`，但**云厂商控制台的安全组/轻量防火墙需要你手动放行**（否则 SSH 都连不上）。

**✅ 必须放行（缺一不可）**

| 协议/端口     | 方向 | 用途                                                | 建议来源             |
| ------------- | ---- | --------------------------------------------------- | -------------------- |
| `TCP 22`      | 入站 | SSH 登录 —— 脚本的所有远端操作都基于 SSH           | 本机公网 IP/32 最佳 |
| `TCP 22000`   | 入站 | Syncthing 设备间同步（TCP 通道，文件主力传输）      | `0.0.0.0/0`          |
| `UDP 22000`   | 入站 | Syncthing 同步的 QUIC 通道（NAT 穿透 / 弱网主力）   | `0.0.0.0/0`          |

**🟡 可选放行**

| 协议/端口     | 方向 | 用途                         | 说明                                              |
| ------------- | ---- | ---------------------------- | ------------------------------------------------- |
| `UDP 21027`   | 入站 | Syncthing 局域网发现（广播） | 纯公网服务器基本用不上，同局域网多设备时才有意义 |

**🔒 强烈建议「不要」对公网开放**

| 协议/端口     | 原因                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------- |
| `TCP 8384`    | Syncthing Web UI。脚本已通过 `ssh -L 18384:127.0.0.1:8384` 建立本地端口转发，你在本机访问的是 `http://127.0.0.1:18384`，**公网暴露 8384 会让任何人扫到你的 Syncthing 后台**。 |

**腾讯云控制台直达入口**

- CVM 安全组：<https://console.cloud.tencent.com/cvm/securitygroup>
- 轻量应用服务器防火墙：<https://console.cloud.tencent.com/lighthouse/instance/index> → 实例详情 → 防火墙

> 💡 脚本在 SSH 首次握手失败时，会自动在终端打印同款清单 + 控制台链接，不需要背端口号。

---

## 🔁 日常使用

### 追加一个新 Vault

```bash
./obsidian-sync.sh
# → 选择 2) 追加同步目录
```

### 卸载

```bash
./obsidian-sync.sh
# → 选择 3) 卸载，可单选远端 / 本地 / 两者
```

---

## 🗂 目录与文件

```
obsidian2linux/
├── obsidian-sync.sh      # 主脚本（唯一入口，约 3000 行）
├── test_unit.sh          # 单元测试脚本（开发用）
└── .gitignore
```

运行时在本机生成：

```
~/.obsidian-sync/
├── last-run.json         # 部署状态（Device ID / 配置路径 / 已同步 Vault 等）
└── run.log               # 结构化运行日志（不含任何密码）
```

---

## 🛠 环境变量（高级用法）

| 变量                            | 默认 | 说明                                                                   |
| ------------------------------- | ---- | ---------------------------------------------------------------------- |
| `OBSIDIAN_SYNC_SKIP_REMOTE_LOG` | `0`  | 设为 `1` 可在失败时跳过远端日志抓取（SSH 不稳定时加快退出）             |
| `OBSIDIAN_SYNC_PEER_WAIT`       | `60` | 等待双向 TCP 连接建立的最大秒数（网络慢或防火墙严格时可调大）           |

示例：

```bash
OBSIDIAN_SYNC_PEER_WAIT=120 ./obsidian-sync.sh
```

---

## 🧩 脚本架构（开发者向）

```
ui            —— 终端交互与彩色输出
ssh           —— 远程命令执行 / 文件读写
local         —— 本地 Mac 端 Syncthing 安装与管理
remote        —— 服务器端 Syncthing 部署与管理
syncthing_api —— Syncthing REST API 封装
state         —— 运行状态持久化（last-run.json）
```

主流程由 `main()` 统一调度：依赖检查 → 选择动作 → 收集输入 → 部署远端 / 建立隧道 / 本地安装 → 设备配对 → 选择 Vault → 创建共享文件夹 → 保存状态。

---

## 🆘 排障

- **想看完整运行日志**：`less ~/.obsidian-sync/run.log`
- **远端 Syncthing 状态**：`ssh user@host 'systemctl --user status syncthing'`（或 `systemctl status syncthing@用户名`）
- **端口是否通**：`nc -zv <服务器IP> 22` 检查 SSH；`nc -zv <服务器IP> 22000` 检查 Syncthing TCP 通道
- **UDP 端口自检**：`nc -zuv <服务器IP> 22000`（macOS 上 `nc` 对 UDP 探测不完全可靠，失败不一定代表不通，以 Syncthing GUI 里 `Connected (TCP/QUIC)` 状态为准）
- **重新来一次**：删除 `~/.obsidian-sync/last-run.json` 后重跑脚本，可触发全新部署。
- **已有 Syncthing 冲突**：脚本在安装阶段会检测并清理包管理器装的旧版 Syncthing，如遇异常可手动 `apt purge syncthing` / `dnf remove syncthing` 后重跑。

---

## 🔐 安全说明

- SSH 密码与 Syncthing API Key **仅驻留内存**，脚本退出时通过 `trap` 主动 `unset`。
- 运行日志 (`run.log`) **不记录任何密码**，仅包含步骤与非敏感字段。
- macOS 上可选将 SSH 密码写入 **Keychain**（`security` 命令），避免重复输入。
- Syncthing 自身使用 TLS + 每台设备唯一的 Device ID 做端到端加密。

---

## 🔗 相关项目推荐

### 🧠 [AutoGenLLMWiki](https://github.com/chenp0401/AutoGenLLMWiki) —— 让 AI 自动生成你的个人 LLM Wiki
如果你喜欢 `obsidian2linux` 把笔记「本地优先 + 多端同步」的思路，那一定也会喜欢这个配套项目：

> **AutoGenLLMWiki** 是一个基于 [Andrej Karpathy 的 LLM Wiki 理念](https://karpathy.bearblog.dev/) 设计的**个人知识库系统**，由 AI 自动生成与维护，让每一次和大模型的对话都能沉淀成结构化、可检索、可持续演进的知识资产。

- 🤖 **AI 自动建 Wiki**：把和 LLM 的高质量问答 / 调研结果，一键整理成规范的 Wiki 条目，而非散落各处的聊天记录。
- 🧩 **Karpathy 风格的知识组织**：围绕「概念 → 关联 → 索引」的方式组织条目，更贴近人脑的学习与检索习惯。
- 📂 **纯 Markdown 输出**：生成的 Wiki 文件是标准 `.md`，天然兼容 Obsidian；配合 `obsidian2linux`，可以直接**同步到 Linux 服务器、多端实时可用**。
- 🔒 **本地优先**：知识资产存在你自己的磁盘里，随时带走、随时开源、随时托管。
- 🛠 **可编程、可扩展**：支持接入不同的 LLM 后端，按自己的工作流裁剪 Prompt 与生成模板。

**推荐组合玩法 🎯**

```
LLM 对话  ──►  AutoGenLLMWiki 自动生成 Wiki 条目（Markdown）
                    │
                    ▼
              Obsidian Vault（本地优先，所见即所得）
                    │
                    ▼
        obsidian2linux（Syncthing 端到端加密同步）
                    │
                    ▼
      Linux 云端服务器 / 其它 Mac / iOS / Android 多端实时可用
```

一句话：**用 AutoGenLLMWiki 积累知识，用 Obsidian 阅读与编辑，用 obsidian2linux 跨端同步** —— 一个完整的「AI 时代个人知识资产」闭环。

> 👉 戳这里了解更多：<https://github.com/chenp0401/AutoGenLLMWiki> 欢迎 Star / Issue / PR！

---

## 📜 License

本项目采用 **[MIT License](./LICENSE)** 授权，欢迎自由使用、修改与分发。

> 注：本项目依赖的 [Syncthing](https://github.com/syncthing/syncthing) 为 [MPL-2.0](https://github.com/syncthing/syncthing/blob/main/LICENSE) 协议，版权归原项目所有，本仓库仅通过脚本调用其已发布的二进制，未对其源码进行修改或再分发。

---

## 🙌 致谢

- **[Syncthing](https://github.com/syncthing/syncthing)** —— 本项目的核心驱动。整个 `obsidian2linux` 的灵感正是来源于 Syncthing 出色的点对点、端到端加密同步能力；没有 Syncthing，就没有这个脚本。向 Syncthing 团队与所有贡献者致以最诚挚的谢意 🎉
- **[Obsidian](https://github.com/obsidianmd/obsidian-releases)** —— 强烈推荐的本地优先 Markdown 笔记应用。所有笔记以纯 `.md` 文件存在你自己的磁盘上，配合本脚本的 Syncthing 同步，即可获得「本地优先 + 多端实时同步 + 端到端加密」的完美体验。如果你还没用过，点上面的链接下载试试。
