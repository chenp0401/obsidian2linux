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
    # 注意：不要使用 $input 作为变量名，它是 PowerShell 自动变量（代表管道输入）
    $userInput = Read-Host
    # 注意：不要写 `return if (...) {...} else {...}`，
    #   PowerShell 解析器会把 if 当作独立语句而非 return 的表达式，
    #   导致报错 "The term 'if' is not recognized as a name of a cmdlet..."
    if ([string]::IsNullOrEmpty($userInput)) {
        return $Default
    } else {
        return $userInput
    }
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

# ---------------------------------------------------------------------------
# 工具：带进度条的下载（显示速度/百分比/已下载大小）
# ---------------------------------------------------------------------------
function Invoke-DownloadWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [int]$TimeoutSec = 30,
        [string]$Activity = "下载中"
    )
    
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.UserAgent = "PowerShell/obsidian-sync"
    
    Write-Host "   ↳ 正在连接 $Url ..." -ForegroundColor DarkGray
    $response = $request.GetResponse()
    $totalBytes = $response.ContentLength
    $totalMB = if ($totalBytes -gt 0) { [Math]::Round($totalBytes / 1MB, 2) } else { 0 }
    
    if ($totalBytes -gt 0) {
        Write-Host "   ↳ 已建立连接，文件大小：$totalMB MB" -ForegroundColor DarkGray
    } else {
        Write-Host "   ↳ 已建立连接，文件大小未知（服务端未返回 Content-Length）" -ForegroundColor DarkGray
    }
    
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    
    $buffer = New-Object byte[] 8192
    $totalRead = 0
    $lastUpdate = [DateTime]::Now
    $startTime = [DateTime]::Now
    
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $totalRead += $read
            
            # 每 200ms 刷新一次进度，避免刷屏
            $now = [DateTime]::Now
            if (($now - $lastUpdate).TotalMilliseconds -ge 200 -or $totalRead -eq $totalBytes) {
                $elapsedSec = ($now - $startTime).TotalSeconds
                $speedKB = if ($elapsedSec -gt 0) { [Math]::Round($totalRead / 1KB / $elapsedSec, 1) } else { 0 }
                $downloadedMB = [Math]::Round($totalRead / 1MB, 2)
                
                if ($totalBytes -gt 0) {
                    $percent = [Math]::Min([Math]::Round(($totalRead / $totalBytes) * 100, 1), 100)
                    Write-Progress -Activity $Activity -Status "$downloadedMB MB / $totalMB MB  ($speedKB KB/s)" -PercentComplete $percent
                } else {
                    Write-Progress -Activity $Activity -Status "$downloadedMB MB 已下载 ($speedKB KB/s)"
                }
                $lastUpdate = $now
            }
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $response.Close()
        Write-Progress -Activity $Activity -Completed
    }
    
    $elapsedTotal = [Math]::Round(([DateTime]::Now - $startTime).TotalSeconds, 1)
    $finalMB = [Math]::Round($totalRead / 1MB, 2)
    Write-Host "   ↳ 下载完成：$finalMB MB，用时 $elapsedTotal 秒" -ForegroundColor DarkGray
}

