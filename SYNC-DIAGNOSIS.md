# Obsidian 同步问题诊断指南

## 🔧 快速诊断

如果遇到同步问题，可以使用诊断模式快速排查：

```powershell
# 运行完整诊断（推荐）
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 diagnose

# 或者指定文件夹ID进行诊断
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1 diagnose -FolderId Win10-vaulte-4l5us
```

## 📋 常见问题排查

### 1. 端口连通性问题
```powershell
# 检查端口22000是否连通
Test-NetConnection 43.163.113.77 -Port 22000
```

**如果失败：**
- 检查云服务器安全组是否开放22000端口
- 检查服务器防火墙设置
- 确认网络连接正常

### 2. 本地Syncthing服务状态
```powershell
# 检查本地服务是否运行
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/system/ping" -Method GET
```

**如果失败：**
- 检查本地Syncthing是否启动
- 查看日志：`C:\Users\陈洁\.obsidian-sync\local-syncthing.log`

### 3. 设备连接状态
```powershell
# 检查设备连接
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/system/connections" -Method GET
```

**如果远程设备未连接：**
- 确认远程Syncthing服务运行正常
- 检查网络连接和端口设置

### 4. 文件夹同步状态
```powershell
# 检查特定文件夹状态
Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/db/status?folder=Win10-vaulte-4l5us" -Method GET
```

**关键字段说明：**
- `state`: 同步状态（idle/scanning/syncing）
- `globalBytes`: 已同步字节数
- `needBytes`: 等待同步字节数
- `error`: 错误信息（如果有）

## 🚨 紧急修复步骤

### 如果同步完全失败：

1. **重启本地Syncthing服务**
```powershell
# 停止服务
Stop-Process -Id (Get-Content 'C:\Users\陈洁\.obsidian-sync\local-syncthing.pid') -Force

# 重新运行脚本
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
```

2. **重新配置文件夹**
```powershell
# 删除现有配置后重新运行
Remove-Item 'C:\Users\陈洁\.obsidian-sync\last-run.json' -Force
PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
```

3. **检查文件权限**
```powershell
# 确保本地文件夹可访问
test-path 'C:\Users\陈洁\Documents\Obsidian\Win10 vaulte'

# 检查文件数量
(Get-ChildItem 'C:\Users\陈洁\Documents\Obsidian\Win10 vaulte' -Recurse -File).Count
```

## 📊 诊断输出解读

### 正常状态
- ✅ 本地Syncthing服务运行正常
- ✅ 远程设备连接正常  
- ✅ 端口22000连通性正常
- ✅ 文件夹状态：idle，已同步 XXXX 字节

### 异常状态
- ❌ 本地服务异常 → 重启服务
- ❌ 远程设备未连接 → 检查网络和端口
- ❌ 端口无法连通 → 检查防火墙设置
- ❌ 文件夹状态异常 → 查看错误信息

## 📞 技术支持

如果以上步骤无法解决问题，请提供以下信息：

1. 运行诊断模式的完整输出
2. `C:\Users\陈洁\.obsidian-sync\local-syncthing.log` 日志文件
3. `C:\Users\陈洁\.obsidian-sync\last-run.json` 配置文件

---
*最后更新：$(Get-Date -Format "yyyy-MM-dd")*