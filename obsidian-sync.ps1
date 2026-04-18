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
# 注意：不开启 Set-StrictMode -Version Latest
#   - 我们大量使用 $global:SSH_HOST 这种跨作用域全局变量
#   - JSON 反序列化后可能访问可选字段 ($config.server.host)，Latest 下会对缺失字段抛异常
#   - 使用较宽松的 2.0 可覆盖未声明变量/未初始化属性的主要风险，且不干扰正常流程
Set-StrictMode -Version 2.0

# ============================================================================
# 编码设置与修复（解决VSCode和PowerShell终端中文显示不一致问题）
# ============================================================================

# 强制设置UTF-8编码（在脚本开始时立即执行）
# 注意：此函数在顶层调用时，Write-Warn 等日志函数尚未定义，所以内部只能用
#       原生 Write-Host/Write-Warning，不要调用项目内的自定义日志函数！
function Initialize-Encoding {
    try {
        # 1. 设置PowerShell内部编码
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $PSDefaultParameterValues['*:Encoding'] = 'UTF8'
        
        # 2. 设置系统代码页为UTF-8
        $null = chcp 65001 2>&1
        
        # 3. 设置环境变量（影响子进程）
        $env:PYTHONIOENCODING = "utf-8"
        $env:LANG = "en_US.UTF-8"
        
        # 4. 等待代码页切换落盘
        Start-Sleep -Milliseconds 50
        
        return $true
    } catch {
        # 顶层调用时自定义 Write-Warn 可能还没定义，用原生 Write-Warning 保证一定可用
        Write-Warning "编码初始化失败: $($_.Exception.Message)"
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
            Write-Err "编码设置完全失败，中文可能显示异常"
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

# ---------------------------------------------------------------------------
# 日志包装函数
# 注意事项：
#   1) *不要* 把函数命名为 Write-Error —— 它是 PowerShell 内置 cmdlet，
#      覆盖后会让 $ErrorActionPreference='Stop' 语义失效，主流程 catch 永远捕捉不到。
#      因此改名为 Write-Err。
#   2) 使用显式 [string]$Message 接参而不是 $args（数组），避免
#      Set-StrictMode 下参数绑定与类型转换的边界行为。
# ---------------------------------------------------------------------------
function Write-Info { param([string]$Message) Write-Log "INFO" $Message -Color "Blue" }
function Write-Ok   { param([string]$Message) Write-Log "OK"   $Message -Color "Green" }
function Write-Warn { param([string]$Message) Write-Log "WARN" $Message -Color "Yellow" }
function Write-Err  { param([string]$Message) Write-Log "ERR"  $Message -Color "Red" }
function Write-Step { param([string]$Message) Write-Log "STEP" $Message -Color "Cyan" }
function Write-Hint { param([string]$Message) Write-Host "   ↳ $Message" -ForegroundColor "DarkGray" }

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

# ---------------------------------------------------------------------------
# 检测 Chocolatey 安装是否完整（自修复早期版本用"解压复制法"部署时漏掉的文件）
# 判定"损坏"的信号：
#   - C:\ProgramData\chocolatey\lib\chocolatey\chocolatey.nupkg 不存在
#   - choco install 返回 "installed 0/0 packages" 但没有真实报错
# 损坏时尝试补齐缺失的 nupkg 文件，避免所有后续 choco install 全部静默失败
# ---------------------------------------------------------------------------
function Test-ChocolateyHealth {
    if (-not (Test-Command "choco")) { return $true }  # 未安装就不检测
    
    $chocoRoot = $env:ChocolateyInstall
    if (-not $chocoRoot) { $chocoRoot = "$env:ProgramData\chocolatey" }
    
    $libSelfNupkg = Join-Path $chocoRoot "lib\chocolatey\chocolatey.nupkg"
    if (-not (Test-Path $libSelfNupkg)) {
        return $false
    }
    
    # 额外校验：nupkg 文件必须是合法 zip（前两字节 PK）
    try {
        $fs = [System.IO.File]::OpenRead($libSelfNupkg)
        $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
        $fs.Close()
        if ($b0 -ne 0x50 -or $b1 -ne 0x4B) { return $false }
    } catch {
        return $false
    }
    
    return $true
}

# ---------------------------------------------------------------------------
# 在常见位置搜索已存在的 chocolatey nupkg（上一次安装残留、用户手动下载等）
# 命中即可完全跳过下载，修复滑滞前退到 0 秒
# ---------------------------------------------------------------------------
function Find-LocalChocolateyNupkg {
    param([string]$Version = "2.7.1")
    
    $candidates = @(
        # 本脚本上一次安装时的临时下载
        "$env:TEMP\obsidian-sync-choco\chocolatey.nupkg",
        "$env:TEMP\obsidian-sync-choco-repair\chocolatey.nupkg",
        # choco 官方安装时自己的临时包（无论新老版本都可能在）
        "$env:TEMP\chocolatey\chocoInstall\chocolatey.zip",
        "$env:TEMP\chocolatey\chocolatey.nupkg",
        # 用户的常见下载目录
        "$env:USERPROFILE\Downloads\chocolatey.$Version.nupkg",
        "$env:USERPROFILE\Downloads\chocolatey.nupkg",
        "$env:USERPROFILE\Desktop\chocolatey.$Version.nupkg",
        "$env:USERPROFILE\Desktop\chocolatey.nupkg"
    )
    
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) {
            try {
                $fs = [System.IO.File]::OpenRead($p)
                $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
                $fs.Close()
                if ($b0 -eq 0x50 -and $b1 -eq 0x4B) {
                    $size = (Get-Item $p).Length
                    if ($size -gt 1MB) {
                        return $p
                    }
                }
            } catch { }
        }
    }
    
    # 重拳击：将 %USERPROFILE%\Downloads 所有 *.nupkg 扫一遍，找匹配名称的
    $downloadsDir = Join-Path $env:USERPROFILE "Downloads"
    if (Test-Path $downloadsDir) {
        try {
            $match = Get-ChildItem -Path $downloadsDir -Filter "chocolatey*.nupkg" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 1MB } |
                Select-Object -First 1
            if ($match) { return $match.FullName }
        } catch { }
    }
    
    return $null
}

