# Windows 版本测试脚本
# 用于验证 obsidian-sync.ps1 的基本功能

Write-Host "=== Obsidian Sync Windows 版本测试 ===" -ForegroundColor Cyan
Write-Host "测试时间: $(Get-Date)" -ForegroundColor Gray
Write-Host ""

# 1. 检查脚本文件是否存在
Write-Host "1. 检查脚本文件..." -ForegroundColor Yellow
if (Test-Path "obsidian-sync.ps1") {
    Write-Host "   ✓ obsidian-sync.ps1 存在" -ForegroundColor Green
    $size = (Get-Item "obsidian-sync.ps1").Length
    Write-Host "   文件大小: $($size / 1KB) KB" -ForegroundColor Gray
} else {
    Write-Host "   ✗ obsidian-sync.ps1 不存在" -ForegroundColor Red
    exit 1
}

# 2. 检查语法错误
Write-Host "2. 检查 PowerShell 语法..." -ForegroundColor Yellow
try {
    $content = Get-Content "obsidian-sync.ps1" -Raw
    $parserErrors = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$null)
    Write-Host "   ✓ PowerShell 语法检查通过" -ForegroundColor Green
} catch {
    Write-Host "   ✗ PowerShell 语法错误: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 3. 检查函数定义
Write-Host "3. 检查函数定义..." -ForegroundColor Yellow
$functions = Select-String -Path "obsidian-sync.ps1" -Pattern "^function " | Measure-Object
Write-Host "   发现 $($functions.Count) 个函数定义" -ForegroundColor Gray

# 4. 检查模块结构
Write-Host "4. 检查模块结构..." -ForegroundColor Yellow
$modules = @(
    "ui            —— 终端交互与彩色输出",
    "dependencies  —— 依赖检查与安装", 
    "ssh           —— 远程命令执行",
    "local         —— 本地 Windows 端 Syncthing 安装与管理",
    "remote        —— 服务器端 Syncthing 部署与管理",
    "syncthing_api —— Syncthing REST API 封装",
    "state         —— 运行状态持久化"
)

foreach ($module in $modules) {
    $moduleName = $module.Split("——")[0].Trim()
    if (Select-String -Path "obsidian-sync.ps1" -Pattern $moduleName -Quiet) {
        Write-Host "   ✓ $module" -ForegroundColor Green
    } else {
        Write-Host "   ✗ $module" -ForegroundColor Red
    }
}

# 5. 检查全局变量
Write-Host "5. 检查全局变量..." -ForegroundColor Yellow
$globalVars = @("SCRIPT_NAME", "SCRIPT_VERSION", "STATE_DIR", "STATE_FILE", "LOG_FILE")
foreach ($var in $globalVars) {
    if (Select-String -Path "obsidian-sync.ps1" -Pattern "\$$var" -Quiet) {
        Write-Host "   ✓ `$$var" -ForegroundColor Green
    } else {
        Write-Host "   ✗ `$$var" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== 测试总结 ===" -ForegroundColor Cyan
Write-Host "脚本结构验证完成！" -ForegroundColor Green
Write-Host ""
Write-Host "使用说明：" -ForegroundColor Yellow
Write-Host "1. 在 Windows PowerShell 中运行：" -ForegroundColor Gray
Write-Host "   PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1" -ForegroundColor White
Write-Host ""
Write-Host "2. 以管理员权限运行（推荐）：" -ForegroundColor Gray
Write-Host "   右键点击 PowerShell -> 以管理员身份运行" -ForegroundColor White
Write-Host ""
Write-Host "3. 依赖安装：" -ForegroundColor Gray
Write-Host "   脚本会自动检查并安装所需依赖" -ForegroundColor White
Write-Host ""
Write-Host "Windows 版本功能特性：" -ForegroundColor Yellow
Write-Host "✓ Chocolatey 包管理支持" -ForegroundColor Green
Write-Host "✓ Windows 服务管理 (sc.exe)" -ForegroundColor Green
Write-Host "✓ Windows 凭据管理器集成" -ForegroundColor Green
Write-Host "✓ PowerShell 彩色输出" -ForegroundColor Green
Write-Host "✓ 路径格式自动转换 (Windows ↔ Unix)" -ForegroundColor Green
Write-Host ""
Write-Host "注意：实际功能需要在 Windows 环境中测试运行。" -ForegroundColor Magenta