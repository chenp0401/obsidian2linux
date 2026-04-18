# ============================================================================
# obsidian-sync.ps1
#   Obsidian 本地与云端一键同步工具（基于 Syncthing） - Windows 版本
#   单脚本、交互式向导、傻瓜化部署
#
#   模块分层：
#     ui            —— 终端交互与彩色输出
#     dependencies  —— 依赖检查与安装
#     ssh           —— 远程命令执行
#     local         —— 本地 Windows 端 Syncthing 安装与管理
#     remote        —— 服务器端 Syncthing 部署与管理
#     syncthing_api —— Syncthing REST API 封装
#     state         —— 运行状态持久化
#
#   使用：PowerShell -ExecutionPolicy Bypass -File obsidian-sync.ps1
# ============================================================================

# 设置错误处理
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================================
# 编码设置与修复（解决VSCode和PowerShell终端中文显示不一致问题）
# ============================================================================

# 强制设置UTF-8编码（在脚本开始时立即执行）
function Initialize-Encoding {
    try {
        # 1. 设置PowerShell内部编码
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $PSDefaultParameterValues['*:Encoding'] = 'UTF8'
        
        # 2. 设置系统代码页为UTF-8
        $codePageResult = chcp 65001 2>&1
        
        # 3. 设置环境变量（影响子进程）
        $env:PYTHONIOENCODING = "utf-8"
        $env:LANG = "en_US.UTF-8"
        
        # 4. 验证设置结果
        Start-Sleep -Milliseconds 50
        
        return $true
    } catch {
        Write-Warn "编码初始化失败: $($_.Exception.Message)"
        return $false
    }
}

# 立即执行编码初始化
Initialize-Encoding | Out-Null

# 编码检测与修复函数
function Test-AndFix-Encoding {
    try {
        Write-Info "开始编码检测与修复..."
        
        # 检测当前控制台编码
        $consoleEncoding = [Console]::OutputEncoding.EncodingName
        $outputEncoding = $OutputEncoding.EncodingName
        $currentCodePage = chcp | Out-String
        
        Write-Info "当前编码状态："
        Write-Info "  - 控制台编码: $consoleEncoding"
        Write-Info "  - 输出编码: $outputEncoding"
        Write-Info "  - 代码页: $currentCodePage"
        
        # 检查是否需要修复
        $needsFix = $false
        $fixes = @()
        
        if ($consoleEncoding -notlike "*UTF*" -and $consoleEncoding -notlike "*Unicode*") {
            $needsFix = $true
            $fixes += "控制台编码非UTF-8"
        }
        
        if ($outputEncoding -notlike "*UTF*" -and $outputEncoding -notlike "*Unicode*") {
            $needsFix = $true
            $fixes += "输出编码非UTF-8"
        }
        
        if ($currentCodePage -notmatch "65001") {
            $needsFix = $true
            $fixes += "代码页非UTF-8"
        }
        
        if ($needsFix) {
            Write-Warn "检测到编码问题: $($fixes -join ', ')"
            Write-Warn "正在修复编码设置..."
            
            # 强制设置UTF-8编码
            chcp 65001 | Out-Null
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            $OutputEncoding = [System.Text.Encoding]::UTF8
            $PSDefaultParameterValues['*:Encoding'] = 'UTF8'
            
            # 验证修复结果
            Start-Sleep -Milliseconds 100
            $newConsoleEncoding = [Console]::OutputEncoding.EncodingName
            $newOutputEncoding = $OutputEncoding.EncodingName
            $newCodePage = chcp | Out-String
            
            Write-Ok "编码修复完成："
            Write-Ok "  - 新控制台编码: $newConsoleEncoding"
            Write-Ok "  - 新输出编码: $newOutputEncoding"
            Write-Ok "  - 新代码页: $newCodePage"
            
            # 测试中文显示
            Write-Info "测试中文显示：中文测试内容 ✔ ✘ ℹ ⚠ ▶"
        } else {
            Write-Ok "编码设置正常，无需修复"
        }
        
    } catch {
        Write-Warn "编码检测失败: $($_.Exception.Message)"
        Write-Warn "尝试基础编码设置..."
        
        # 基础编码设置作为备用方案
        try {
            chcp 65001 | Out-Null
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            Write-Ok "基础编码设置完成"
        } catch {
            Write-Error "编码设置完全失败，中文可能显示异常"
        }
    }
}