# ---------------------------------------------------------------------------
# 多镜像并发下载：所有镜像同时开始下载，首个完成的胜出，其余取消
# 比串行轮询快几倍，尤其是某些镜像在限速时
# 返回胜出的本地文件路径，失败时返回 $null
# ---------------------------------------------------------------------------
function Invoke-ParallelDownload {
    param(
        [Parameter(Mandatory=$true)][string[]]$Urls,
        [Parameter(Mandatory=$true)][string]$OutDir,
        [Parameter(Mandatory=$true)][string]$FinalOutFile,
        [int]$TimeoutSec = 120,
        [int]$MinSizeBytes = 1048576   # 1 MB
    )
    
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    
    # 为每个 URL 启动一个后台 Job，各自写到独立临时文件
    $jobs = @()
    $i = 0
    foreach ($url in $Urls) {
        $i++
        $tmpFile = Join-Path $OutDir "candidate_$i.bin"
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
        
        $job = Start-Job -ScriptBlock {
            param($jobUrl, $jobOutFile, $jobTimeout)
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
                $client = New-Object System.Net.WebClient
                $client.Headers.Add("User-Agent", "PowerShell/obsidian-sync")
                # WebClient 没有 Timeout 属性，用异步 + 等待来控制
                $task = $client.DownloadFileTaskAsync($jobUrl, $jobOutFile)
                if ($task.Wait([TimeSpan]::FromSeconds($jobTimeout))) {
                    return @{ Success = $true; File = $jobOutFile; Url = $jobUrl }
                } else {
                    $client.CancelAsync()
                    return @{ Success = $false; Url = $jobUrl; Error = "超时" }
                }
            } catch {
                return @{ Success = $false; Url = $jobUrl; Error = $_.Exception.Message }
            } finally {
                if ($client) { $client.Dispose() }
            }
        } -ArgumentList $url, $tmpFile, $TimeoutSec
        
        $jobs += @{ Job = $job; Url = $url; File = $tmpFile; Index = $i }
        Write-Host "   ↳ [并发 $i] 已启动: $url" -ForegroundColor DarkGray
    }
    
    # 轮询：监控所有 Job 的临时文件大小 + 状态，首个成功下完合法文件的胜出
    $winner = $null
    $startTime = [DateTime]::Now
    $deadline = $startTime.AddSeconds($TimeoutSec)
    $lastReport = $startTime
    
    while ($null -eq $winner -and [DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 500
        
        # 每 2 秒汇报一次各路进度
        $now = [DateTime]::Now
        if (($now - $lastReport).TotalSeconds -ge 2) {
            $report = @()
            foreach ($j in $jobs) {
                $sizeMB = 0
                if (Test-Path $j.File) {
                    $sizeMB = [Math]::Round((Get-Item $j.File).Length / 1MB, 2)
                }
                $state = $j.Job.State
                $report += "[$($j.Index)]${sizeMB}MB/$state"
            }
            $elapsed = [Math]::Round(($now - $startTime).TotalSeconds, 1)
            Write-Host "   ↳ 并发进度[${elapsed}s]: $($report -join '  ')" -ForegroundColor DarkGray
            $lastReport = $now
        }
        
        foreach ($j in $jobs) {
            if ($j.Job.State -eq "Completed") {
                # 即使 Job 失败，只要临时文件体积达标且是合法 zip，就认为胜出
                # 这样可以避开 StrictMode 对 hashtable 缺字段的严格检查
                Receive-Job -Job $j.Job -ErrorAction SilentlyContinue | Out-Null
                if (Test-Path $j.File) {
                    $size = (Get-Item $j.File).Length
                    if ($size -ge $MinSizeBytes) {
                        try {
                            $fs = [System.IO.File]::OpenRead($j.File)
                            $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
                            $fs.Close()
                            if ($b0 -eq 0x50 -and $b1 -eq 0x4B) {
                                $winner = $j
                                break
                            }
                        } catch { }
                    }
                }
            }
        }
    }
    
    # 停掉所有还在跑的 Job
    foreach ($j in $jobs) {
        if ($j.Job.State -eq "Running") {
            Stop-Job -Job $j.Job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $j.Job -Force -ErrorAction SilentlyContinue
    }
    
    if ($null -eq $winner) {
        # 清理所有临时文件
        foreach ($j in $jobs) {
            Remove-Item $j.File -Force -ErrorAction SilentlyContinue
        }
        return $null
    }
    
    # 胜出者重命名为最终文件，清理其他临时文件
    if (Test-Path $FinalOutFile) { Remove-Item $FinalOutFile -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $winner.File -Destination $FinalOutFile -Force
    foreach ($j in $jobs) {
        if ($j.Index -ne $winner.Index) {
            Remove-Item $j.File -Force -ErrorAction SilentlyContinue
        }
    }
    
    $elapsedTotal = [Math]::Round(([DateTime]::Now - $startTime).TotalSeconds, 1)
    $sizeMB = [Math]::Round((Get-Item $FinalOutFile).Length / 1MB, 2)
    Write-Ok "并发下载完成：胜出镜像 [通道 $($winner.Index)]，$sizeMB MB，用时 $elapsedTotal 秒"
    Write-Hint "胜出 URL: $($winner.Url)"
    
    return $FinalOutFile
}

function Repair-Chocolatey {
    Write-Step "修复 Chocolatey 安装"
    
    if (-not (Test-IsAdministrator)) {
        throw "修复 Chocolatey 需要管理员权限"
    }
    
    $chocoRoot = $env:ChocolateyInstall
    if (-not $chocoRoot) { $chocoRoot = "$env:ProgramData\chocolatey" }
    
    Write-Info "检测到 Chocolatey 包索引损坏（缺失 lib\chocolatey\chocolatey.nupkg）"
    
    # ---- 优化 1：先尝试从本地复用已有的 nupkg，命中则 0 秒完成 ----
    $chocoVersion = "2.7.1"
    $libSelfDir = Join-Path $chocoRoot "lib\chocolatey"
    if (-not (Test-Path $libSelfDir)) {
        New-Item -ItemType Directory -Path $libSelfDir -Force | Out-Null
    }
    $libSelfNupkg = Join-Path $libSelfDir "chocolatey.nupkg"
    
    $localExisting = Find-LocalChocolateyNupkg -Version $chocoVersion
    if ($localExisting) {
        $sizeMB = [Math]::Round((Get-Item $localExisting).Length / 1MB, 2)
        Write-Ok "发现本地已有 chocolatey nupkg：$localExisting（$sizeMB MB）"
        Write-Info "直接复用，跳过网络下载"
        Copy-Item -Path $localExisting -Destination $libSelfNupkg -Force
        Write-Ok "已补齐 choco 包索引: $libSelfNupkg"
        return
    }
    
    # ---- 优化 2：本地没有则多镜像并发下载 ----
    Write-Info "本地未找到可复用 nupkg，启动多镜像并发下载..."
    $tmpDir = Join-Path $env:TEMP "obsidian-sync-choco-repair"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    
    $githubPath = "chocolatey/choco/releases/download/$chocoVersion/chocolatey.$chocoVersion.nupkg"
    $mirrorUrls = @(
        "https://ghfast.top/https://github.com/$githubPath",
        "https://gh-proxy.com/https://github.com/$githubPath",
        "https://mirror.ghproxy.com/https://github.com/$githubPath",
        "https://ghproxy.net/https://github.com/$githubPath",
        "https://gh.ddlc.top/https://github.com/$githubPath",
        "https://github.com/$githubPath"
    )
    
    $localNupkg = Join-Path $tmpDir "chocolatey.nupkg"
    $winner = Invoke-ParallelDownload -Urls $mirrorUrls -OutDir $tmpDir -FinalOutFile $localNupkg -TimeoutSec 90 -MinSizeBytes 3MB
    
    if (-not $winner) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "所有镜像并发下载均失败；请手动下载 chocolatey.$chocoVersion.nupkg 并放到任意目录后重试"
    }
    
    # 补齐 lib\chocolatey\chocolatey.nupkg
    Copy-Item -Path $localNupkg -Destination $libSelfNupkg -Force
    Write-Ok "已补齐 choco 包索引: $libSelfNupkg"
    
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 修复 Chocolatey 源配置
# 早期版本错误地把"华为云 NuGet 镜像"添加为优先级 1 并禁用官方源，
# 但华为云 NuGet 源只包含 .NET 类库，不包含 Chocolatey 应用包（putty/jq/fzf 等），
# 导致所有应用包安装失败："The package was not found with the source(s) listed"
# 此函数自动检测并修复：删除错误镜像、重新启用官方 chocolatey 源
# ---------------------------------------------------------------------------
function Repair-ChocolateySources {
    if (-not (Test-Command "choco")) { return }
    
    try {
        $sourceList = & choco source list 2>&1 | Out-String
    } catch {
        return
    }
    
    $needsRepair = $false
    
    # 信号 1：存在华为云 NuGet 镜像（误用为 choco 源）
    if ($sourceList -match "huaweicloud") {
        $needsRepair = $true
    }
    
    # 信号 2：官方 chocolatey 源被禁用
    # 官方源行的典型格式：chocolatey - https://community.chocolatey.org/api/v2/ [Priority 0|Bypass Proxy - False|Self-Service - False|Admin Only - False]
    # 禁用时行首会出现 "[Disabled]" 或 choco source list 会标记
    if ($sourceList -match "(?im)^chocolatey\s+.*\[Disabled\]" -or 
        $sourceList -match "(?im)chocolatey.*Disabled\s*=\s*True") {
        $needsRepair = $true
    }
    
    if (-not $needsRepair) { return }
    
    Write-Warn "检测到 Chocolatey 源配置异常（早期版本错误配置了不兼容的华为云 NuGet 源）"
    Write-Hint "这会导致 choco install putty/jq/fzf 等应用包全部失败"
    Write-Info "正在自动修复..."
    
    try {
        # 1) 删除错误的华为云源
        if ($sourceList -match "huaweicloud") {
            & choco source remove -n="huaweicloud" 2>&1 | Out-Null
            Write-Ok "已移除华为云 NuGet 源"
        }
        
        # 2) 重新启用官方 chocolatey 源
        & choco source enable -n="chocolatey" 2>&1 | Out-Null
        Write-Ok "已启用 Chocolatey 官方源"
        
        # 3) 验证修复结果
        $newList = & choco source list 2>&1 | Out-String
        if ($newList -match "(?im)^chocolatey\s+-\s+https://community\.chocolatey\.org") {
            Write-Ok "Chocolatey 源配置已修复"
        } else {
            Write-Warn "源配置修复可能未生效，请手动检查：choco source list"
        }
    } catch {
        Write-Warn "源配置修复失败：$($_.Exception.Message)"
        Write-Hint "请手动执行："
        Write-Hint "  choco source remove -n=huaweicloud"
        Write-Hint "  choco source enable -n=chocolatey"
    }
}

# ---------------------------------------------------------------------------
# 包装 choco install：自动识别临时性网络错误（503/超时/连接重置）并重试
# 返回一个 hashtable：@{ Success=bool; Output=string; IsNetworkError=bool; IsChocoBroken=bool }
# 调用方可根据 IsNetworkError / IsChocoBroken 给出更准确的提示
# ---------------------------------------------------------------------------
function Invoke-ChocoInstallWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$PackageName,
        [int]$MaxRetries = 4,
        [int]$InitialDelaySec = 3
    )
    
    # 备用源：第 1-2 次用默认源，第 3 次显式指定官方源，第 4 次切到 CDN 源
    # packages.chocolatey.org 是官方的直接包下载 CDN，community.chocolatey.org 503 时常可用
    $sourceRotation = @(
        $null,                                                  # 默认源（使用 choco.config 里的）
        $null,
        "https://community.chocolatey.org/api/v2/",             # 显式官方源
        "https://packages.chocolatey.org/"                      # 备用 CDN
    )
    
    $attempt = 0
    $delay = $InitialDelaySec
    $lastOutput = ""
    
    while ($attempt -lt $MaxRetries) {
        $attempt++
        $srcForThisTry = $sourceRotation[[Math]::Min($attempt - 1, $sourceRotation.Count - 1)]
        
        $label = if ($srcForThisTry) { "备用源: $srcForThisTry" } else { "默认源" }
        if ($attempt -eq 1) {
            Write-Info "正在执行: choco install $PackageName -y ($label)"
        } else {
            Write-Info "重试 $attempt/$MaxRetries：choco install $PackageName -y ($label)"
        }
        
        if ($srcForThisTry) {
            $chocoOutput = & choco install $PackageName -y --no-progress -s="$srcForThisTry" 2>&1
        } else {
            $chocoOutput = & choco install $PackageName -y --no-progress 2>&1
        }
        $exitCode = $LASTEXITCODE
        $chocoOutput | ForEach-Object { Write-Host "   ↳ $_" -ForegroundColor DarkGray }
        $outputText = ($chocoOutput | Out-String)
        $lastOutput = $outputText
        
        # 判定：本体损坏的特征（不可重试）
        $isChocoBroken = ($outputText -match "is not a valid nupkg file") -or 
                         ($outputText -match "Chocolatey installed 0/0 packages" -and $outputText -notmatch "503" -and $outputText -notmatch "Unable to find package")
        
        # 判定：网络性临时错误（可重试）
        $isNetworkError = ($outputText -match "503") -or 
                          ($outputText -match "Service Unavailable") -or
                          ($outputText -match "Failed to fetch results from V2 feed") -or
                          ($outputText -match "unable to connect to the remote server") -or
                          ($outputText -match "The operation has timed out") -or
                          ($outputText -match "连接被关闭") -or
                          ($outputText -match "响应状态代码不指示成功") -or
                          ($outputText -match "NuGetResolverInputException")
        
        # 判定：成功安装
        $isSuccess = ($exitCode -eq 0) -and 
                     ($outputText -match "Chocolatey installed 1/1 packages" -or
                      $outputText -match "Chocolatey installed \d+/\d+ packages" -and $outputText -notmatch "installed 0/\d+ packages") -and
                     (-not $isChocoBroken)
        
        if ($isSuccess) {
            return @{ Success = $true; Output = $outputText; IsNetworkError = $false; IsChocoBroken = $false; Attempts = $attempt }
        }
        
        # 本体损坏→立即返回，不重试
        if ($isChocoBroken) {
            return @{ Success = $false; Output = $outputText; IsNetworkError = $false; IsChocoBroken = $true; Attempts = $attempt }
        }
        
        # 网络性错误→指数退避后重试
        if ($isNetworkError -and $attempt -lt $MaxRetries) {
            Write-Warn "检测到临时性网络错误（第 $attempt/$MaxRetries 次），$delay 秒后重试..."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 15)
            continue
        }
        
        # 其他错误（非网络、非 choco 损坏）：也给一次重试机会
        if ($attempt -lt $MaxRetries) {
            Write-Warn "choco install 失败（exit=$exitCode，第 $attempt/$MaxRetries 次），$delay 秒后重试..."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 15)
        }
    }
    
    # 所有重试均失败
    return @{ Success = $false; Output = $lastOutput; IsNetworkError = $true; IsChocoBroken = $false; Attempts = $attempt }
}

