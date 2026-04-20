# Obsidian 同步工具 - Windows 版本

基于 Syncthing 的 Windows ↔ Linux Obsidian 一键同步工具。

## 🚀 快速开始

### 系统要求
- **操作系统**: Windows 10/11
- **PowerShell**: 5.1 或更高版本
- **网络**: 可访问目标 Linux 服务器

### 安装步骤

1. **下载脚本**
   ```powershell
   # 克隆仓库或直接下载脚本
   git clone https://github.com/chenp0401/obsidian2linux.git
   cd obsidian2linux
   ```

2. **运行脚本**
   ```powershell
   # 以管理员权限运行 PowerShell，然后执行：
   PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
   ```

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

### 必需依赖
脚本会自动检查并安装以下依赖：

| 依赖 | 用途 | Windows 安装方式 |
|------|------|------------------|
| **OpenSSH** | SSH 客户端连接 | `choco install openssh -y` |
| **curl** | HTTP API 调用 | `choco install curl -y` |
| **Chocolatey** | 包管理器 | 自动安装 |

### 可选依赖
| 依赖 | 用途 | 安装方式 |
|------|------|----------|
| **sshpass** | 非交互式 SSH 登录 | `choco install sshpass -y` |
| **jq** | JSON 解析 | `choco install jq -y` |
| **fzf** | 目录多选界面 | `choco install fzf -y` |

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