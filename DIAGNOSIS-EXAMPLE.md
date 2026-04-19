# 同步诊断功能使用示例

## 🚀 快速开始

### 基本诊断
```powershell
# 运行完整同步诊断
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 diagnose
```

### 指定文件夹诊断
```powershell
# 诊断特定文件夹（使用上次运行的配置）
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 diagnose -FolderId Win10-vaulte-4l5us
```

## 📊 诊断输出示例

### 正常诊断结果
```
=== Obsidian 同步工具 (Windows 版本) ===
版本: 1.0.0
操作系统: Windows 10.0.19045
运行身份: [管理员]

运行同步问题诊断模式...

[INFO] 加载上次配置：服务器 43.163.113.77，设备ID F3KBECC-NASWMOT-GDWJRWC-7EIJF6I-B36SAGS-VB2W4DU-TVWPUU7-3JWRTQ5
[INFO] 诊断文件夹：Win10-vaulte-4l5us

[INFO] 检查本地Syncthing服务...
[OK] 本地Syncthing服务运行正常

[INFO] 检查设备连接状态...
[OK] 远程设备连接正常

[INFO] 检查端口连通性...
[OK] 端口22000连通性正常

[INFO] 检查文件夹状态...
[INFO] 文件夹状态：
[INFO]   - 状态: idle
[INFO]   - 本地字节: 7428
[INFO]   - 全局字节: 7428
[INFO]   - 需要字节: 0
[INFO]   - 错误: 

[OK] 诊断完成，所有检查项正常
```

### 异常诊断结果
```
=== Obsidian 同步工具 (Windows 版本) ===
版本: 1.0.0
操作系统: Windows 10.0.19045
运行身份: [管理员]

运行同步问题诊断模式...

[INFO] 检查本地Syncthing服务...
[WARN] 无法连接本地Syncthing服务：连接被拒绝

[INFO] 检查设备连接状态...
[WARN] 连接状态检查失败：无法连接到远程服务器

[INFO] 检查端口连通性...
[WARN] 端口22000无法连通，请检查防火墙和网络设置

[INFO] 检查文件夹状态...
[WARN] 文件夹状态检查失败：无法获取文件夹信息

[OK] 诊断完成，请根据以上信息排查问题
```

## 🔧 手动诊断命令

### 1. 检查端口连通性
```powershell
Test-NetConnection 43.163.113.77 -Port 22000
```

### 2. 检查本地Syncthing服务
```powershell
# 检查服务是否运行
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/system/ping" -Method GET

# 检查设备连接
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/system/connections" -Method GET
```

### 3. 检查文件夹状态
```powershell
# 检查特定文件夹状态
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/db/status?folder=Win10-vaulte-4l5us" -Method GET
```

### 4. 查看日志文件
```powershell
# 查看本地Syncthing日志
type "C:\Users\陈洁\.obsidian-sync\local-syncthing.log"

# 查看脚本运行日志
type "C:\Users\陈洁\.obsidian-sync\run.log"
```

## 🚨 常见问题解决方案

### 问题1：端口22000无法连通
**解决方案：**
1. 检查云服务器安全组设置，确保开放22000端口
2. 检查服务器防火墙规则
3. 确认网络连接正常

### 问题2：本地Syncthing服务未启动
**解决方案：**
1. 重启本地Syncthing服务
```powershell
# 停止服务
Stop-Process -Id (Get-Content 'C:\Users\陈洁\.obsidian-sync\local-syncthing.pid') -Force

# 重新运行脚本
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
```

### 问题3：远程设备未连接
**解决方案：**
1. 检查远程服务器上的Syncthing服务是否运行
2. 确认网络连接和端口设置
3. 检查设备ID配置是否正确

### 问题4：文件夹同步异常
**解决方案：**
1. 重新配置文件夹共享
```powershell
# 删除配置后重新运行
Remove-Item 'C:\Users\陈洁\.obsidian-sync\last-run.json' -Force
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
```

## 📞 获取帮助

如果诊断结果无法解决问题，请提供以下信息：

1. 完整的诊断输出
2. 相关日志文件内容
3. 错误截图或描述

---
*最后更新：$(Get-Date -Format "yyyy-MM-dd")*