# 编码修复测试脚本 - Windows 版本
# 用于验证远程桌面环境下的中文显示问题

Write-Host "=== 编码修复测试脚本 (Windows) ===" -ForegroundColor Cyan
Write-Host "版本: 1.0.0" -ForegroundColor Gray
Write-Host "运行时间: $(Get-Date)" -ForegroundColor Gray
Write-Host ""

# 1. 检测当前编码状态
Write-Host "1. 当前编码状态检测:" -ForegroundColor Yellow
$consoleEncoding = [Console]::OutputEncoding.EncodingName
$outputEncoding = $OutputEncoding.EncodingName
$codePage = chcp | Out-String

Write-Host "   控制台编码: $consoleEncoding" -ForegroundColor Gray
Write-Host "   输出编码: $outputEncoding" -ForegroundColor Gray
Write-Host "   代码页: $codePage" -ForegroundColor Gray
Write-Host ""

# 2. 应用编码修复
Write-Host "2. 应用编码修复..." -ForegroundColor Yellow
try {
    # 强制设置UTF-8编码
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    $PSDefaultParameterValues['*:Encoding'] = 'UTF8'
    
    # 等待设置生效
    Start-Sleep -Milliseconds 200
    
    Write-Host "   ✓ 编码修复完成" -ForegroundColor Green
} catch {
    Write-Host "   ✗ 编码修复失败: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# 3. 验证修复后的编码状态
Write-Host "3. 修复后编码状态:" -ForegroundColor Yellow
$newConsoleEncoding = [Console]::OutputEncoding.EncodingName
$newOutputEncoding = $OutputEncoding.EncodingName
$newCodePage = chcp | Out-String

Write-Host "   新控制台编码: $newConsoleEncoding" -ForegroundColor Gray
Write-Host "   新输出编码: $newOutputEncoding" -ForegroundColor Gray
Write-Host "   新代码页: $newCodePage" -ForegroundColor Gray
Write-Host ""

# 4. 中文显示测试
Write-Host "4. 中文显示测试:" -ForegroundColor Yellow

# 基本中文字符
Write-Host "   基本中文: Obsidian 本地与云端一键同步工具" -ForegroundColor White
Write-Host "   特殊符号: ✔ ✘ ℹ ⚠ ▶ ★ ☆ ♥ ♦ ♣ ♠" -ForegroundColor White

# 复杂中文内容
Write-Host "   复杂中文: 基于 Syncthing 的同步解决方案" -ForegroundColor White
Write-Host "   技术术语: 单脚本、交互式向导、傻瓜化部署" -ForegroundColor White
Write-Host "   路径测试: C:\Users\用户名\Documents\Obsidian" -ForegroundColor White
Write-Host ""

# 5. 符号和表情测试
Write-Host "5. 符号和表情测试:" -ForegroundColor Yellow
Write-Host "   状态符号: ✔ 成功 ✘ 失败 ℹ 信息 ⚠ 警告 ▶ 步骤" -ForegroundColor White
Write-Host "   箭头符号: ← → ↑ ↓ ↖ ↗ ↘ ↙" -ForegroundColor White
Write-Host "   数学符号: ± × ÷ ≠ ≤ ≥ ∞ π ∑ ∏" -ForegroundColor White
Write-Host "   货币符号: $ € ¥ £ ¢" -ForegroundColor White
Write-Host ""

# 6. 文件编码测试
Write-Host "6. 文件编码测试:" -ForegroundColor Yellow
try {
    $testFile = "$env:TEMP\encoding-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $testContent = @"
中文测试文件 - UTF-8 编码验证
================================
项目名称: Obsidian 同步工具
功能描述: 基于 Syncthing 的本地与云端一键同步
特殊符号: ✔ ✘ ℹ ⚠ ▶
测试时间: $(Get-Date)
"@
    
    $testContent | Out-File $testFile -Encoding UTF8
    $readContent = Get-Content $testFile -Encoding UTF8 -Raw
    
    if ($readContent -eq $testContent) {
        Write-Host "   ✓ 文件编码测试通过" -ForegroundColor Green
        Write-Host "   文件路径: $testFile" -ForegroundColor Gray
    } else {
        Write-Host "   ✗ 文件编码测试失败" -ForegroundColor Red
    }
    
    # 清理测试文件
    Remove-Item $testFile -ErrorAction SilentlyContinue
    
} catch {
    Write-Host "   ✗ 文件编码测试异常: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# 7. 测试结果总结
Write-Host "7. 测试结果总结:" -ForegroundColor Yellow

if ($newConsoleEncoding -like "*UTF*" -or $newConsoleEncoding -like "*Unicode*") {
    Write-Host "   ✓ 控制台编码: UTF-8" -ForegroundColor Green
} else {
    Write-Host "   ✗ 控制台编码: $newConsoleEncoding" -ForegroundColor Red
}

if ($newOutputEncoding -like "*UTF*" -or $newOutputEncoding -like "*Unicode*") {
    Write-Host "   ✓ 输出编码: UTF-8" -ForegroundColor Green
} else {
    Write-Host "   ✗ 输出编码: $newOutputEncoding" -ForegroundColor Red
}

if ($newCodePage -match "65001") {
    Write-Host "   ✓ 代码页: UTF-8 (65001)" -ForegroundColor Green
} else {
    Write-Host "   ✗ 代码页: $newCodePage" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== 测试完成 ===" -ForegroundColor Cyan
Write-Host "如果所有中文字符和符号都正确显示，说明编码修复成功！" -ForegroundColor Green
Write-Host ""
Write-Host "使用说明:" -ForegroundColor Yellow
Write-Host "1. 在远程桌面中运行此脚本: PowerShell -ExecutionPolicy Bypass -File test-encoding-fix.ps1" -ForegroundColor Gray
Write-Host "2. 如果仍有乱码，请检查远程桌面的编码设置" -ForegroundColor Gray
Write-Host "3. 运行主脚本前先运行此测试脚本验证编码" -ForegroundColor Gray