# ---------------------------------------------------------------------------
# 从 GitHub 镜像直接下载 PuTTY 便携版（choco 完全不可用时的最后 Fallback）
# PuTTY 官方不在 GitHub，但有多个顶级镜像源：
#   - https://the.earth.li/~sgtatham/putty/latest/w64/   （官方，国内访问不稳定）
#   - https://tartarus.org/~simon/putty-snapshots/w64/    （官方快照）
# 这里我们采用官方压缩包（不需安装，解压即用），装到 ~/.obsidian-sync/bin 后加入 PATH
# ---------------------------------------------------------------------------
function Install-PuTTYFromFallback {
    Write-Info "尝试从官方备用下载 PuTTY 便携包（绕开 Chocolatey）..."
    
    $destDir = Join-Path $env:USERPROFILE ".obsidian-sync\bin\putty"
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    
    # 只需要 plink.exe，不需要整个 PuTTY 套件
    # 官方提供单独的 plink.exe下载：https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe
    $mirrorUrls = @(
        "https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe",
        "https://tartarus.org/~simon/putty-snapshots/w64/plink.exe"
    )
    
    $plinkDest = Join-Path $destDir "plink.exe"
    $downloaded = $false
    foreach ($url in $mirrorUrls) {
        try {
            Write-Info "下载: $url"
            Invoke-DownloadWithProgress -Url $url -OutFile $plinkDest -TimeoutSec 90 -Activity "下载 plink.exe"
            # 简单验证：MZ 头（Windows PE 可执行文件魔数）
            $fs = [System.IO.File]::OpenRead($plinkDest)
            $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
            $fs.Close()
            if ($b0 -eq 0x4D -and $b1 -eq 0x5A) {
                $downloaded = $true
                break
            } else {
                Remove-Item $plinkDest -Force -ErrorAction SilentlyContinue
                Write-Warn "下载的文件不是有效的 Windows 可执行文件，切换下一个源"
            }
        } catch {
            Write-Warn "下载失败: $($_.Exception.Message)"
        }
    }
    
    if (-not $downloaded) {
        throw "所有 PuTTY 备用源均不可访问，无法绕开 Chocolatey 完成安装"
    }
    
    # 加入当前进程 PATH
    if ($env:Path -notlike "*$destDir*") {
        $env:Path = "$destDir;$env:Path"
    }
    
    # 持久化到用户 PATH
    try {
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$destDir*") {
            $newUserPath = if ($userPath) { "$destDir;$userPath" } else { $destDir }
            [System.Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Write-Ok "已把 $destDir 添加到用户 PATH（重启终端后永久生效）"
        }
    } catch {
        Write-Warn "永久化 PATH 失败：$($_.Exception.Message)（本进程内仍可用）"
    }
    
    Write-Ok "PuTTY plink.exe 下载安装成功：$plinkDest"
    return $plinkDest
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
        # 自检：验证 choco 安装是否完整，早期解压部署可能漏掉 lib\chocolatey\chocolatey.nupkg
        if (-not (Test-ChocolateyHealth)) {
            Write-Warn "检测到 Chocolatey 安装不完整（lib\chocolatey\chocolatey.nupkg 缺失或损坏）"
            Write-Hint "这会导致 choco install 静默失败（Chocolatey installed 0/0 packages）"
            if (Confirm "是否立即修复？" "Y") {
                Repair-Chocolatey
            } else {
                throw "Chocolatey 已损坏，无法继续；请选择修复或手动卸载重装"
            }
        } else {
            Write-Ok "已安装：Chocolatey 包管理器"
        }
        
        # 无论 choco 本体是否健康，都检查源配置是否被历史版本破坏
        Repair-ChocolateySources
    }
    
    $required = @("ssh", "curl")
    # Windows 下非交互式 SSH 首选 plink（PuTTY 套件），
    # 已在 Invoke-SSHCommand 内做了兜底；这里只作提示，不强制
    $optional = @(
        @{Name="jq"; Description="JSON 解析"},
        @{Name="fzf"; Description="目录多选 TUI"}
    )
    
    $missing = @()
    foreach ($cmd in $required) {
        if (Test-Command $cmd) {
            Write-Ok "已安装：$cmd"
        } else {
            Write-Err "缺少必需依赖：$cmd"
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
    
    # ---- 非交互式 SSH 客户端检测（plink.exe 优先） ----
    $plinkPath = Get-PlinkPath
    if ($plinkPath) {
        Write-Ok "已安装：plink.exe（PuTTY 非交互式 SSH）→ $plinkPath"
    } elseif (Test-Command "sshpass") {
        Write-Ok "已安装：sshpass（非交互式 SSH 密码登录，备选方案）"
    } else {
        Write-Warn "未检测到 plink.exe 或 sshpass（非交互式 SSH 登录工具）"
        Write-Hint "  - 推荐安装 PuTTY（含 plink.exe）: choco install putty -y"
        Write-Hint "  - 或安装 sshpass（备选）: choco install sshpass -y"
        
        if ((Test-Command "choco") -and (Confirm "是否立即通过 Chocolatey 安装 PuTTY（推荐）？" "Y")) {
            $installedViaChoco = $false
            try {
                # 使用包含自动重试的包装器（应对 503/超时等临时性网络错误）
                $result = Invoke-ChocoInstallWithRetry -PackageName "putty.portable" -MaxRetries 4 -InitialDelaySec 3
                
                if ($result.Success) {
                    $installedViaChoco = $true
                    # 刷新 PATH（合并 Machine+User，去重避免过长）
                    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                    
                    # 主动把 choco bin 加到当前进程 PATH（shim 通常刚生成还没被加载）
                    $chocoBin = "$env:ProgramData\chocolatey\bin"
                    if ((Test-Path $chocoBin) -and ($env:Path -notlike "*$chocoBin*")) {
                        $env:Path = "$chocoBin;$env:Path"
                    }
                    
                    $plinkPath = Get-PlinkPath
                    if ($plinkPath) {
                        Write-Ok "PuTTY 安装成功：$plinkPath"
                        $plinkDir = Split-Path -Parent $plinkPath
                        if ($plinkDir -and ($env:Path -notlike "*$plinkDir*")) {
                            $env:Path = "$plinkDir;$env:Path"
                        }
                    } else {
                        Write-Warn "choco 报安装成功但 plink.exe 未找到，将尝试备用方案"
                        $installedViaChoco = $false
                    }
                } else {
                    # 区分不同失败类型，给出精准提示
                    if ($result.IsChocoBroken) {
                        Write-Err "Chocolatey 包索引损坏（请重启脚本触发 choco 自检修复）"
                    } elseif ($result.IsNetworkError) {
                        Write-Warn "Chocolatey 源在重试 $($result.Attempts) 次后仍不可访问（常见于 503/网络抖动）"
                        Write-Hint "将尝试从官方备用源直接下载 PuTTY"
                    } else {
                        Write-Err "PuTTY 安装失败（重试 $($result.Attempts) 次）"
                    }
                }
            } catch {
                Write-Warn "choco install 流程异常：$($_.Exception.Message)"
            }
            
            # ---- Fallback：GitHub / 官方备用源直接下载 plink.exe ----
            if (-not $installedViaChoco) {
                try {
                    $fallbackPlink = Install-PuTTYFromFallback
                    $plinkPath = Get-PlinkPath
                    if (-not $plinkPath) { $plinkPath = $fallbackPlink }
                    if ($plinkPath) {
                        Write-Ok "已通过备用方案安装 plink.exe：$plinkPath"
                    } else {
                        throw "备用方案完成但 plink.exe 仍无法定位"
                    }
                } catch {
                    Write-Err "备用安装方案也失败：$($_.Exception.Message)"
                    Write-Hint "昤后可手动下载：https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe"
                    Write-Hint "下载后放到任意目录，并把该目录加入 PATH。"
                    throw "前置依赖 plink.exe 未就绪，无法继续"
                }
            }
        } else {
            # 用户拒绝安装 PuTTY，且也没有 sshpass → 无法继续
            throw "前置依赖缺失：需要 plink.exe（PuTTY）或 sshpass 之一才能进行非交互式 SSH 登录"
        }
    }
    
    # ---- 前置依赖最终硬校验：任一 SSH 客户端必须存在，否则立即中止 ----
    $finalPlink = Get-PlinkPath
    if ((-not $finalPlink) -and (-not (Test-Command "sshpass"))) {
        throw "前置依赖检查未通过：plink.exe 与 sshpass 均不可用，无法进行非交互式 SSH 登录"
    }
    
    foreach ($item in $optional) {
        if (Test-Command $item.Name) {
            Write-Ok "已安装：$($item.Name)（$($item.Description)）"
        } else {
            Write-Warn "未检测到 $($item.Name)（$($item.Description)）"
            switch ($item.Name) {
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
        
        # 安装成功后不再配置任何镜像源（历史教训：华为云 NuGet 源不兼容 choco）
        # Chocolatey 官方源已足够好用；如需加速，可后续从代理层面解决，而不是用错误的源替换
        Write-Info "保留 Chocolatey 官方源配置（华为云 NuGet 镜像不兼容，不使用）"
        
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
        
        # ---- 关键修复：补齐 choco 包索引 ----
        # choco install 时会读取 lib\chocolatey\chocolatey.nupkg 校验自身包信息，
        # 若缺失则安装任何包都会出现 "Chocolatey installed 0/0 packages" 的静默失败
        $libSelfDir = Join-Path $chocoInstallRoot "lib\chocolatey"
        if (-not (Test-Path $libSelfDir)) {
            New-Item -ItemType Directory -Path $libSelfDir -Force | Out-Null
        }
        $libSelfNupkg = Join-Path $libSelfDir "chocolatey.nupkg"
        Copy-Item -Path $NupkgPath -Destination $libSelfNupkg -Force
        Write-Host "   ↳ 已补齐 choco 自身包索引: $libSelfNupkg" -ForegroundColor DarkGray
        
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
                Write-Err "UAC 提权被拒绝或失败：$($_.Exception.Message)"
                return $false
            }
        } else {
            Write-Err "无法定位脚本路径，请手动以管理员身份重新运行"
            return $false
        }
    }
    return $false
}

function Set-ChocolateyMirror_DEPRECATED {
    # ⚠ 历史版本遗留的错误逻辑——已废弃，不再调用
    # 原因：华为云 NuGet 源（mirrors.huaweicloud.com/repository/nuget/）只包含 .NET NuGet 包，
    # 不包含 Chocolatey 的应用包（putty/jq/fzf 等）。将其设为优先级 1 并禁用官方源后，
    # 任何 choco install 都会失败。函数仅作为警示保留，不会被调用。
    Write-Warn "Set-ChocolateyMirror 已废弃（华为云 NuGet 不兼容 choco），跳过执行"
    return
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
        # 注意：sc.exe 的语法要求参数名与等号紧挨，等号后接空格再跟值
        $null = sc.exe create $ServiceName binPath= "`"$ExecutablePath`"" DisplayName= "$DisplayName" start= "auto"
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "服务创建成功"
            
            # 设置服务描述
            sc.exe description $ServiceName "$Description" | Out-Null
            
            return $true
        } else {
            throw "服务创建失败 (exit code: $LASTEXITCODE)"
        }
        
    } catch {
        Write-Err "服务安装失败: $($_.Exception.Message)"
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
        Write-Err "服务启动失败: $($_.Exception.Message)"
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
#
# Windows 下非交互 SSH 登录的选型说明：
#   - 首选 plink.exe（PuTTY 套件）：Windows 原生可用，choco install putty 极稳定；
#     支持 -pw 直接传密码、-batch 禁用交互。
#   - 备选 sshpass：Chocolatey 的 sshpass 是 cygwin 版，兼容性差，仅作兜底。
#   - 所有命令行都把 stderr 重定向到 stdout（2>&1），便于上层捕获错误信息。
# ---------------------------------------------------------------------------

# 查找 plink.exe 的绝对路径
# Chocolatey 安装 PuTTY 后的常见位置（choco 会装 putty.portable，plink 在 lib 下）：
#   - C:\Program Files\PuTTY\plink.exe                              （官方 MSI 安装）
#   - C:\ProgramData\chocolatey\bin\plink.exe                       （choco shim）
#   - C:\ProgramData\chocolatey\lib\putty.portable\tools\plink.exe  （choco portable）
#   - C:\ProgramData\chocolatey\lib\putty\tools\plink.exe           （choco putty 元包）
function Get-PlinkPath {
    # 1) 优先使用 PATH 中的 plink（最快）
    $cmd = Get-Command "plink.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    
    # 2) 尝试所有已知的静态路径
    $candidates = @(
        "$env:ProgramFiles\PuTTY\plink.exe",
        "${env:ProgramFiles(x86)}\PuTTY\plink.exe",
        "$env:ChocolateyInstall\bin\plink.exe",
        "$env:ProgramData\chocolatey\bin\plink.exe",
        "$env:ProgramData\chocolatey\lib\putty.portable\tools\plink.exe",
        "$env:ProgramData\chocolatey\lib\putty\tools\plink.exe",
        "$env:ChocolateyInstall\lib\putty.portable\tools\plink.exe",
        "$env:ChocolateyInstall\lib\putty\tools\plink.exe"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    
    # 3) 兜底：递归扫描 choco 的 lib 目录（刚装完 putty，choco shim 还没生成时的场景）
    $chocoLibDirs = @(
        "$env:ProgramData\chocolatey\lib",
        "$env:ChocolateyInstall\lib"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    
    foreach ($libDir in $chocoLibDirs) {
        try {
            $found = Get-ChildItem -Path $libDir -Filter "plink.exe" -Recurse -ErrorAction SilentlyContinue -Force | 
                Select-Object -First 1
            if ($found) { return $found.FullName }
        } catch { }
    }
    
    return $null
}

# 首次连接时，把远端主机的 host key 写入 HKCU，避免 plink 卡在 "Store key in cache?(y/n)" 交互
function Register-PlinkHostKey {
    param(
        [Parameter(Mandatory=$true)][string]$PlinkPath,
        [Parameter(Mandatory=$true)][string]$SshHost,
        [Parameter(Mandatory=$true)][string]$SshPort
    )
    try {
        # 通过管道喂入 "y" 自动接受 host key；-batch 不能用（否则会直接拒绝未知 host）
        # 注意：只在首次尝试时调用；若已接受过，重复执行也无害
        "y" | & $PlinkPath -ssh -P $SshPort -l $global:SSH_USER -pw $global:SSH_PASS `
            "$($global:SSH_HOST)" "exit" 2>&1 | Out-Null
    } catch {
        # 容忍失败；真正的连接失败会在后续 Invoke-SSHCommand 中再次报出
        Write-Hint "host key 预接受过程提示：$($_.Exception.Message)"
    }
}

