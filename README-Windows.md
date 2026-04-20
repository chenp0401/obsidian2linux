# Obsidian 同步工具 - Windows 版本

基于 Syncthing 的 Windows ↔ Linux Obsidian 一键同步工具。

## 🚀 快速开始

### 📋 前置条件（需要客户自备）

> ⚠️ 以下 6 项是**脚本无法自动帮你搞定**的，必须先准备好，否则部署会在中途失败。

| # | 项目 | 要求 | 说明 |
|---|------|------|------|
| 1 | **操作系统** | Windows 10 / Windows 11 | 旧版 Windows（7/8）未测试 |
| 2 | **PowerShell** | **强烈推荐 7.x**；最低 5.1 | 见下方【为什么推荐 PS 7】 |
| 3 | **管理员权限** | 必需 | 首次运行需要装 Chocolatey / PuTTY / OpenSSH 等 |
| 4 | **一台 Linux 云服务器** | Debian / Ubuntu / RHEL / CentOS / Rocky 等，支持 `systemd`，账号具备 `sudo` 权限 | 若没有，可参考主 [README.md](README.md#-还没有自己的服务器一键部署-openclaw) 一键买/部署 |
| 5 | **云厂商安全组放行** | `TCP 22`（SSH）+ `TCP 22000`（Syncthing）+ `UDP 22000`（QUIC）入站 | **安全组不放行，脚本就连不上；这不是脚本能替你做的** |
| 6 | **网络可直连以下站点** | GitHub Releases、chocolatey.org、the.earth.li（PuTTY 官方下载） | 公司网 / 某些代理会拦截，必要时先挂上代理或换网络 |

#### 💡 为什么推荐 PowerShell 7

脚本代码本身兼容 **PS 5.1 / 7+ 双版本**，但在实际使用中 PS 5.1 存在以下痛点：

- **代理环境容易卡死**：`Invoke-RestMethod` 在 PS 5.1 上无 `-NoProxy` 参数，遇到公司代理 / 全局代理时会把 `127.0.0.1:18384` 的流量也送去代理，导致长时间无响应（历次踩坑之一）。
- **UTF-8 输出不稳定**：PS 5.1 默认仍是系统 ANSI/GBK 编码，远程桌面环境下容易中文乱码；PS 7 原生 UTF-8，即开即用。
- **TLS 1.2 默认未启用**：PS 5.1 在 .NET Framework 下需要显式开启 TLS 1.2 才能拉 GitHub / Chocolatey；PS 7 直接可用。
- **JSON / Web API 行为差异**：PS 7 的 `ConvertFrom-Json -AsHashtable`、`Invoke-RestMethod -SkipHttpErrorCheck` 等对诊断极有帮助。

一句话：**能用 PS 7 就用 PS 7**，避坑最多。

**安装 PowerShell 7**（任选一种）：

```powershell
# 方式 1：winget（推荐，Windows 10/11 自带）
winget install --id Microsoft.PowerShell --source winget

# 方式 2：Chocolatey（如果你已装了 choco）
choco install powershell-core -y

# 方式 3：官方 MSI 下载
# https://github.com/PowerShell/PowerShell/releases/latest
```

安装完成后，用 `pwsh.exe` 启动 PowerShell 7（而不是默认的 `powershell.exe`）：

```powershell
# 检查当前 PowerShell 版本
$PSVersionTable.PSVersion    # 应显示 7.x.x

# 以管理员身份启动 PS 7
Start-Process pwsh -Verb RunAs
```

### 安装步骤

1. **下载脚本**
   ```powershell
   # 克隆仓库或直接下载脚本
   git clone https://github.com/chenp0401/obsidian2linux.git
   cd obsidian2linux
   ```

2. **运行脚本**
   ```powershell
   # 推荐：以管理员身份启动 PowerShell 7（pwsh），然后执行：
   pwsh -ExecutionPolicy Bypass -File obsidian-sync.ps1

   # 或者兼容写法（PS 5.1 / PS 7 皆可）：
   PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
   ```

   > 💡 如果 `pwsh` 命令找不到，说明还没装 PowerShell 7，回到上方【前置条件】安装一下即可。

3. **跟随向导**
   - 脚本会自动检查并安装所需依赖
   - 输入服务器连接信息
   - 自动部署 Syncthing 同步环境

### 🔧 同步问题诊断

如果遇到同步问题，可以使用诊断模式快速排查：

```powershell
# 运行同步问题诊断
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -Action diagnose
```

诊断功能会检查：
- ✅ 本地Syncthing服务状态
- ✅ 远程设备连接状态
- ✅ 端口连通性（22000端口）
- ✅ 文件夹同步状态
- ✅ 错误信息分析

详细诊断指南请参考：[SYNC-DIAGNOSIS.md](SYNC-DIAGNOSIS.md)

### 🧹 管理与卸载

脚本通过 `-Action` 参数统一管理部署后的生命周期；不传参数会弹出交互菜单：

```powershell
# 部署或新增 Vault（默认）
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -Action deploy

# 取消某个 folder 的双向共享（可选级联删数据）
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -Action remove-folder

# 解除本地 ↔ 服务器 的设备配对（可顺带清理两端 folder 配置）
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -Action unpair

# 完全卸载：停止并清理两端 Syncthing、删除本地凭据和 state 目录
# 默认不删 Vault 笔记文件，会二次确认
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -Action uninstall
```

所有破坏性操作均提供二次确认，且**默认不删除用户数据**，只有显式选择才会级联删除。


## 📋 功能特性

### ✅ 已实现功能
- **Windows 环境检测** - 自动识别操作系统和依赖
- **Chocolatey 包管理** - 自动安装缺失依赖
- **PowerShell 彩色输出** - 友好的交互界面
- **Windows 凭据管理** - 安全存储 SSH 密码
- **SSH 连接测试** - 验证服务器连通性

### 🔄 同步功能（开发中）
- **Syncthing 自动安装** - Windows 和 Linux 端
- **双向同步配置** - 自动创建共享文件夹
- **服务管理** - Windows 服务自动启动
- **状态持久化** - 记录运行状态和配置

## 🔧 依赖管理

### 必需依赖（脚本会自动检查并安装）

| 依赖 | 用途 | Windows 安装方式 |
|------|------|------------------|
| **Chocolatey** | 包管理器，后续所有依赖靠它 | 脚本自动安装；也可手动装（见下文） |
| **OpenSSH** | SSH 客户端连接 | `choco install openssh -y` |
| **curl** | HTTP API 调用 | Windows 10/11 自带；缺失时 `choco install curl -y` |
| **plink.exe**（PuTTY） | **Windows 下非交互式 SSH 的首选**，脚本会优先用它替代 sshpass | `choco install putty.portable -y`；失败时脚本会自动从 the.earth.li 直连下载 |

### 可选依赖
| 依赖 | 用途 | 安装方式 |
|------|------|----------|
| **sshpass** | 非交互式 SSH 登录（plink 不可用时的备选） | `choco install sshpass -y` |
| **jq** | JSON 解析（缺失时回退到 PowerShell 原生 `ConvertFrom-Json`） | `choco install jq -y` |
| **fzf** | 目录多选 TUI（缺失时降级为数字菜单） | `choco install fzf -y` |

## 🔥 云厂商安全组 / 防火墙放行清单（必做）

> 脚本会自动配置**服务器内部**的 `ufw` / `firewalld`，但**云厂商控制台的安全组 / 轻量防火墙必须你自己在网页上点一下放行**，否则 SSH 都进不去，更别提同步。

### ✅ 必须放行（缺一不可）

| 协议/端口 | 方向 | 用途 | 建议来源 |
|-----------|------|------|----------|
| `TCP 22` | 入站 | SSH 登录 —— 脚本的一切远端操作都基于 SSH | 本机公网 IP/32 最佳 |
| `TCP 22000` | 入站 | Syncthing 设备间同步（TCP 通道，文件主力传输） | `0.0.0.0/0` |
| `UDP 22000` | 入站 | Syncthing 同步的 QUIC 通道（NAT 穿透 / 弱网主力） | `0.0.0.0/0` |

### 🟡 可选放行

| 协议/端口 | 方向 | 用途 | 说明 |
|-----------|------|------|------|
| `UDP 21027` | 入站 | Syncthing 局域网发现（广播） | 纯公网服务器基本用不上 |

### 🔒 强烈建议「不要」对公网开放

| 协议/端口 | 原因 |
|-----------|------|
| `TCP 8384` | Syncthing Web UI。脚本已通过 `ssh -L 18384:127.0.0.1:8384` 建立本地端口转发，你在本机访问的是 `http://127.0.0.1:18384`；**公网暴露 8384 = 任何人能扫到你的 Syncthing 后台**。 |

**腾讯云控制台直达入口**
- CVM 安全组：<https://console.cloud.tencent.com/cvm/securitygroup>
- 轻量应用服务器防火墙：<https://console.cloud.tencent.com/lighthouse/instance/index> → 实例详情 → 防火墙

**Windows 端快速自检端口连通性**（部署前先验一下）：
```powershell
Test-NetConnection <服务器IP> -Port 22       # SSH
Test-NetConnection <服务器IP> -Port 22000    # Syncthing TCP
```

## 🛠️ 手动安装依赖

如果自动安装失败，可以手动安装：

```powershell
# 1. 以管理员身份运行 PowerShell
# 2. 安装 Chocolatey（如果未安装）
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 3. 安装必需依赖
choco install openssh curl -y

# 4. 安装可选依赖（推荐）
choco install sshpass jq fzf -y
```

## 📁 文件结构

```
obsidian2linux/
├── obsidian-sync.ps1      # Windows 主脚本
├── obsidian-sync.sh       # Linux/macOS 脚本
├── README-Windows.md      # Windows 使用说明（本文档）
├── README.md              # 通用说明文档
├── LICENSE                # MIT 许可证
└── .gitignore            # Git 忽略文件
```

## 🔒 安全性说明

- **密码安全**: SSH 密码存储在 Windows 凭据管理器中
- **加密传输**: Syncthing 使用端到端加密
- **本地优先**: 所有笔记文件存储在本地磁盘
- **无云依赖**: 不依赖任何第三方云服务

## 🐛 故障排除

### 常见问题

#### 1. PowerShell 执行策略限制
```powershell
# 解决方案：临时放宽执行策略
Set-ExecutionPolicy Bypass -Scope Process -Force
```

#### 2. Chocolatey 安装失败
```powershell
# 检查网络连接，然后重试安装
ping community.chocolatey.org
```

#### 3. SSH 连接失败
- 检查服务器 IP/端口是否正确
- 确认防火墙设置
- 验证用户名和密码

#### 4. 依赖检测失败
```powershell
# 刷新环境变量
refreshenv
# 或重启 PowerShell
```

#### 5. 同步问题诊断
如果文件同步失败，使用诊断模式快速排查：

```powershell
# 运行完整诊断
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 diagnose

# 检查端口连通性
Test-NetConnection 43.163.113.77 -Port 22000

# 检查本地Syncthing服务
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/system/ping" -Method GET
```

**常见同步问题：**
- 🔴 端口22000无法连通 → 检查服务器防火墙和安全组设置
- 🔴 本地Syncthing服务未启动 → 查看 `C:\Users\陈洁\.obsidian-sync\local-syncthing.log`
- 🔴 远程设备未连接 → 检查网络连接和端口设置
- 🔴 文件夹状态异常 → 查看错误信息和同步统计

详细诊断指南请参考：[SYNC-DIAGNOSIS.md](SYNC-DIAGNOSIS.md)

### 日志文件
脚本运行日志保存在：
```
%USERPROFILE%\.obsidian-sync\run.log
```

## 🔄 与 Linux/macOS 版本对比

| 特性 | Windows 版本 | Linux/macOS 版本 |
|------|--------------|------------------|
| **脚本语言** | PowerShell | Bash |
| **包管理器** | Chocolatey | Homebrew/apt |
| **服务管理** | sc.exe | systemd |
| **凭据存储** | Windows 凭据管理器 | macOS 钥匙串 |
| **路径格式** | C:\Users\... | /home/... |

## 📞 技术支持

- **GitHub Issues**: [项目问题反馈](https://github.com/chenp0401/obsidian2linux/issues)
- **文档**: 查看 [README.md](README.md) 获取完整功能说明

## 📜 许可证

本项目采用 [MIT License](LICENSE)。

## 🙌 致谢

- **[Syncthing](https://github.com/syncthing/syncthing)** - 强大的开源同步引擎
- **[Obsidian](https://github.com/obsidianmd/obsidian-releases)** - 优秀的本地笔记应用
- **[Chocolatey](https://chocolatey.org/)** - Windows 包管理器

---

**注意**: 这是 Windows 版本的早期实现，部分高级功能仍在开发中。如有问题请反馈到 GitHub Issues。