function Test-UrlReachable {
    param(
        [string]$Url,
        [int]$TimeoutSec = 8
    )
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "HEAD"
        $request.Timeout = $TimeoutSec * 1000
        $request.UserAgent = "PowerShell/obsidian-sync"
        $response = $request.GetResponse()
        $size = $response.ContentLength
        $response.Close()
        return @{ Ok = $true; Size = $size }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
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
        
        # Chocolatey 稳定版本（可按需升级；GitHub Release 是真实存储位置）
        $chocoVersion = "2.7.1"
        
        # 候选镜像源（按优先级排序，基于实测可靠性）：
        #   ghfast.top → gh-proxy.com → mirror.ghproxy.com → GitHub 直连 → 官方源
        # 说明：Chocolatey 的 nupkg 真实存放在 GitHub Release，走 GitHub 反代比官方源更快
        $githubReleasePath = "chocolatey/choco/releases/download/$chocoVersion/chocolatey.$chocoVersion.nupkg"
        
        $mirrors = @(
            @{
                Name = "ghfast.top 代理"
                PackageUrl = "https://ghfast.top/https://github.com/$githubReleasePath"
                InstallScriptUrl = $null
            },
            @{
                Name = "gh-proxy.com 代理"
                PackageUrl = "https://gh-proxy.com/https://github.com/$githubReleasePath"
                InstallScriptUrl = $null
            },
            @{
                Name = "mirror.ghproxy.com 代理"
                PackageUrl = "https://mirror.ghproxy.com/https://github.com/$githubReleasePath"
                InstallScriptUrl = $null
            },
            @{
                Name = "GitHub 直连"
                PackageUrl = "https://github.com/$githubReleasePath"
                InstallScriptUrl = $null
            },
            @{
                Name = "Chocolatey 官方源"
                PackageUrl = $null
                InstallScriptUrl = "https://community.chocolatey.org/install.ps1"
            }
        )
        
        # 准备临时目录
        $tmpDir = Join-Path $env:TEMP "obsidian-sync-choco"
        if (-not (Test-Path $tmpDir)) {
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        }
        
        $installed = $false
        $mirrorIndex = 0
        $totalMirrors = $mirrors.Count
        
        foreach ($mirror in $mirrors) {
            $mirrorIndex++
            Write-Info "[$mirrorIndex/$totalMirrors] 尝试使用镜像：$($mirror.Name)"
            
            try {
                # ---- 阶段 1：连通性探测（最多 3 次重试） ----
                $probeUrl = if ($mirror.PackageUrl) { $mirror.PackageUrl } else { $mirror.InstallScriptUrl }
                $reachable = $false
                $probeSize = 0
                
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    Write-Host "   ↳ [阶段 1/3] 连通性探测（第 $attempt/3 次）：$probeUrl" -ForegroundColor DarkGray
                    $probeStart = [DateTime]::Now
                    $probe = Test-UrlReachable -Url $probeUrl -TimeoutSec 8
                    $probeElapsed = [Math]::Round(([DateTime]::Now - $probeStart).TotalSeconds, 1)
                    
                    if ($probe.Ok) {
                        Write-Host "   ↳ 连通性 OK（用时 $probeElapsed 秒，大小 $([Math]::Round($probe.Size/1MB,2)) MB）" -ForegroundColor DarkGray
                        $reachable = $true
                        $probeSize = $probe.Size
                        break
                    } else {
                        Write-Warn "   第 $attempt/3 次探测失败（用时 $probeElapsed 秒）：$($probe.Error)"
                        if ($attempt -lt 3) {
                            Write-Host "   ↳ 2 秒后重试..." -ForegroundColor DarkGray
                            Start-Sleep -Seconds 2
                        }
                    }
                }
                
                if (-not $reachable) {
                    Write-Warn "镜像 $($mirror.Name) 无法连通，切换下一个镜像"
                    continue
                }
                
                # ---- 阶段 2：下载安装脚本 / 安装包 ----
                if ($mirror.PackageUrl) {
                    # 下载 nupkg 到本地，然后直接解压安装（不走官方 install.ps1，减少网络依赖）
                    $localNupkg = Join-Path $tmpDir "chocolatey.nupkg"
                    Write-Info "[阶段 2/3] 下载 Chocolatey 安装包..."
                    try {
                        Invoke-DownloadWithProgress -Url $mirror.PackageUrl -OutFile $localNupkg -TimeoutSec 120 -Activity "下载 Chocolatey 安装包（$($mirror.Name)）"
                    } catch {
                        Write-Warn "安装包下载失败：$($_.Exception.Message)"
                        continue
                    }
                    
                    # 校验下载的文件确实是 zip/nupkg（避免下到 HTML 错误页）
                    $fileBytes = [System.IO.File]::ReadAllBytes($localNupkg)
                    if ($fileBytes.Length -lt 1024 -or $fileBytes[0] -ne 0x50 -or $fileBytes[1] -ne 0x4B) {
                        Write-Warn "下载的文件不是有效的 nupkg 包（可能是错误页），文件大小：$($fileBytes.Length) 字节"
                        continue
                    }
                    
                    # ---- 阶段 3：本地解压安装 ----
                    Write-Info "[阶段 3/3] 本地解压并安装 Chocolatey..."
                    $installStart = [DateTime]::Now
                    try {
                        Install-ChocolateyFromNupkg -NupkgPath $localNupkg
                    } catch {
                        Write-Warn "本地解压安装失败：$($_.Exception.Message)"
                        continue
                    }
                    $installElapsed = [Math]::Round(([DateTime]::Now - $installStart).TotalSeconds, 1)
                    Write-Host "   ↳ 本地安装完毕，用时 $installElapsed 秒" -ForegroundColor DarkGray
                } else {
                    # 官方源：走原始 install.ps1 流程
                    $scriptUrl = $mirror.InstallScriptUrl
                    $localScript = Join-Path $tmpDir "install.ps1"
                    Write-Info "[阶段 2/3] 下载官方安装脚本 install.ps1..."
                    try {
                        Invoke-DownloadWithProgress -Url $scriptUrl -OutFile $localScript -TimeoutSec 30 -Activity "下载 Chocolatey 安装脚本"
                    } catch {
                        Write-Warn "安装脚本下载失败：$($_.Exception.Message)"
                        continue
                    }
                    
                    # ---- 阶段 3：执行官方安装脚本 ----
                    Write-Info "[阶段 3/3] 执行 Chocolatey 官方安装脚本（可能需要 30-60 秒）..."
                    Write-Host "   ↳ Chocolatey 自身正在解压、注册 PATH、刷新环境..." -ForegroundColor DarkGray
                    $installStart = [DateTime]::Now
                    
                    $installScript = Get-Content -Path $localScript -Raw -Encoding UTF8
                    Invoke-Expression $installScript
                    
                    $installElapsed = [Math]::Round(([DateTime]::Now - $installStart).TotalSeconds, 1)
                    Write-Host "   ↳ 安装脚本执行完毕，用时 $installElapsed 秒" -ForegroundColor DarkGray
                }
                
                # 刷新环境变量
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                if (Test-Path "$env:ProgramData\chocolatey\bin") {
                    $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
                }
                
                if (Test-Command "choco") {
                    Write-Ok "Chocolatey 安装成功（使用 $($mirror.Name) 镜像）"
                    $installed = $true
                    break
                } else {
                    Write-Warn "安装脚本已执行但未检测到 choco 命令，尝试下一个镜像"
                }
            } catch {
                Write-Warn "使用 $($mirror.Name) 镜像安装失败：$($_.Exception.Message)"
                continue
            }
        }
        
        # 清理临时目录
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        
        if (-not $installed) {
            # 所有在线镜像都失败 —— 提示用户手动下载并兜底
            Write-Warn "所有在线镜像均失败，尝试离线安装方案..."
            Write-Host ""
            Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
            Write-Host " 请手动下载 Chocolatey 安装包（任选一种方式）：" -ForegroundColor Yellow
            Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
            Write-Host " 方式 A：用浏览器打开以下任一链接，下载 chocolatey.$chocoVersion.nupkg：" -ForegroundColor White
            Write-Host "   1. https://ghfast.top/https://github.com/chocolatey/choco/releases/download/$chocoVersion/chocolatey.$chocoVersion.nupkg" -ForegroundColor Cyan
            Write-Host "   2. https://gh-proxy.com/https://github.com/chocolatey/choco/releases/download/$chocoVersion/chocolatey.$chocoVersion.nupkg" -ForegroundColor Cyan
            Write-Host "   3. https://github.com/chocolatey/choco/releases/download/$chocoVersion/chocolatey.$chocoVersion.nupkg" -ForegroundColor Cyan
            Write-Host ""
            Write-Host " 方式 B：从其他能联网的机器下载后通过 U 盘/网络共享传过来" -ForegroundColor White
            Write-Host ""
            Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
            
            $manualPath = Read-WithDefault "请输入已下载的 nupkg 文件完整路径（留空则放弃）" ""
            if ([string]::IsNullOrWhiteSpace($manualPath) -or -not (Test-Path $manualPath)) {
                throw "未提供有效的 nupkg 文件，请检查网络或手动安装 Chocolatey"
            }
            
            Write-Info "使用本地 nupkg 文件安装：$manualPath"
            Install-ChocolateyFromNupkg -NupkgPath $manualPath
            
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            if (Test-Path "$env:ProgramData\chocolatey\bin") {
                $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
            }
            
            if (Test-Command "choco") {
                Write-Ok "Chocolatey 离线安装成功"
                $installed = $true
            } else {
                throw "离线安装后仍未检测到 choco 命令"
            }
        }
        
        # 安装成功后，配置 Chocolatey 使用国内镜像作为默认源
        Set-ChocolateyMirror
        
    } catch {
        throw "Chocolatey 安装失败: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 从 nupkg 文件本地解压安装 Chocolatey（不需要再次联网）
# nupkg 本质是 zip，解压到 %ProgramData%\chocolatey，然后调用其中的 chocolateyInstall.ps1
# ---------------------------------------------------------------------------
function Install-ChocolateyFromNupkg {
    param([Parameter(Mandatory=$true)][string]$NupkgPath)
    
    if (-not (Test-Path $NupkgPath)) {
        throw "找不到 nupkg 文件：$NupkgPath"
    }
    
    # 二次确认管理员权限（不能靠 chocolateyInstall.ps1 自己检查，它会 throw 中断流程）
    if (-not (Test-IsAdministrator)) {
        throw "需要管理员权限才能安装 Chocolatey 到 $env:ProgramData\chocolatey，请以管理员身份重新运行 PowerShell"
    }
    
    $chocoInstallRoot = Join-Path $env:ProgramData "chocolatey"
    $extractTmp = Join-Path $env:TEMP "obsidian-sync-choco-extract"
    
    # 每次调用都强制清理旧的临时目录（关键：防止上一轮失败残留导致 ZipFile.ExtractToDirectory 报"文件已存在"）
    if (Test-Path $extractTmp) {
        Remove-Item -Path $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
        # 等待文件系统释放句柄
        Start-Sleep -Milliseconds 200
    }
    New-Item -ItemType Directory -Path $extractTmp -Force | Out-Null
    
    try {
        # 解压 nupkg（它就是一个 zip）
        Write-Host "   ↳ 解压 nupkg 到临时目录..." -ForegroundColor DarkGray
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($NupkgPath, $extractTmp)
        
        # 创建 Chocolatey 主目录
        if (-not (Test-Path $chocoInstallRoot)) {
            New-Item -ItemType Directory -Path $chocoInstallRoot -Force | Out-Null
        }
        
        $toolsDir = Join-Path $extractTmp "tools"
        if (-not (Test-Path $toolsDir)) {
            throw "nupkg 中未找到 tools 目录，包结构异常"
        }
        
        # 直接采用"文件复制"方式部署，完全不执行 chocolateyInstall.ps1
        # 原因：Chocolatey 2.x 自带的 chocolateyInstall.ps1 会重复检查管理员身份、
        #       设置各种复杂环境变量，任一步出错都会中断；对我们而言只需要 choco.exe 可用即可
        Write-Host "   ↳ 部署 Chocolatey 文件到 $chocoInstallRoot ..." -ForegroundColor DarkGray
        
        # 复制 tools 目录下的所有内容到 chocolatey 根目录
        # tools 下结构通常为：tools/chocolateyInstall/{choco.exe, helpers/, redirects/, ...}
        $innerInstallDir = Join-Path $toolsDir "chocolateyInstall"
        if (Test-Path $innerInstallDir) {
            # Chocolatey 2.x 结构：tools/chocolateyInstall/ 是真正的安装根
            Copy-Item -Path "$innerInstallDir\*" -Destination $chocoInstallRoot -Recurse -Force
        } else {
            # 兼容：直接把 tools 下所有内容复制过去
            Copy-Item -Path "$toolsDir\*" -Destination $chocoInstallRoot -Recurse -Force
        }
        
        # 校验核心可执行文件
        $chocoExe = Join-Path $chocoInstallRoot "choco.exe"
        if (-not (Test-Path $chocoExe)) {
            # 某些包 choco.exe 在 bin 子目录
            $chocoExeAlt = Join-Path $chocoInstallRoot "bin\choco.exe"
            if (Test-Path $chocoExeAlt) {
                $chocoExe = $chocoExeAlt
            } else {
                throw "部署完成但未找到 choco.exe，请检查 nupkg 结构"
            }
        }
        
        # 确保 bin 目录存在（用作 PATH 注册点），choco.exe 需要出现在 PATH 中
        $chocoBinDir = Join-Path $chocoInstallRoot "bin"
        if (-not (Test-Path $chocoBinDir)) {
            New-Item -ItemType Directory -Path $chocoBinDir -Force | Out-Null
        }
        # 若 choco.exe 在根目录，则在 bin 下做一个拷贝（Chocolatey 官方行为也是如此）
        $binChoco = Join-Path $chocoBinDir "choco.exe"
        if (-not (Test-Path $binChoco)) {
            Copy-Item -Path $chocoExe -Destination $binChoco -Force
        }
        
        # 注册系统级环境变量（管理员权限下写 Machine）
        Write-Host "   ↳ 注册系统 PATH 与 ChocolateyInstall 环境变量..." -ForegroundColor DarkGray
        [System.Environment]::SetEnvironmentVariable("ChocolateyInstall", $chocoInstallRoot, "Machine")
        
        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($machinePath -notlike "*$chocoBinDir*") {
            [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;$chocoBinDir", "Machine")
        }
        
        # 同时刷新当前进程环境，避免需要重启终端
        $env:ChocolateyInstall = $chocoInstallRoot
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        Write-Host "   ↳ Chocolatey 已部署到 $chocoInstallRoot" -ForegroundColor DarkGray
    } finally {
        # 清理临时解压目录
        Remove-Item -Path $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 管理员权限检查与自动提权
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-AdminElevation {
    if (Test-IsAdministrator) { return $true }
    
    Write-Warn "当前不是管理员身份运行，Chocolatey 安装需要管理员权限"
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " 选项：" -ForegroundColor Yellow
    Write-Host "   1) 自动以管理员身份重新启动本脚本（推荐）" -ForegroundColor White
    Write-Host "   2) 手动退出，自行右键 PowerShell -> 以管理员身份运行后重试" -ForegroundColor White
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    
    if (Confirm "是否自动以管理员身份重新启动本脚本？" "Y") {
        $scriptPath = $MyInvocation.PSCommandPath
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        if (-not $scriptPath) {
            # 在某些交互式执行中 $PSCommandPath 可能为空，从脚本根变量获取
            $scriptPath = (Get-Variable -Name MyInvocation -Scope Script -ErrorAction SilentlyContinue).Value.MyCommand.Path
        }
        
        if ($scriptPath -and (Test-Path $scriptPath)) {
            Write-Info "正在以管理员身份启动：$scriptPath"
            try {
                Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"" `
                    -Verb RunAs
                Write-Ok "已启动管理员窗口，当前窗口将退出"
                exit 0
            } catch {
                Write-Error "UAC 提权被拒绝或失败：$($_.Exception.Message)"
                return $false
            }
        } else {
            Write-Error "无法定位脚本路径，请手动以管理员身份重新运行"
            return $false
        }
    }
    return $false
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
        # 不要写 `return if (...) {...} else {...}`，PowerShell 会把 if 当独立语句报错
        if ($cred) {
            return $cred.GetNetworkCredential().Password
        } else {
            return $null
        }
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
        $adminMark = if (Test-IsAdministrator) { "[管理员]" } else { "[普通用户]" }
        Write-Host "运行身份: $adminMark" -ForegroundColor Gray
        Write-Host ""
        
        # 编码检测与修复（解决远程桌面乱码问题）
        Test-AndFix-Encoding
        
        # 管理员权限检查（安装 Chocolatey / Windows 服务需要管理员）
        if (-not (Test-IsAdministrator)) {
            if (-not (Request-AdminElevation)) {
                throw "需要管理员权限才能继续，请以管理员身份重新运行脚本"
            }
        }
        
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