function Invoke-SSHCommand {
    param([string]$Command)
    
    if ([string]::IsNullOrEmpty($global:SSH_PASS)) {
        throw "SSH 密码未设置，请先完成 Collect-UserInput"
    }
    
    # ---- 方案 A：plink.exe（首选） ----
    $plinkPath = Get-PlinkPath
    if ($plinkPath) {
        # -batch: 禁用所有交互提示（密码错误/host key 变化等情况直接失败而不是阻塞）
        # -ssh -P port -l user -pw pass host cmd
        $result = & $plinkPath -ssh -batch `
            -P $global:SSH_PORT `
            -l $global:SSH_USER `
            -pw $global:SSH_PASS `
            "$($global:SSH_HOST)" `
            $Command 2>&1
        return $result
    }
    
    # ---- 方案 B：sshpass 兜底（不推荐在 Windows 使用） ----
    if (Test-Command "sshpass") {
        $prevSshpass = $env:SSHPASS
        $env:SSHPASS = $global:SSH_PASS
        try {
            $result = & sshpass -e ssh `
                -o StrictHostKeyChecking=no `
                -o UserKnownHostsFile=/dev/null `
                -p $global:SSH_PORT `
                "$($global:SSH_USER)@$($global:SSH_HOST)" `
                $Command 2>&1
            return $result
        } finally {
            if ($null -eq $prevSshpass) {
                Remove-Item Env:SSHPASS -ErrorAction SilentlyContinue
            } else {
                $env:SSHPASS = $prevSshpass
            }
        }
    }
    
    throw "未找到可用的 SSH 客户端：请安装 PuTTY（choco install putty -y）获取 plink.exe"
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
        Write-Err "SSH 连接失败: $($_.Exception.Message)"
    }
    return $false
}

