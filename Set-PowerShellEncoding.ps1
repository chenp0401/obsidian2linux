# PowerShell 编码设置工具
# 解决VSCode和PowerShell终端中文显示不一致问题

function Set-PowerShellEncoding {
    param(
        [switch]$Permanent = $false
    )
    
    Write-Host "=== PowerShell 编码设置工具 ===" -ForegroundColor Cyan
    Write-Host ""
    
    # 显示当前编码状态
    Write-Host "当前编码状态:" -ForegroundColor Yellow
    Write-Host "  - 控制台输出编码: $([Console]::OutputEncoding.EncodingName)"
    Write-Host "  - PowerShell输出编码: $($OutputEncoding.EncodingName)"
    Write-Host "  - 系统代码页: $(chcp | Out-String)"
    Write-Host ""
    
    # 设置UTF-8编码
    try {
        # 设置控制台编码
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        
        # 设置默认编码参数
        $PSDefaultParameterValues['*:Encoding'] = 'UTF8'
        
        # 设置代码页为UTF-8
        chcp 65001 | Out-Null
        
        Write-Host "✅ 编码设置完成:" -ForegroundColor Green
        Write-Host "  - 控制台输出编码: $([Console]::OutputEncoding.EncodingName)"
        Write-Host "  - PowerShell输出编码: $($OutputEncoding.EncodingName)"
        Write-Host "  - 系统代码页: $(chcp | Out-String)"
        Write-Host ""
        
        # 测试中文显示
        Write-Host "📝 中文测试: 这是一段中文测试文本 ✔ ✘ ℹ ⚠" -ForegroundColor Magenta
        
    } catch {
        Write-Host "❌ 编码设置失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    
    # 如果是永久设置，修改PowerShell配置文件
    if ($Permanent) {
        Set-PermanentEncoding
    }
    
    return $true
}

function Set-PermanentEncoding {
    # 获取PowerShell配置文件路径
    $profilePath = $PROFILE.CurrentUserAllHosts
    
    # 确保配置文件目录存在
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    
    # 编码设置代码
    $encodingCode = @'
# 设置UTF-8编码（解决中文乱码问题）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'UTF8'
chcp 65001 | Out-Null
'@
    
    # 检查配置文件是否已存在编码设置
    $hasEncodingSetting = $false
    if (Test-Path $profilePath) {
        $content = Get-Content $profilePath -Raw
        if ($content -match "UTF-8|65001|OutputEncoding") {
            $hasEncodingSetting = $true
        }
    }
    
    if (-not $hasEncodingSetting) {
        # 添加编码设置到配置文件
        Add-Content -Path $profilePath -Value "`n$encodingCode" -Encoding UTF8
        Write-Host "✅ 已永久设置编码到PowerShell配置文件: $profilePath" -ForegroundColor Green
    } else {
        Write-Host "ℹ 配置文件已包含编码设置，无需修改" -ForegroundColor Blue
    }
}

function Test-Encoding {
    Write-Host "=== 编码测试 ===" -ForegroundColor Cyan
    Write-Host ""
    
    # 测试各种中文字符
    $testCases = @(
        "普通中文: 这是一段测试文本",
        "特殊符号: ✔ ✘ ℹ ⚠ ▶",
        "标点符号: ，。！？；：""''（）【】《》",
        "复杂中文: 饕餮耄耋龘龖",
        "混合文本: Hello 世界！123测试"
    )
    
    foreach ($test in $testCases) {
        Write-Host $test -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "如果以上中文显示正常，说明编码设置成功！" -ForegroundColor Green
}

# 显示使用帮助
function Show-Help {
    Write-Host "使用方法:" -ForegroundColor Yellow
    Write-Host "  .\Set-PowerShellEncoding.ps1           # 临时设置编码（当前会话有效）"
    Write-Host "  .\Set-PowerShellEncoding.ps1 -Permanent # 永久设置编码（修改配置文件）"
    Write-Host ""
    Write-Host "其他命令:" -ForegroundColor Yellow
    Write-Host "  Set-PowerShellEncoding                 # 临时设置"
    Write-Host "  Set-PowerShellEncoding -Permanent      # 永久设置"
    Write-Host "  Test-Encoding                          # 测试编码"
    Write-Host ""
}

# 主执行逻辑
if ($MyInvocation.InvocationName -ne '.') {
    # 如果是直接执行脚本
    if ($args.Count -gt 0 -and $args[0] -eq "-Permanent") {
        Set-PowerShellEncoding -Permanent
    } else {
        Set-PowerShellEncoding
    }
    
    Test-Encoding
    Write-Host ""
    Show-Help
}
