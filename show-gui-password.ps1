# ============================================================================
# show-gui-password.ps1
# ---------------------------------------------------------------------------
# 用途：从 DPAPI 加密文件中读回 obsidian-sync 主脚本随机生成的 Syncthing GUI 密码。
# 设计原则：
#   - 只解密 CurrentUser 作用域，只有当前 Windows 用户能读回
#   - 不修改任何文件、不发网络请求，纯本地读取
#   - 支持多主机：若存在多个 obsidian-sync-gui-* 凭据文件会列表让用户选择
# ============================================================================

param(
    [Alias("Host")]
    [string]$HostName = ""   # 可选：直接指定服务器 IP/域名，跳过列表选择
)

$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:USERPROFILE ".obsidian-sync"
$CredDir  = Join-Path $StateDir "credentials"

if (-not (Test-Path $CredDir)) {
    Write-Host "❌ 未找到凭据目录: $CredDir" -ForegroundColor Red
    Write-Host "   请先运行 obsidian-sync.ps1 成功完成步骤 3/8"
    exit 1
}

# 列出所有 GUI 凭据文件
$guiCreds = Get-ChildItem -Path $CredDir -Filter "obsidian-sync-gui-*.cred" -ErrorAction SilentlyContinue
if (-not $guiCreds -or $guiCreds.Count -eq 0) {
    Write-Host "❌ 未找到任何 GUI 凭据文件（obsidian-sync-gui-*.cred）" -ForegroundColor Red
    Write-Host "   请先运行 obsidian-sync.ps1 成功完成步骤 3/8"
    exit 1
}

# 选择目标
$target = $null
if ($HostName) {
    $safeName = $HostName -replace '[^a-zA-Z0-9_.-]', '_'
    $target = "obsidian-sync-gui-$safeName"
    $credFile = Join-Path $CredDir "$target.cred"
    if (-not (Test-Path $credFile)) {
        Write-Host "❌ 未找到 $HostName 对应的凭据文件: $credFile" -ForegroundColor Red
        exit 1
    }
} elseif ($guiCreds.Count -eq 1) {
    $target = $guiCreds[0].BaseName
    Write-Host "ℹ  自动选择唯一凭据: $target" -ForegroundColor Cyan
} else {
    Write-Host "发现多个 GUI 凭据，请选择：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $guiCreds.Count; $i++) {
        Write-Host "  [$($i+1)] $($guiCreds[$i].BaseName)"
    }
    $choice = Read-Host "输入编号 [1-$($guiCreds.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $guiCreds.Count) {
        Write-Host "❌ 无效选择" -ForegroundColor Red
        exit 1
    }
    $target = $guiCreds[$idx].BaseName
}

# DPAPI 解密
$credFile = Join-Path $CredDir "$target.cred"
try {
    Add-Type -AssemblyName System.Security
    $encryptedBase64 = Get-Content -Path $credFile -Raw -Encoding UTF8
    $encryptedBytes  = [Convert]::FromBase64String($encryptedBase64.Trim())
    $plainBytes      = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $encryptedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $plainText = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    # 凭据文件格式：username:password（Set-WindowsCredential 写入的格式）
    $parts = $plainText -split ':', 2
    $user  = $parts[0]
    $pass  = if ($parts.Count -ge 2) { $parts[1] } else { "" }
    
    # 从 target 名字还原主机：obsidian-sync-gui-43_163_113_77 -> 43.163.113.77
    $hostFromTarget = $target -replace '^obsidian-sync-gui-', '' -replace '_', '.'
    
    Write-Host ""
    Write-Host "=== Syncthing GUI 凭据 ===" -ForegroundColor Green
    Write-Host "  Web UI   : http://$hostFromTarget`:8384" -ForegroundColor Yellow
    Write-Host "  用户名   : $user" -ForegroundColor Yellow
    Write-Host "  密码     : $pass" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "提示：密码已显示明文，请注意周围是否有人！" -ForegroundColor DarkYellow
} catch {
    Write-Host "❌ 解密失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   可能原因：" -ForegroundColor DarkYellow
    Write-Host "   1. 你不是保存密码时的那个 Windows 用户（DPAPI 绑定 CurrentUser）"
    Write-Host "   2. 凭据文件损坏"
    Write-Host "   3. 你切换了 Windows 账户或重置了密码"
    Write-Host "   解决：重新运行 obsidian-sync.ps1 生成新的 GUI 凭据"
    exit 1
}