# ---------------------------------------------------------------------------
# 模块：Windows 凭据管理
# 设计说明：
#   早期版本使用 PowerShell Gallery 上的第三方模块 CredentialManager 提供的
#   Get-StoredCredential / Set-StoredCredential，但该模块并非系统内置，
#   默认 PowerShell 环境下会报 "term not recognized"。
#
#   为最大化兼容性（任何干净的 Windows 10/11 + PowerShell 5.1/7 都能工作），
#   改用 Windows 原生组合方案：
#     1) 用 DPAPI（System.Security.Cryptography.ProtectedData）将密码加密
#        存储为文件，只有同一 Windows 用户在同一台机器上才能解密（CurrentUser 作用域）
#     2) 同时调用内置 cmdkey.exe 在"凭据管理器"里注册一个可见条目，
#        方便用户通过"控制面板 -> 凭据管理器 -> Windows 凭据"查看和删除
#   两者失败时互相独立降级，不影响主流程。
# ---------------------------------------------------------------------------
function Get-CredentialFilePath {
    param([string]$Target)
    $credDir = Join-Path $STATE_DIR "credentials"
    if (-not (Test-Path $credDir)) {
        New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    }
    # 文件名中不能出现 @ : \ / 等特殊字符，做简单替换
    $safeName = $Target -replace '[^a-zA-Z0-9_.-]', '_'
    return Join-Path $credDir "$safeName.cred"
}