# ---------------------------------------------------------------------------
# 全局常量与运行时变量
# ---------------------------------------------------------------------------
$SCRIPT_NAME = "obsidian-sync"
$SCRIPT_VERSION = "0.1.0"
$STATE_DIR = Join-Path $env:USERPROFILE ".obsidian-sync"
$STATE_FILE = Join-Path $STATE_DIR "last-run.json"
$LOG_FILE = Join-Path $STATE_DIR "run.log"
$REMOTE_API_LOCAL_PORT = "18384"
$LOCAL_API_URL = "http://127.0.0.1:8384"
$REMOTE_API_URL = "http://127.0.0.1:$REMOTE_API_LOCAL_PORT"
$DEFAULT_OBSIDIAN_ROOT = Join-Path $env:USERPROFILE "Documents\Obsidian"
$DEFAULT_REMOTE_ROOT = "/data/obsidian"

# 运行时敏感变量
$global:SSH_HOST = ""
$global:SSH_USER = "root"
$global:SSH_PORT = "22"
$global:SSH_PASS = $null
$global:REMOTE_API_KEY = $null
$global:LOCAL_API_KEY = $null
$global:REMOTE_DEVICE_ID = $null
$global:LOCAL_DEVICE_ID = $null
$global:SSH_TUNNEL_PROCESS = $null
$global:REMOTE_GUI_USER = ""
$global:REMOTE_GUI_PASS = $null

# 回滚栈
$global:ROLLBACK_STACK = @()

# ---------------------------------------------------------------------------
# 模块：ui —— 彩色日志与交互
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Level,
        [string]$Message,
        [string]$Color = "White"
    )
    
    $symbols = @{
        "INFO" = "ℹ";
        "OK"   = "✔";
        "WARN" = "⚠";
        "ERR"  = "✘";
        "STEP" = "▶"
    }    
    $symbol = $symbols[$Level]
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # 控制台输出
    if ($Level -eq "STEP") {
        Write-Host "`n" -NoNewline
    }
    Write-Host "$symbol  " -NoNewline -ForegroundColor $Color
    Write-Host $Message -ForegroundColor $Color
    
    # 文件日志
    if (Test-Path $STATE_DIR) {
        "[$timestamp] [$Level] $Message" | Out-File $LOG_FILE -Append -Encoding UTF8
    }
}

function Write-Info    { Write-Log "INFO" $args -Color "Blue" }
function Write-Ok      { Write-Log "OK" $args -Color "Green" }
function Write-Warn    { Write-Log "WARN" $args -Color "Yellow" }
function Write-Error   { Write-Log "ERR" $args -Color "Red" }
function Write-Step    { Write-Log "STEP" $args -Color "Cyan" }
function Write-Hint    { Write-Host "   ↳ $($args[0])" -ForegroundColor "DarkGray" }

function Confirm {
    param(
        [string]$Prompt,
        [string]$Default = "N"
    )
    
    $hint = if ($Default -eq "Y") { "[Y/n]" } else { "[y/N]" }
    Write-Host "$Prompt $hint " -NoNewline -ForegroundColor Magenta
    
    $reply = Read-Host
    $reply = if ([string]::IsNullOrEmpty($reply)) { $Default } else { $reply }
    return $reply -match "^[Yy]$"
}

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    
    Write-Host "$Prompt [默认: $Default]: " -NoNewline -ForegroundColor Magenta
    $input = Read-Host
    return if ([string]::IsNullOrEmpty($input)) { $Default } else { $input }
}

function Read-Password {
    param([string]$Prompt = "请输入密码")
    
    Write-Host "$Prompt (输入时不会显示): " -NoNewline -ForegroundColor Magenta
    $secure = Read-Host -AsSecureString
    $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
    return $password
}
# ---------------------------------------------------------------------------
# 模块：依赖检查
# ---------------------------------------------------------------------------
function Test-Command {
    param([string]$Command)
    return Get-Command $Command -ErrorAction SilentlyContinue
}

