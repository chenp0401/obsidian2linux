# 编码测试脚本 - 验证远程桌面环境下的中文显示
Write-Host "=== 编码测试脚本 ===" -ForegroundColor Cyan
Write-Host ""

# 测试当前编码设置
Write-Host "1. 当前控制台编码:" -ForegroundColor Yellow
Write-Host "   OutputEncoding: $([Console]::OutputEncoding.EncodingName)" -ForegroundColor Gray
Write-Host "   OutputEncoding变量: $($OutputEncoding.EncodingName)" -ForegroundColor Gray
Write-Host ""

# 测试中文显示
Write-Host "2. 中文显示测试:" -ForegroundColor Yellow
Write-Host "   ✔ 这是一个对勾符号" -ForegroundColor Green
Write-Host "   ✘ 这是一个叉号符号" -ForegroundColor Red
Write-Host "   ℹ 这是一个信息符号" -ForegroundColor Blue
Write-Host "   ⚠ 这是一个警告符号" -ForegroundColor Yellow
Write-Host "   ▶ 这是一个步骤符号" -ForegroundColor Cyan
Write-Host ""

# 测试中文字符串
Write-Host "3. 中文字符串测试:" -ForegroundColor Yellow
Write-Host "   Obsidian 本地与云端一键同步工具" -ForegroundColor White
Write-Host "   基于 Syncthing 的同步解决方案" -ForegroundColor White
Write-Host "   单脚本、交互式向导、傻瓜化部署" -ForegroundColor White
Write-Host ""

# 测试文件编码
Write-Host "4. 文件编码测试:" -ForegroundColor Yellow
$testFile = "$env:TEMP\encoding-test.txt"
"中文测试内容 - 这是一个UTF-8编码测试文件" | Out-File $testFile -Encoding UTF8
$content = Get-Content $testFile -Encoding UTF8
Write-Host "   文件内容: $content" -ForegroundColor Gray
Remove-Item $testFile -ErrorAction SilentlyContinue
Write-Host ""

Write-Host "=== 测试完成 ===" -ForegroundColor Cyan
Write-Host "如果所有中文字符和符号都正确显示，说明编码设置成功！" -ForegroundColor Green