function Get-WindowsCredential {
    param([string]$Target)
    
    try {
        $credFile = Get-CredentialFilePath -Target $Target
        if (-not (Test-Path $credFile)) {
            return $null
        }
        
        # 使用 DPAPI 解密（CurrentUser 作用域，只有保存时的那个 Windows 用户能解密）
        Add-Type -AssemblyName System.Security
        $encryptedBase64 = Get-Content -Path $credFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($encryptedBase64)) {
            return $null
        }
        $encryptedBytes = [Convert]::FromBase64String($encryptedBase64.Trim())
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encryptedBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($plainBytes)
    } catch {
        Write-Warn "读取已保存凭据失败，将要求重新输入密码: $($_.Exception.Message)"
        return $null
    }
}

function Set-WindowsCredential {
    param([string]$Target, [string]$Password)
    
    # 1) DPAPI 加密落盘（主存储，保证能回读真实密码）
    try {
        Add-Type -AssemblyName System.Security
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
        $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $encryptedBase64 = [Convert]::ToBase64String($encryptedBytes)
        
        $credFile = Get-CredentialFilePath -Target $Target
        Set-Content -Path $credFile -Value $encryptedBase64 -Encoding UTF8 -NoNewline
        Write-Ok "凭据已加密保存: $credFile"
    } catch {
        Write-Warn "Windows 凭据加密保存失败: $($_.Exception.Message)"
    }
    
    # 2) 同时在"Windows 凭据管理器"注册可视条目（便于用户管理，失败不影响主流程）
    try {
        # /generic 通用凭据，/user 用户标签，/pass 密码本身
        # 注意：cmdkey 参数必须用 = 形式，且整体作为单一字符串传入更稳
        $null = & cmdkey.exe /generic:$Target /user:$Target /pass:$Password 2>&1
    } catch {
        # 不打扰主流程，仅 debug 级别提示
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
        Write-Err "执行失败: $($_.Exception.Message)"
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
    if (-not (Test-Path $STATE_FILE)) { return }
    
    try {
        $config = Get-Content $STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        
        # 注意：StrictMode 下直接访问 $config.server.host，若字段不存在会 throw；
        # 使用 PSObject.Properties 做安全访问
        if ($config -and $config.PSObject.Properties.Name -contains 'server') {
            $server = $config.server
            if ($server.PSObject.Properties.Name -contains 'host') { $global:SSH_HOST = [string]$server.host }
            if ($server.PSObject.Properties.Name -contains 'user') { $global:SSH_USER = [string]$server.user }
            if ($server.PSObject.Properties.Name -contains 'port') { $global:SSH_PORT = [string]$server.port }
            
            if (-not [string]::IsNullOrEmpty($global:SSH_HOST)) {
                Write-Info "已从上次运行记录加载：$($global:SSH_USER)@$($global:SSH_HOST):$($global:SSH_PORT)"
            }
        }
    } catch {
        Write-Warn "加载上次配置失败: $($_.Exception.Message)"
    }
}

# 执行主函数
Main