function Check-Dependencies {
    Write-Step "检查本地依赖"
    
    # Windows 特有依赖检查
    if (-not (Test-Command "choco")) {
        Write-Warn "未检测到 Chocolatey 包管理器"
        if (Confirm "是否安装 Chocolatey？（推荐，用于自动安装依赖）" "Y") {
            Install-Chocolatey
        }
    } else {
        Write-Ok "已安装：Chocolatey 包管理器"
    }
    
    $required = @("ssh", "curl")
    $optional = @(
        @{Name="sshpass"; Description="非交互式 SSH 密码登录"},
        @{Name="jq"; Description="JSON 解析"},
        @{Name="fzf"; Description="目录多选 TUI"}
    )
    
    $missing = @()
    foreach ($cmd in $required) {
        if (Test-Command $cmd) {
            Write-Ok "已安装：$cmd"
        } else {
            Write-Error "缺少必需依赖：$cmd"
            $missing += $cmd
        }
    }
    
    if ($missing.Count -gt 0) {
        Write-Hint "Windows 安装建议："
        foreach ($cmd in $missing) {
            switch ($cmd) {
                "ssh" { Write-Hint "  - 安装 OpenSSH: choco install openssh -y" }
                "curl" { Write-Hint "  - 安装 curl: choco install curl -y" }
            }
        }
        throw "请先安装缺失的必需依赖后再重试。"
    }
    
    foreach ($item in $optional) {
        if (Test-Command $item.Name) {
            Write-Ok "已安装：$($item.Name)（$($item.Description)）"
        } else {
            Write-Warn "未检测到 $($item.Name)（$($item.Description)）"
            # Windows 安装提示
            switch ($item.Name) {
                "sshpass" { Write-Hint "  - 安装: choco install sshpass -y" }
                "jq" { Write-Hint "  - 安装: choco install jq -y" }
                "fzf" { Write-Hint "  - 安装: choco install fzf -y" }
            }
        }
    }
}

function Install-Chocolatey {
    Write-Step "安装 Chocolatey 包管理器（使用国内镜像加速）"
    
    try {
        # 检查 PowerShell 执行策略
        $policy = Get-ExecutionPolicy
        if ($policy -eq "Restricted") {
            Write-Warn "PowerShell 执行策略为 Restricted，需要临时放宽"
            Set-ExecutionPolicy Bypass -Scope Process -Force
        }
        
        # 启用 TLS 1.2
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        
        # 候选镜像源（按优先级排序）：华为云 → 腾讯云 → 清华大学 → 官方源
        $mirrors = @(
            @{
                Name = "华为云"
                PackageUrl = "https://mirrors.huaweicloud.com/chocolatey/chocolatey.0.10.15.nupkg"
                InstallScriptUrl = $null
            },
            @{
                Name = "腾讯云"
                PackageUrl = "https://mirrors.cloud.tencent.com/chocolatey/chocolatey.0.10.15.nupkg"
                InstallScriptUrl = $null
            },
            @{
                Name = "清华大学"
                PackageUrl = "https://mirrors.tuna.tsinghua.edu.cn/chocolatey/chocolatey.nupkg"
                InstallScriptUrl = $null
            },
            @{
                Name = "官方源"
                PackageUrl = $null
                InstallScriptUrl = "https://community.chocolatey.org/install.ps1"
            }
        )
        
        $installed = $false
        foreach ($mirror in $mirrors) {
            Write-Info "尝试使用镜像：$($mirror.Name)"
            try {
                if ($mirror.PackageUrl) {
                    # 通过环境变量指定 nupkg 下载地址，让官方脚本从镜像拉包
                    $env:chocolateyDownloadUrl = $mirror.PackageUrl
                    $env:chocolateyVersion = ""
                }
                
                $scriptUrl = if ($mirror.InstallScriptUrl) { $mirror.InstallScriptUrl } else { "https://community.chocolatey.org/install.ps1" }
                
                # 设置下载超时（30秒）
                $webClient = New-Object System.Net.WebClient
                $webClient.Headers.Add("User-Agent", "PowerShell")
                $installScript = $webClient.DownloadString($scriptUrl)
                
                Write-Info "从 $($mirror.Name) 下载安装包并执行..."
                Invoke-Expression $installScript
                
                # 刷新环境变量
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                
                if (Test-Command "choco") {
                    Write-Ok "Chocolatey 安装成功（使用 $($mirror.Name) 镜像）"
                    $installed = $true
                    break
                }
            } catch {
                Write-Warn "使用 $($mirror.Name) 镜像安装失败：$($_.Exception.Message)"
                continue
            } finally {
                # 清理环境变量
                Remove-Item Env:\chocolateyDownloadUrl -ErrorAction SilentlyContinue
                Remove-Item Env:\chocolateyVersion -ErrorAction SilentlyContinue
            }
        }
        
        if (-not $installed) {
            throw "所有镜像源均安装失败，请检查网络或手动安装 Chocolatey"
        }
        
        # 安装成功后，配置 Chocolatey 使用国内镜像作为默认源
        Set-ChocolateyMirror
        
    } catch {
        throw "Chocolatey 安装失败: $($_.Exception.Message)"
    }
}

function Set-ChocolateyMirror {
    Write-Step "配置 Chocolatey 使用国内镜像源"
    
    try {
        # 添加华为云镜像源（优先级最高）
        $huaweiSource = "https://mirrors.huaweicloud.com/repository/nuget/v3/index.json"
        
        # 查看现有源
        $existingSources = choco source list 2>&1 | Out-String
        
        if ($existingSources -notmatch "huaweicloud") {
            Write-Info "添加华为云镜像源..."
            choco source add -n="huaweicloud" -s="$huaweiSource" --priority=1 | Out-Null
            Write-Ok "已添加华为云镜像源（优先级 1）"
        } else {
            Write-Ok "华为云镜像源已存在"
        }
        
        # 禁用官方源（可选，加速后续安装）
        if (Confirm "是否禁用 Chocolatey 官方源以强制使用国内镜像？（推荐）" "Y") {
            choco source disable -n="chocolatey" 2>&1 | Out-Null
            Write-Ok "已禁用 Chocolatey 官方源"
        }
        
    } catch {
        Write-Warn "配置镜像源失败：$($_.Exception.Message)"
        Write-Hint "可稍后手动执行：choco source add -n=huaweicloud -s=https://mirrors.huaweicloud.com/repository/nuget/v3/index.json --priority=1"
    }
}

# 添加 Windows 服务管理功能
function Install-WindowsService {
    param(
        [string]$ServiceName,
        [string]$ExecutablePath,
        [string]$DisplayName,
        [string]$Description
    )
    
    Write-Step "安装 Windows 服务: $ServiceName"
    
    # 检查服务是否已存在
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-Warn "服务 '$ServiceName' 已存在，跳过安装"
        return $true
    }
    
    try {
        # 使用 sc.exe 创建服务
        $result = sc.exe create $ServiceName binPath= "`"$ExecutablePath`"" DisplayName= "$DisplayName" start= "auto"
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "服务创建成功"
            
            # 设置服务描述
            sc.exe description $ServiceName "$Description" | Out-Null
            
            return $true
        } else {
            throw "服务创建失败 (exit code: $LASTEXITCODE)"
        }
        
    } catch {
        Write-Error "服务安装失败: $($_.Exception.Message)"
        return $false
    }
}

function Start-WindowsService {
    param([string]$ServiceName)
    
    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Ok "服务 '$ServiceName' 启动成功"
        return $true
    } catch {
        Write-Error "服务启动失败: $($_.Exception.Message)"
        return $false
    }
}

# 添加 Windows 路径处理函数
function Convert-ToWindowsPath {
    param([string]$UnixPath)
    
    # 将 Unix 路径转换为 Windows 路径
    if ($UnixPath -match "^/home/([^/]+)") {
        return "C:\Users\$($Matches[1])" + $UnixPath.Substring($Matches[0].Length)
    }
    elseif ($UnixPath -match "^/data") {
        return "D:" + $UnixPath.Substring(1)
    }
    
    return $UnixPath
}

function Convert-ToUnixPath {
    param([string]$WindowsPath)
    
    # 将 Windows 路径转换为 Unix 路径
    if ($WindowsPath -match "^([A-Z]):\\Users\\([^\\]+)") {
        return "/home/$($Matches[2])" + $WindowsPath.Substring($Matches[0].Length).Replace("\\", "/")
    }
    elseif ($WindowsPath -match "^([A-Z]):") {
        return "/data" + $WindowsPath.Substring(2).Replace("\\", "/")
    }
    
    return $WindowsPath
}

# ---------------------------------------------------------------------------
# 模块：ssh —— 远程命令执行
# ---------------------------------------------------------------------------
function Invoke-SSHCommand {
    param([string]$Command)
    
    if (-not (Test-Command "sshpass")) {
        throw "未安装 sshpass，无法非交互登录"
    }
    
    $cmd = "sshpass -e ssh -p $SSH_PORT $SSH_USER@$SSH_HOST `"$Command`""
    return Invoke-Expression $cmd
}

function Test-SSHConnection {
    Write-Step "测试 SSH 连接"
    
    try {
        $result = Invoke-SSHCommand "echo __OBSIDIAN_SYNC_PROBE_OK__"
        if ($result -contains "__OBSIDIAN_SYNC_PROBE_OK__") {
            Write-Ok "SSH 连接测试成功"
            return $true
        }
    } catch {
        Write-Error "SSH 连接失败: $($_.Exception.Message)"
    }
    return $false
}

# ---------------------------------------------------------------------------
# 模块：Windows 凭据管理
# ---------------------------------------------------------------------------
function Get-WindowsCredential {
    param([string]$Target)
    
    try {
        $cred = Get-StoredCredential -Target $Target -ErrorAction SilentlyContinue
        return if ($cred) { $cred.GetNetworkCredential().Password } else { $null }
    } catch {
        return $null
    }
}

function Set-WindowsCredential {
    param([string]$Target, [string]$Password)
    
    try {
        $secure = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($Target, $secure)
        Set-StoredCredential -Target $Target -Credential $cred -Persist LocalMachine
    } catch {
        Write-Warn "Windows 凭据保存失败: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
function Main {
    try {
        Write-Host "=== Obsidian 同步工具 (Windows 版本) ===" -ForegroundColor Cyan
        Write-Host "版本: $SCRIPT_VERSION" -ForegroundColor Gray
        Write-Host "操作系统: Windows $( [System.Environment]::OSVersion.Version )" -ForegroundColor Gray
        Write-Host ""
        
        # 编码检测与修复（解决远程桌面乱码问题）
        Test-AndFix-Encoding
        
        # 创建状态目录
        if (-not (Test-Path $STATE_DIR)) {
            New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
            Write-Ok "创建状态目录: $STATE_DIR"
        }
        
        # 检查依赖
        Check-Dependencies
        
        # 收集用户输入
        Collect-UserInput
        
        # 测试 SSH 连接
        if (-not (Test-SSHConnection)) {
            throw "SSH 连接测试失败"
        }
        
        Write-Ok "Windows 版本脚本框架已创建，核心功能实现中..."
        Write-Hint "后续将实现：Windows 服务管理、Syncthing 安装、API 调用等功能"
        
    } catch {
        Write-Error "执行失败: $($_.Exception.Message)"
        exit 1
    }
}

function Collect-UserInput {
    Write-Step "步骤 1/8：采集服务器连接信息"
    
    # 从上次运行记录加载配置
    Load-LastConfig
    
    # 获取服务器信息
    $global:SSH_HOST = Read-WithDefault "服务器 IP 或域名" $SSH_HOST
    $global:SSH_USER = Read-WithDefault "SSH 用户名" $SSH_USER
    $global:SSH_PORT = Read-WithDefault "SSH 端口" $SSH_PORT
    
    # 密码处理
    $credTarget = "obsidian-sync-${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    $savedPass = Get-WindowsCredential $credTarget
    
    if ($savedPass) {
        if (Confirm "检测到已保存的密码，直接使用？" "Y") {
            $global:SSH_PASS = $savedPass
            return
        }
    }
    
    $global:SSH_PASS = Read-Password "SSH 密码"
    Set-WindowsCredential $credTarget $SSH_PASS
}

function Load-LastConfig {
    if (Test-Path $STATE_FILE) {
        try {
            $config = Get-Content $STATE_FILE | ConvertFrom-Json
            $global:SSH_HOST = $config.server.host
            $global:SSH_USER = $config.server.user
            $global:SSH_PORT = $config.server.port
            
            if ($SSH_HOST) {
                Write-Info "已从上次运行记录加载：${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
            }
        } catch {
            Write-Warn "加载上次配置失败: $($_.Exception.Message)"
        }
    }
}

# 执行主函数
Main