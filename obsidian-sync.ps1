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

# 远端运行上下文（由步骤 2 填充）
$global:REMOTE_RUN_USER = ""
$global:REMOTE_HOME = ""
$global:REMOTE_CONFIG_DIR = ""
$global:REMOTE_CONFIG_XML = ""

# 本地 Syncthing 上下文（由步骤 4 填充）
#   - 安装目录放 LOCALAPPDATA（免管理员），和 Chocolatey 的 C:\ProgramData\chocolatey 解耦
#   - 配置目录走官方默认 %LOCALAPPDATA%\Syncthing，避免自己发明路径导致未来升级/迁移困难
#   - 版本号与服务器保持一致（v2.x），否则 syncthing v1 <-> v2 协议无法互联
$LOCAL_SYNCTHING_VERSION = "v2.0.16"
$LOCAL_SYNCTHING_HOME = Join-Path $env:LOCALAPPDATA "obsidian-sync\syncthing"
$LOCAL_SYNCTHING_EXE = Join-Path $LOCAL_SYNCTHING_HOME "syncthing.exe"
$LOCAL_SYNCTHING_CONFIG_DIR = Join-Path $env:LOCALAPPDATA "Syncthing"
$LOCAL_SYNCTHING_CONFIG_XML = Join-Path $LOCAL_SYNCTHING_CONFIG_DIR "config.xml"
$LOCAL_SYNCTHING_LOG = Join-Path $STATE_DIR "local-syncthing.log"
$LOCAL_SYNCTHING_PID_FILE = Join-Path $STATE_DIR "local-syncthing.pid"
$global:LOCAL_SYNCTHING_PROCESS = $null

# 回滚栈
$global:ROLLBACK_STACK = @()

# 步骤 6/8 填充：用户选中的本地 Vault 绝对路径数组
$global:SELECTED_VAULTS = @()

# 步骤 6’7 填充：本次 folder 要共享给哪些远端设备（device ID）
# 默认至少包含本次目标服务器 REMOTE_DEVICE_ID，如本地已配对多台远端则可在步骤 7 追加勾选
$global:SELECTED_REMOTE_DEVICES = @()

# 步骤 7/8 填充：本次成功建立的共享 folder 清单
# 每项格式：[pscustomobject]@{ FolderId=...; LocalPath=...; RemotePath=...; Label=... }
$global:SHARED_FOLDERS = @()

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
    #
    # 可选依赖：缺失时不影响核心流程（脚本均已实现降级方案），
    # 但若 Chocolatey 可用会提示用户"一键安装"以提升体验。
    #   - ChocoPkg : choco 包名（留空则不提供自动安装）
    #   - Purpose  : 缺失时的影响说明（显示给用户，帮助其决定是否安装）
    $optional = @(
        @{Name="jq";  Description="JSON 解析";   ChocoPkg="jq";  Purpose="用于解析 Syncthing REST API 的 JSON 响应；缺失时脚本会回退到 PowerShell 原生 ConvertFrom-Json（功能等价）"},
        @{Name="fzf"; Description="目录多选 TUI"; ChocoPkg="fzf"; Purpose="步骤 6/8 Vault 多选时提供带模糊搜索的 TUI 多选界面；缺失时降级为数字菜单（功能可用但体验较差）"}
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
            continue
        }

        Write-Warn "未检测到 $($item.Name)（$($item.Description)）"
        if ($item.Purpose) {
            Write-Hint "用途：$($item.Purpose)"
        }

        # 没有 Chocolatey 或未指定 ChocoPkg，只做提示、不尝试自动装
        $hasChoco = Test-Command "choco"
        if ((-not $hasChoco) -or [string]::IsNullOrWhiteSpace($item.ChocoPkg)) {
            if (-not [string]::IsNullOrWhiteSpace($item.ChocoPkg)) {
                Write-Hint "安装: choco install $($item.ChocoPkg) -y（当前未检测到 choco，可手动安装）"
            }
            continue
        }

        # 交互确认后尝试通过 Chocolatey 安装；复用现成的重试包装器
        if (-not (Confirm "是否立即通过 Chocolatey 安装 $($item.Name)（可选，不装也能用）？" "Y")) {
            Write-Hint "已跳过安装，将自动降级（后续流程不受影响）"
            continue
        }

        $installed = $false
        try {
            $result = Invoke-ChocoInstallWithRetry -PackageName $item.ChocoPkg -MaxRetries 3 -InitialDelaySec 3
            if ($result.Success) {
                # 刷新 PATH 让当前进程立即能调用到 shim
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                $chocoBin = "$env:ProgramData\chocolatey\bin"
                if ((Test-Path $chocoBin) -and ($env:Path -notlike "*$chocoBin*")) {
                    $env:Path = "$chocoBin;$env:Path"
                }

                if (Test-Command $item.Name) {
                    Write-Ok "$($item.Name) 安装成功并已就绪"
                    $installed = $true
                } else {
                    Write-Warn "choco 报安装成功但 $($item.Name) 仍未找到，将继续使用降级方案"
                }
            } else {
                if ($result.IsNetworkError) {
                    Write-Warn "Chocolatey 源在重试 $($result.Attempts) 次后仍不可访问（常见于 503/网络抖动）"
                } elseif ($result.IsChocoBroken) {
                    Write-Warn "Chocolatey 包索引损坏，请稍后重启脚本触发自检修复"
                } else {
                    Write-Warn "$($item.Name) 安装失败（重试 $($result.Attempts) 次）"
                }
            }
        } catch {
            Write-Warn "choco install $($item.ChocoPkg) 流程异常：$($_.Exception.Message)"
        }

        if (-not $installed) {
            Write-Hint "$($item.Name) 未就绪，后续流程将自动走降级方案（不影响核心功能）"
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
        [string]$Activity = "下载中",
        # 速度守护：在 StallWindowSec 秒的窗口内，若平均速度低于 MinSpeedKBps 则放弃本次连接。
        # 默认 0/0 表示关闭此保护（保持旧行为）。
        [int]$MinSpeedKBps = 0,
        [int]$StallWindowSec = 15
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
    # 速度守护用：记录 StallWindowSec 秒前的已下载字节数
    $stallCheckpointTime  = [DateTime]::Now
    $stallCheckpointBytes = 0
    $abortReason = $null
    
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

            # 速度守护：每到达 StallWindowSec 窗口，评估一次窗口内平均速度
            if ($MinSpeedKBps -gt 0) {
                $winSec = ($now - $stallCheckpointTime).TotalSeconds
                if ($winSec -ge $StallWindowSec) {
                    $winBytes = $totalRead - $stallCheckpointBytes
                    $winSpeedKB = if ($winSec -gt 0) { [Math]::Round($winBytes / 1KB / $winSec, 1) } else { 0 }
                    if ($winSpeedKB -lt $MinSpeedKBps) {
                        $abortReason = "窗口内速度 $winSpeedKB KB/s < 阈值 $MinSpeedKBps KB/s（已等待 $([int]$winSec)s），放弃该镜像"
                        break
                    }
                    $stallCheckpointTime  = $now
                    $stallCheckpointBytes = $totalRead
                }
            }
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $response.Close()
        Write-Progress -Activity $Activity -Completed
    }
    
    if ($abortReason) {
        # 删除半成品，向上层抛出让 caller 走镜像降级
        try { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue } catch {}
        throw $abortReason
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
# 返回：$true = 已录入或之前已存在；$false = 录入失败（网络/密码错误等）
function Register-PlinkHostKey {
    param(
        [Parameter(Mandatory=$true)][string]$PlinkPath,
        [Parameter(Mandatory=$true)][string]$SshHost,
        [Parameter(Mandatory=$true)][string]$SshPort
    )
    
    # 快路径：HKCU:\Software\SimonTatham\PuTTY\SshHostKeys 已存在该主机键时直接跳过
    try {
        $regPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
        if (Test-Path $regPath) {
            $entries = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($entries) {
                $keyPattern = "*@${SshPort}:$SshHost"
                $matched = $entries.PSObject.Properties | Where-Object { $_.Name -like $keyPattern }
                if ($matched) {
                    Write-Hint "host key 已缓存，跳过预接收"
                    return $true
                }
            }
        }
    } catch { }
    
    Write-Info "首次连接该服务器，正在预接收 host key..."
    try {
        # 通过管道喂入 "y" 自动接受 host key；-batch 不能用（否则会直接拒绝未知 host）
        # 使用临时文件引导输入以避免 PowerShell 管道编码问题
        $tmpIn = [System.IO.Path]::GetTempFileName()
        "y`ny`n" | Set-Content -Path $tmpIn -NoNewline -Encoding ASCII
        
        $output = cmd.exe /c "`"$PlinkPath`" -ssh -P $SshPort -l $($global:SSH_USER) -pw $($global:SSH_PASS) $SshHost exit < `"$tmpIn`" 2>&1"
        $exitCode = $LASTEXITCODE
        
        Remove-Item $tmpIn -Force -ErrorAction SilentlyContinue
        
        # 检查是否已写入注册表
        $registered = $false
        try {
            $entries = Get-ItemProperty -Path "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys" -ErrorAction SilentlyContinue
            if ($entries) {
                $keyPattern = "*@${SshPort}:$SshHost"
                $registered = [bool]($entries.PSObject.Properties | Where-Object { $_.Name -like $keyPattern })
            }
        } catch { }
        
        if ($registered) {
            Write-Ok "host key 已成功录入 PuTTY 缓存"
            return $true
        }
        
        # 未录入：把 plink 输出暂存起来，供调用方诊断
        $outStr = ($output | Out-String).Trim()
        Write-Warn "host key 预接收未成功（exit=$exitCode）"
        if ($outStr) {
            Write-Host "   ↳ plink 原始输出:" -ForegroundColor DarkGray
            $outStr -split "`r?`n" | Select-Object -First 20 | ForEach-Object {
                Write-Host "   ↳ $_" -ForegroundColor DarkGray
            }
        }
        $global:LAST_PLINK_OUTPUT = $outStr
        return $false
    } catch {
        Write-Warn "host key 预接收过程异常：$($_.Exception.Message)"
        return $false
    }
}

function Invoke-SSHCommand {
    param(
        [string]$Command,
        [switch]$CaptureStderr  # 开启后：失败时抛异常并包含 plink/ssh 原始输出，默认不开以保持向后兼容
    )
    
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
        $exitCode = $LASTEXITCODE
        
        # 失败时将原始输出写入全局变量，便于上层打印诊断
        if ($exitCode -ne 0) {
            $global:LAST_PLINK_OUTPUT = ($result | Out-String).Trim()
            if ($CaptureStderr) {
                $detail = if ($global:LAST_PLINK_OUTPUT) { $global:LAST_PLINK_OUTPUT } else { "(plink 无输出，exit=$exitCode)" }
                throw "plink 执行失败（exit=$exitCode）: $detail"
            }
        }
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
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0 -and $CaptureStderr) {
                $detail = ($result | Out-String).Trim()
                throw "ssh 执行失败（exit=$exitCode）: $detail"
            }
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
    
    # 第一步：预先在 PuTTY 注册表录入 host key，避免 -batch 下首次连接被拒绝
    $plinkPath = Get-PlinkPath
    if ($plinkPath) {
        $registered = Register-PlinkHostKey -PlinkPath $plinkPath -SshHost $global:SSH_HOST -SshPort $global:SSH_PORT
        if (-not $registered) {
            # host key 预接收失败，给出精准诊断
            $out = $global:LAST_PLINK_OUTPUT
            if ($out -match "Access denied|Wrong password|Server refused our password|Disconnected: Too many authentication failures") {
                Write-Err "SSH 登录密码错误（服务器拒绝）"
                Write-Hint "请确认：1) 密码是否正确；2) 目标用户是否允许密码登录（sshd_config: PasswordAuthentication yes）"
                Write-Hint "可执行：Remove-Item '$env:USERPROFILE\.obsidian-sync\credentials\obsidian-sync-$($global:SSH_USER)_$($global:SSH_HOST)_$($global:SSH_PORT).cred' 后重入密码"
                return $false
            }
            if ($out -match "Network error|Connection refused|Connection timed out|No route to host") {
                Write-Err "SSH 网络层连接失败"
                Write-Hint "已知 TCP $($global:SSH_HOST):$($global:SSH_PORT) 通（Test-Connection 返回 True），但 plink 报了网络错误——可能是防火墙深度检测或 SSH 端口上绑定的不是 sshd"
                return $false
            }
            if ($out -match "host key is not cached|Server's host key did not match") {
                Write-Err "host key 写入注册表失败，可能由于权限或策略限制"
                Write-Hint "手动执行一次 plink 并输入 y 接受 host key：& '$plinkPath' -ssh -P $($global:SSH_PORT) -l $($global:SSH_USER) $($global:SSH_HOST) exit"
                return $false
            }
            # 其他未分类错误：直接把 plink 原始输出扔出来
            Write-Err "host key 预接收失败，无法继续"
            if ($out) {
                Write-Host "   ↳ plink 原始输出：" -ForegroundColor DarkGray
                $out -split "`r?`n" | ForEach-Object { Write-Host "   ↳ $_" -ForegroundColor DarkGray }
            }
            return $false
        }
    }
    
    # 第二步：执行探针命令
    try {
        $result = Invoke-SSHCommand -Command "echo __OBSIDIAN_SYNC_PROBE_OK__" -CaptureStderr
        if ($result -match "__OBSIDIAN_SYNC_PROBE_OK__") {
            Write-Ok "SSH 连接测试成功"
            return $true
        }
        # plink exit=0 但输出里没有探针字符串（极少见的调用环境问题）
        Write-Err "SSH 连接返回意外的输出内容"
        $outStr = ($result | Out-String).Trim()
        if ($outStr) {
            Write-Host "   ↳ 实际输出：" -ForegroundColor DarkGray
            $outStr -split "`r?`n" | Select-Object -First 20 | ForEach-Object {
                Write-Host "   ↳ $_" -ForegroundColor DarkGray
            }
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Err "SSH 连接失败: $msg"
        # 基于错误内容给出修复建议
        if ($msg -match "Access denied|Wrong password|Server refused our password") {
            Write-Hint "密码错误：请删除已保存的凭据重新输入"
            Write-Hint "Remove-Item '$env:USERPROFILE\.obsidian-sync\credentials\obsidian-sync-$($global:SSH_USER)_$($global:SSH_HOST)_$($global:SSH_PORT).cred'"
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# 模块：remote —— 服务器端 Syncthing 部署（步骤 2/8）
# 设计要点：
#   - sh 版用一个 heredoc 投送多行脚本到 ssh 远端 bash -s，我们需要
#     用 plink 的 stdin 实现同样效果：把脚本内容写到临时文件 →
#     cmd.exe /c "plink ... bash -s < tempfile" 读取返回
#   - 除了次号引内插值必须用双引外，所有远端脚本均用 PowerShell
#     的单引号 here-string (@'...'@) 包裹，保证 $, ``, ", \
#     等字符不被 PS 解释
#   - 无论成败都将 plink 原始 stdout 以字符串返回，调用方再 awk/regex
#     提取 KV 或校验关键字
# ---------------------------------------------------------------------------
function Invoke-SSHScript {
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [switch]$ThrowOnError  # 开启后，远端 exit 非零时抛异常并包含输出
    )
    
    if ([string]::IsNullOrEmpty($global:SSH_PASS)) {
        throw "SSH 密码未设置，请先完成 Collect-UserInput"
    }
    $plinkPath = Get-PlinkPath
    if (-not $plinkPath) {
        throw "未找到 plink.exe，无法执行远端脚本"
    }
    
    # 1) 将脚本写入临时文件（统一用 LF + UTF8-NoBOM，避免远端 bash 遇到 CRLF 结尾报错）
    $scriptLF = $Script -replace "`r`n", "`n"
    $tmpScript = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpScript, $scriptLF, $utf8NoBom)
    
    try {
        # 2) 通过 cmd.exe 重定向 stdin 给 plink——PowerShell 的 | 管道对同时传递 stdin 与读取 stdout 处理不得很好，改用 cmd 的 < 重定向更稳
        # plink 的 -batch 必须保留（host key 已在 Test-SSHConnection 阺段预接收）
        # 输出捕获使用 2>&1 将 stderr 合并，便于打印完整诊断
        $cmdLine = "`"$plinkPath`" -ssh -batch -P $($global:SSH_PORT) -l $($global:SSH_USER) -pw $($global:SSH_PASS) $($global:SSH_HOST) `"bash -s`" < `"$tmpScript`" 2>&1"
        $rawOutput = cmd.exe /c $cmdLine
        $exitCode = $LASTEXITCODE
        $output = ($rawOutput | Out-String)
        
        if ($exitCode -ne 0 -and $ThrowOnError) {
            throw "远端脚本执行失败（exit=$exitCode）:`n$($output.Trim())"
        }
        return @{
            Success  = ($exitCode -eq 0)
            ExitCode = $exitCode
            Output   = $output
        }
    } finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }
}

# 从 KV 输出中提取单个字段 (形如 KEY=value 的行)
function Get-KVValue {
    param([string]$Text, [string]$Key)
    $pattern = "(?m)^$([regex]::Escape($Key))=(.*)$"
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# ---- 2.1 探测远端环境 ----
function Get-RemoteEnv {
    $script = @'
set -e
. /etc/os-release 2>/dev/null || true
ID_LIKE_STR="${ID_LIKE:-}"
printf "OS_ID=%s\n"        "${ID:-unknown}"
printf "OS_LIKE=%s\n"      "$ID_LIKE_STR"
printf "VERSION_ID=%s\n"   "${VERSION_ID:-unknown}"
if command -v apt-get >/dev/null 2>&1; then printf "PKG_MGR=apt\n"
elif command -v dnf >/dev/null 2>&1; then   printf "PKG_MGR=dnf\n"
elif command -v yum >/dev/null 2>&1; then   printf "PKG_MGR=yum\n"
else                                        printf "PKG_MGR=unknown\n"
fi
if command -v syncthing >/dev/null 2>&1; then
    printf "SYNCTHING_INSTALLED=1\n"
    printf "SYNCTHING_VERSION=%s\n" "$(syncthing --version 2>/dev/null | head -1 | awk '{print $2}')"
else
    printf "SYNCTHING_INSTALLED=0\n"
fi
printf "WHOAMI=%s\n"       "$(whoami)"
printf "HOME=%s\n"         "$HOME"
printf "HAS_SYSTEMD=%s\n"  "$(command -v systemctl >/dev/null 2>&1 && echo 1 || echo 0)"
'@
    $r = Invoke-SSHScript -Script $script -ThrowOnError
    return $r.Output
}

# ---- 2.2 安装远端 Syncthing（强制 v2.x，从 GitHub release 拉二进制） ----
function Install-RemoteSyncthing {
    Write-Info "使用 GitHub release 二进制方式安装 Syncthing（保证 v2.x 与本地 Windows 客户端兼容）..."
    $script = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"

# 1) 已装且 v2.x → 跳过；否则卸旧装

if command -v syncthing >/dev/null 2>&1; then
    cur_ver="$(syncthing --version 2>/dev/null | head -1 | awk '{print $2}')"
    cur_major="${cur_ver#v}"; cur_major="${cur_major%%.*}"
    if [ -n "$cur_major" ] && [ "$cur_major" -ge 2 ] 2>/dev/null; then
        echo "syncthing already >= v2.x ($cur_ver)，跳过"
        exit 0
    fi
    echo "卸载旧版 syncthing ($cur_ver)..."
    $sudo_cmd systemctl stop "syncthing@*" 2>/dev/null || true
    pkill -9 -f "syncthing serve" 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1 && dpkg -l syncthing 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get purge -y syncthing syncthing-discosrv syncthing-relaysrv 2>&1 | tail -3 || true
        $sudo_cmd rm -f /etc/apt/sources.list.d/syncthing*.list \
                        /etc/apt/keyrings/syncthing-archive-keyring.gpg \
                        /etc/apt/keyrings/syncthing-archive-keyring.asc
    elif command -v dnf >/dev/null 2>&1 && dnf list installed syncthing >/dev/null 2>&1; then
        $sudo_cmd dnf remove -y syncthing || true
        $sudo_cmd rm -f /etc/yum.repos.d/syncthing.repo
    elif command -v yum >/dev/null 2>&1 && yum list installed syncthing >/dev/null 2>&1; then
        $sudo_cmd yum remove -y syncthing || true
        $sudo_cmd rm -f /etc/yum.repos.d/syncthing.repo
    fi
    $sudo_cmd rm -f /usr/bin/syncthing /usr/local/bin/syncthing
fi

# 2) 依赖工具
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y -q curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    $sudo_cmd dnf install -y curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
    $sudo_cmd yum install -y curl tar ca-certificates >/dev/null 2>&1 || true
fi

# 3) 架构
uname_m="$(uname -m)"
case "$uname_m" in
    x86_64|amd64)   arch="amd64" ;;
    aarch64|arm64)  arch="arm64" ;;
    armv7l|armv7*)  arch="arm" ;;
    i386|i686)      arch="386" ;;
    *) echo "ERROR: 不支持的 CPU 架构：$uname_m" >&2; exit 1 ;;
esac

# 4) 查最新 v2.x tag
latest_tag=""
if command -v curl >/dev/null 2>&1; then
    latest_tag="$(curl -fsSL --max-time 15 https://api.github.com/repos/syncthing/syncthing/releases/latest 2>/dev/null \
                  | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]+"' \
                  | head -1 \
                  | sed -E 's/.*"(v[^"]+)".*/\1/')"
fi
if [ -z "$latest_tag" ]; then
    latest_tag="v2.0.16"
    echo "WARN: 无法从 GitHub API 获取最新版本号，回退使用 $latest_tag"
fi
echo "将安装 Syncthing $latest_tag ($arch)"

# 5) 下载（按服务器位置智能选源）
#    - 海外服务器（如新加坡/东京/欧美）: GitHub 直连通常最快，国内代理反而绕路更慢
#    - 国内服务器: GitHub 慢，优先走 ghfast.top/gh-proxy.com 等国内加速
#    - 这里统一把 GitHub 直连排第一并给它最多重试机会（5 次 x 600s 总超时），
#      同时保留国内代理作为兜底；另外加 --speed-time 30 --speed-limit 1024，
#      30 秒内速度 <1KB/s 就放弃当前尝试避免死等
tmpdir="$(mktemp -d)"
tarball="syncthing-linux-${arch}-${latest_tag}.tar.gz"
gh_url="https://github.com/syncthing/syncthing/releases/download/${latest_tag}/${tarball}"

candidates=(
    "https://github.com/syncthing/syncthing/releases/download/${latest_tag}/${tarball}|github-direct|5"
    "https://ghfast.top/${gh_url}|ghfast.top|3"
    "https://gh-proxy.com/${gh_url}|gh-proxy.com|3"
    "https://ghproxy.link/${gh_url}|ghproxy.link|3"
    "https://mirror.ghproxy.com/${gh_url}|mirror.ghproxy.com|3"
    "https://gh.ddlc.top/${gh_url}|gh.ddlc.top|3"
)

download_ok=0
for item in "${candidates[@]}"; do
    # 解析 URL|label|retries 三元组
    try_url="$(echo "$item" | cut -d'|' -f1)"
    label="$(echo "$item" | cut -d'|' -f2)"
    retries="$(echo "$item" | cut -d'|' -f3)"
    echo "---- 尝试 [$label] (retries=$retries): $try_url ----"
    # -4: 强制 IPv4（很多海外 VPS 的 IPv6 配置有问题会卡住）
    # --connect-timeout 15: TCP 握手 15s 超时
    # --max-time 600: 单次下载总时长上限 10 分钟
    # --retry N --retry-delay 3 --retry-all-errors: 瞬时错误重试
    # --speed-time 30 --speed-limit 1024: 30s 内速度 <1KB/s 就放弃
    if curl -fL -4 \
            --connect-timeout 15 --max-time 600 \
            --retry "$retries" --retry-delay 3 --retry-all-errors \
            --speed-time 30 --speed-limit 1024 \
            -o "$tmpdir/$tarball" "$try_url" 2>&1 | tail -5; then
        if gzip -t "$tmpdir/$tarball" 2>/dev/null; then
            actual_size=$(stat -c%s "$tmpdir/$tarball" 2>/dev/null || wc -c <"$tmpdir/$tarball")
            echo "[$label] 下载成功，文件大小：$actual_size 字节"
            download_ok=1
            break
        else
            got_size=$(stat -c%s "$tmpdir/$tarball" 2>/dev/null || wc -c <"$tmpdir/$tarball")
            head_bytes=$(head -c 200 "$tmpdir/$tarball" 2>/dev/null | tr -d '\0' | head -c 120)
            echo "[$label] 文件已下载（$got_size 字节）但不是有效的 gz 归档（代理可能返回了错误页）"
            echo "    内容开头：$head_bytes"
            rm -f "$tmpdir/$tarball"
        fi
    else
        curl_rc=$?
        echo "[$label] 下载失败（curl rc=$curl_rc）"
        rm -f "$tmpdir/$tarball" 2>/dev/null || true
    fi
done

if [ "$download_ok" != "1" ]; then
    rm -rf "$tmpdir"
    echo "ERROR: 所有下载源均失败，请检查服务器出站网络" >&2
    echo "可手动执行以下命令看服务器到 GitHub 的连通情况：" >&2
    echo "  curl -v --connect-timeout 10 -o /dev/null https://github.com" >&2
    echo "  curl -v --connect-timeout 10 -o /dev/null $gh_url" >&2
    exit 1
fi

# 6) 解压 + 安装
cd "$tmpdir"
tar xzf "$tarball"
extracted_dir="$(find . -maxdepth 1 -type d -name 'syncthing-linux-*' | head -1)"
if [ -z "$extracted_dir" ] || [ ! -x "$extracted_dir/syncthing" ]; then
    echo "ERROR: 解压后未找到 syncthing 二进制" >&2
    rm -rf "$tmpdir"
    exit 1
fi
$sudo_cmd install -m 0755 "$extracted_dir/syncthing" /usr/local/bin/syncthing
[ -e /usr/bin/syncthing ] || $sudo_cmd ln -sf /usr/local/bin/syncthing /usr/bin/syncthing
cd /
rm -rf "$tmpdir"

# 7) systemd unit —— 关键：WorkingDirectory=/data/obsidian
# 为什么需要？
#   Syncthing v2 某些版本在 POST/PATCH folder 时会把请求 body 里的绝对 path 错误地
#   存成相对路径（bug），之后 syncthing 进程读 config.xml 时会按 **进程 cwd** 解析
#   相对路径。若 unit 不指定 WorkingDirectory，systemd 默认 cwd = "/"，于是数据会
#   被同步到 "/xxx" 而非期望的 "/data/obsidian/xxx"。
#   这里强制 WorkingDirectory=/data/obsidian，使相对路径 "xxx" 仍落在正确前缀下。
UNIT_FILE="/etc/systemd/system/syncthing@.service"
NEED_WRITE_UNIT=1
if [ -f "$UNIT_FILE" ]; then
    if grep -q "^WorkingDirectory=/data/obsidian" "$UNIT_FILE" 2>/dev/null; then
        NEED_WRITE_UNIT=0
    fi
fi
if [ "$NEED_WRITE_UNIT" = "1" ]; then
    echo "写入/更新 $UNIT_FILE（确保 WorkingDirectory 正确）"
    $sudo_cmd mkdir -p /data/obsidian
    $sudo_cmd tee "$UNIT_FILE" >/dev/null <<'UNIT'
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization for %I
Documentation=man:syncthing(1)
After=network.target

[Service]
User=%i
WorkingDirectory=/data/obsidian
ExecStart=/usr/local/bin/syncthing serve --no-browser --no-restart --logflags=0
Restart=on-failure
RestartSec=5
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

ProtectSystem=full
PrivateTmp=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
    $sudo_cmd systemctl daemon-reload
    # 如果服务正在运行，重启以应用新的 WorkingDirectory
    if $sudo_cmd systemctl is-active syncthing@*.service >/dev/null 2>&1; then
        for u in $($sudo_cmd systemctl list-units --type=service --state=active --no-legend 'syncthing@*' 2>/dev/null | awk '{print $1}'); do
            [ -n "$u" ] && $sudo_cmd systemctl restart "$u" || true
        done
    fi
fi

echo "INSTALLED: $(syncthing --version 2>&1 | head -1)"
'@
    $r = Invoke-SSHScript -Script $script
    # 输出转向终端，便于诊断
    $r.Output -split "`r?`n" | ForEach-Object {
        if ($_ -match "^\s*$") { return }
        Write-Host "   ↳ $_" -ForegroundColor DarkGray
    }
    if (-not $r.Success) {
        throw "Syncthing 安装失败（GitHub 二进制安装流程出错，请查上方日志）"
    }
    Write-Ok "Syncthing 安装完成（v2.x GitHub 二进制）"
}

# ---- 2.3 初始化远端配置（首次启动生成 config.xml） ----
function Initialize-RemoteSyncthingConfig {
    Write-Info "初始化 Syncthing 配置（首次启动以生成 config.xml）..."
    $scriptTemplate = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
RUN_USER="__RUN_USER__"
RUN_HOME="__RUN_HOME__"

as_user() {
    if [ "$(whoami)" = "$RUN_USER" ]; then
        env HOME="$RUN_HOME" "$@"
    else
        $sudo_cmd -u "$RUN_USER" env HOME="$RUN_HOME" "$@"
    fi
}

CFG_PATH="$(as_user syncthing paths 2>/dev/null | awk '/^Configuration file:/ {getline; gsub(/^[ \t]+/, "", $0); print; exit}')"
if [ -z "$CFG_PATH" ]; then
    CFG_PATH="$(as_user syncthing --paths 2>/dev/null | awk '/^Configuration file:/ {getline; gsub(/^[ \t]+/, "", $0); print; exit}')"
fi
if [ -z "$CFG_PATH" ]; then
    if [ -d "$RUN_HOME/.local/state/syncthing" ]; then
        CFG_PATH="$RUN_HOME/.local/state/syncthing/config.xml"
    else
        CFG_PATH="$RUN_HOME/.config/syncthing/config.xml"
    fi
fi
CFG_DIR="$(dirname "$CFG_PATH")"
echo "DETECTED_CFG_PATH=$CFG_PATH"

if [ -f "$CFG_PATH" ]; then
    echo "CONFIG_READY=1 (existing)"
    exit 0
fi

mkdir -p "$CFG_DIR"
[ "$(whoami)" = "$RUN_USER" ] || $sudo_cmd chown -R "$RUN_USER":"$RUN_USER" "$CFG_DIR" 2>/dev/null || true

gen_out="$(as_user syncthing generate --home="$CFG_DIR" 2>&1)" && gen_rc=0 || gen_rc=$?
echo "---- generate(v2 --home) rc=$gen_rc ----"
echo "$gen_out" | tail -10

if [ ! -f "$CFG_PATH" ]; then
    gen_out2="$(as_user syncthing generate --home="$CFG_DIR" --no-default-folder 2>&1)" || true
    echo "---- generate(v1.20-1.29 --home + --no-default-folder) ----"
    echo "$gen_out2" | tail -10
fi

if [ ! -f "$CFG_PATH" ]; then
    gen_out3="$(as_user syncthing generate --no-default-folder 2>&1)" || true
    echo "---- generate(legacy subcommand) ----"
    echo "$gen_out3" | tail -10
fi

if [ ! -f "$CFG_PATH" ]; then
    gen_out4="$(as_user syncthing -generate="$CFG_DIR" -no-default-folder 2>&1)" || true
    echo "---- generate(very-old flag) ----"
    echo "$gen_out4" | tail -10
fi

if [ ! -f "$CFG_PATH" ]; then
    echo "---- fallback: foreground bootstrap ----"
    tmplog="$(mktemp)"
    as_user syncthing serve --home="$CFG_DIR" --no-browser >"$tmplog" 2>&1 &
    pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        as_user syncthing serve --no-browser --no-default-folder >"$tmplog" 2>&1 &
        pid=$!
        sleep 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        as_user syncthing -no-browser -no-default-folder >"$tmplog" 2>&1 &
        pid=$!
    fi
    for i in $(seq 1 30); do
        [ -f "$CFG_PATH" ] && break
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tail -15 "$tmplog" 2>/dev/null
    rm -f "$tmplog"
fi

if [ -f "$CFG_PATH" ]; then
    echo "CONFIG_READY=1"
else
    echo "CONFIG_READY=0"
    ls -la "$CFG_DIR" 2>&1
fi
'@
    $script = $scriptTemplate.Replace("__RUN_USER__", $global:REMOTE_RUN_USER).Replace("__RUN_HOME__", $global:REMOTE_HOME)
    $r = Invoke-SSHScript -Script $script
    
    if ($r.Output -notmatch "CONFIG_READY=1") {
        Write-Host "──── 服务器端初始化输出 ────" -ForegroundColor Yellow
        Write-Host $r.Output -ForegroundColor DarkGray
        Write-Host "──────────────────────────────────" -ForegroundColor Yellow
        throw "Syncthing 配置初始化失败，详见上方服务器输出"
    }
    
    $detected = Get-KVValue -Text $r.Output -Key "DETECTED_CFG_PATH"
    if ($detected) {
        $global:REMOTE_CONFIG_XML = $detected
        $global:REMOTE_CONFIG_DIR = Split-Path -Parent $detected
    }
    Write-Ok "Syncthing 配置已生成：$($global:REMOTE_CONFIG_XML)"
}

# ---- 2.4 创建同步根目录 ----
function New-RemoteSyncDir {
    Write-Info "准备同步根目录 $DEFAULT_REMOTE_ROOT..."
    $scriptTemplate = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
$sudo_cmd mkdir -p "__ROOT__"
$sudo_cmd chown -R "__RUN_USER__":"__RUN_USER__" "__ROOT__" || true
ls -ld "__ROOT__"
'@
    $script = $scriptTemplate.Replace("__ROOT__", $DEFAULT_REMOTE_ROOT).Replace("__RUN_USER__", $global:REMOTE_RUN_USER)
    $r = Invoke-SSHScript -Script $script
    $r.Output -split "`r?`n" | Where-Object { $_ -match "\S" } | ForEach-Object {
        Write-Host "   ↳ $_" -ForegroundColor DarkGray
    }
    if (-not $r.Success) {
        throw "创建同步目录 $DEFAULT_REMOTE_ROOT 失败"
    }
    Write-Ok "同步目录已就绪"
}

# ---- 2.5 注册 systemd 服务并启动 ----
function Enable-RemoteSyncthingService {
    Write-Info "配置 systemd 服务并启动..."
    $scriptTemplate = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
RUN_USER="__RUN_USER__"
$sudo_cmd systemctl daemon-reload || true
$sudo_cmd systemctl enable "syncthing@${RUN_USER}.service" >/dev/null 2>&1 || true
$sudo_cmd systemctl restart "syncthing@${RUN_USER}.service"
sleep 2
$sudo_cmd systemctl is-active "syncthing@${RUN_USER}.service"
'@
    $script = $scriptTemplate.Replace("__RUN_USER__", $global:REMOTE_RUN_USER)
    $r = Invoke-SSHScript -Script $script
    $lastLine = ($r.Output -split "`r?`n" | Where-Object { $_ -match "\S" } | Select-Object -Last 1)
    if ($lastLine -match "^active$") {
        Write-Ok "syncthing@$($global:REMOTE_RUN_USER).service 已启动并设置开机自启"
    } else {
        Write-Host $r.Output -ForegroundColor DarkGray
        throw "systemd 服务启动失败"
    }
}

# ---- 2.6 开放防火墙端口 ----
function Open-RemoteFirewall {
    Write-Info "尝试放通防火墙端口（22000/tcp, 22000/udp, 21027/udp）..."
    $script = @'
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
if command -v ufw >/dev/null 2>&1 && $sudo_cmd ufw status 2>/dev/null | grep -q "Status: active"; then
    $sudo_cmd ufw allow 22000/tcp >/dev/null 2>&1 || true
    $sudo_cmd ufw allow 22000/udp >/dev/null 2>&1 || true
    $sudo_cmd ufw allow 21027/udp >/dev/null 2>&1 || true
    echo "FIREWALL=ufw"
elif command -v firewall-cmd >/dev/null 2>&1 && $sudo_cmd firewall-cmd --state 2>/dev/null | grep -q running; then
    $sudo_cmd firewall-cmd --permanent --add-port=22000/tcp >/dev/null 2>&1 || true
    $sudo_cmd firewall-cmd --permanent --add-port=22000/udp >/dev/null 2>&1 || true
    $sudo_cmd firewall-cmd --permanent --add-port=21027/udp >/dev/null 2>&1 || true
    $sudo_cmd firewall-cmd --reload >/dev/null 2>&1 || true
    echo "FIREWALL=firewalld"
else
    echo "FIREWALL=none"
fi
'@
    $r = Invoke-SSHScript -Script $script
    switch -Regex ($r.Output) {
        "FIREWALL=ufw"       { Write-Ok "已通过 ufw 放通端口"; break }
        "FIREWALL=firewalld" { Write-Ok "已通过 firewalld 放通端口"; break }
        default              { Write-Warn "未检测到活动防火墙；请自行确认云厂商安全组已放通 22000、21027 端口" }
    }
}

# ---- 2.7 读取远端 Device ID 与 API Key ----
function Read-RemoteIdentity {
    Write-Info "读取服务器 Device ID 与 API Key..."
    $scriptTemplate = @'
set -e
CFG="__CFG__"
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
DID=$($sudo_cmd grep -oE '<device id="[A-Z0-9-]+"' "$CFG" | head -1 | sed -E 's/.*id="([A-Z0-9-]+)".*/\1/')
AKEY=$($sudo_cmd grep -oE '<apikey>[^<]+</apikey>' "$CFG" | sed -E 's/<\/?apikey>//g')
printf "DEVICE_ID=%s\n" "$DID"
printf "API_KEY=%s\n"   "$AKEY"
'@
    $script = $scriptTemplate.Replace("__CFG__", $global:REMOTE_CONFIG_XML)
    $r = Invoke-SSHScript -Script $script -ThrowOnError
    $global:REMOTE_DEVICE_ID = Get-KVValue -Text $r.Output -Key "DEVICE_ID"
    $global:REMOTE_API_KEY   = Get-KVValue -Text $r.Output -Key "API_KEY"
    if ([string]::IsNullOrEmpty($global:REMOTE_DEVICE_ID) -or [string]::IsNullOrEmpty($global:REMOTE_API_KEY)) {
        throw "无法解析服务器 config.xml 中的 Device ID / API Key"
    }
    $didMasked = "$($global:REMOTE_DEVICE_ID.Substring(0, [Math]::Min(14, $global:REMOTE_DEVICE_ID.Length)))...$($global:REMOTE_DEVICE_ID.Substring([Math]::Max(0, $global:REMOTE_DEVICE_ID.Length - 7)))"
    Write-Ok "服务器 Device ID：$didMasked"
}

# ---- 2.8 步骤 2 主入口 ----
function Deploy-RemoteSyncthing {
    Write-Step "步骤 2/8：服务器端 Syncthing 部署"
    
    # 探测环境
    Write-Info "探测服务器环境..."
    $envOut = Get-RemoteEnv
    $osId      = Get-KVValue -Text $envOut -Key "OS_ID"
    $pkgMgr    = Get-KVValue -Text $envOut -Key "PKG_MGR"
    $installed = Get-KVValue -Text $envOut -Key "SYNCTHING_INSTALLED"
    $syncVer   = Get-KVValue -Text $envOut -Key "SYNCTHING_VERSION"
    $whoamiOut = Get-KVValue -Text $envOut -Key "WHOAMI"
    $remoteHome= Get-KVValue -Text $envOut -Key "HOME"
    $hasSd     = Get-KVValue -Text $envOut -Key "HAS_SYSTEMD"
    
    $global:REMOTE_RUN_USER   = $whoamiOut
    $global:REMOTE_HOME       = $remoteHome
    $global:REMOTE_CONFIG_DIR = "$remoteHome/.config/syncthing"
    $global:REMOTE_CONFIG_XML = "$($global:REMOTE_CONFIG_DIR)/config.xml"
    
    Write-Info "OS=$osId  包管理器=$pkgMgr  运行用户=$($global:REMOTE_RUN_USER)  systemd=$hasSd"
    
    if ($hasSd -ne "1") {
        throw "服务器未安装 systemd，目前脚本仅支持基于 systemd 的发行版"
    }
    
    # 版本策略：强制 v2.x
    $needInstall = $false
    if ($installed -ne "1") {
        $needInstall = $true
    } else {
        $verNum = $syncVer
        if ($verNum) { $verNum = $verNum -replace "^v", "" }
        $majorStr = ($verNum -split "\.")[0]
        $majorInt = 0
        [void][int]::TryParse($majorStr, [ref]$majorInt)
        if ($majorInt -lt 2) {
            Write-Warn "服务器已安装 Syncthing $syncVer，但版本过旧（需要 v2.x 以兼容本地客户端），将强制升级"
            $needInstall = $true
        } else {
            Write-Ok "Syncthing 已安装（版本：$syncVer），跳过安装步骤（幂等）"
        }
    }
    
    if ($needInstall) {
        Install-RemoteSyncthing
    }
    
    Initialize-RemoteSyncthingConfig
    New-RemoteSyncDir
    Enable-RemoteSyncthingService
    Open-RemoteFirewall
    Read-RemoteIdentity
}

# ---------------------------------------------------------------------------
# 模块：syncthing_api —— REST 调用封装（步骤 3 及以后共用）
# 设计说明：
#   - sh 版统一用 curl，Windows 我们用 PowerShell 原生 Invoke-WebRequest，
#     无需额外依赖 jq/curl
#   - 支持 HTTPS 自签证书（Syncthing 默认自签；用反射设置
#     ServerCertificateValidationCallback，兼容 PS 5.1/7）
#   - 内置 3 次重试（对应 sh 版 http_call 的 retry 逻辑）
#   - Body 直接收 [string] JSON，不走临时文件（PS Invoke-WebRequest 原生支持）
# ---------------------------------------------------------------------------

# 首次调用时一次性忽略自签证书（Syncthing 启用 TLS 时走 https://127.0.0.1:18384）
function Disable-CertificateValidation {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy {
    public static bool Validate(object s, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [TrustAllCertsPolicy]::Validate
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
}

# Invoke-SyncthingApi：REST 底层封装（等价 sh 版 http_call）
# 参数：
#   -Method  GET/POST/PUT/DELETE/PATCH
#   -Url     完整 URL（含 http:// 或 https://）
#   -ApiKey  X-API-Key 头的值（可选，健康检查可不传）
#   -Body    JSON 字符串（可选，POST/PUT 用）
#   -Retries 重试次数，默认 3
#   -TimeoutSec 单次请求超时，默认 10
# 返回：PSObject（JSON 反序列化后的对象）或原始字符串（若非 JSON）
function Invoke-SyncthingApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$ApiKey,
        [string]$Body,
        [int]$Retries = 3,
        [int]$TimeoutSec = 10
    )
    Disable-CertificateValidation
    
    # 强制绕过系统代理（关键修复）：
    # Windows 用户常开着 Clash / v2rayN / Shadowsocks 的"系统代理"，
    # 或设置了 HTTP_PROXY/HTTPS_PROXY 环境变量，会把 127.0.0.1 loopback
    # 流量也送到代理，导致长时间无响应。这里做三重兜底：
    #   1) 清空 WebRequest.DefaultWebProxy（PS 5.1 / .NET Framework 生效）
    #   2) 清空 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 进程级环境变量（对 PS 7/.NET Core 生效）
    #   3) 调用时 PS 7 用 -NoProxy，PS 5.1 用 -Proxy '' + ProxyUseDefaultCredentials=$false
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
    foreach ($ev in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy') {
        if (Test-Path "Env:$ev") { Remove-Item "Env:$ev" -ErrorAction SilentlyContinue }
    }
    
    # 检测是否在 PowerShell 7+（PSEdition=Core），以使用对应的参数
    $isPS7 = $PSVersionTable.PSEdition -eq 'Core'
    
    $headers = @{}
    if ($ApiKey) { $headers["X-API-Key"] = $ApiKey }
    
    $attempt = 0
    $lastErr = $null
    while ($attempt -lt $Retries) {
        $attempt++
        try {
            $params = @{
                Method       = $Method
                Uri          = $Url
                Headers      = $headers
                TimeoutSec   = $TimeoutSec
                UseBasicParsing = $true
                ErrorAction  = 'Stop'
            }
            if ($isPS7) {
                # PS 7+ 原生支持 -NoProxy，直接绕过所有代理
                $params.NoProxy = $true
            } else {
                # PS 5.1：用空字符串 + 禁用默认凭据
                $params.Proxy = ''
                $params.ProxyUseDefaultCredentials = $false
            }
            if ($Body) {
                $params.ContentType = "application/json"
                $params.Body        = $Body
            }
            $response = Invoke-WebRequest @params
            $content = $response.Content
            # 尝试解析 JSON，失败则返回原文
            try {
                return $content | ConvertFrom-Json -ErrorAction Stop
            } catch {
                return $content
            }
        } catch {
            $lastErr = $_.Exception.Message
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds 1
            }
        }
    }
    throw "HTTP $Method $Url 失败（重试 $Retries 次）: $lastErr"
}

# 远端 API 调用（经 SSH 隧道，走 127.0.0.1:18384）
function Invoke-RemoteApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Body,
        [int]$Retries = 3
    )
    if ([string]::IsNullOrEmpty($global:REMOTE_API_KEY)) {
        throw "REMOTE_API_KEY 为空，请先完成步骤 2 的 Read-RemoteIdentity"
    }
    Invoke-SyncthingApi -Method $Method -Url "$REMOTE_API_URL$Path" -ApiKey $global:REMOTE_API_KEY -Body $Body -Retries $Retries
}

# 本地 API 调用（本机 syncthing，127.0.0.1:8384）
function Invoke-LocalApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Body,
        [int]$Retries = 3
    )
    if ([string]::IsNullOrEmpty($global:LOCAL_API_KEY)) {
        throw "LOCAL_API_KEY 为空，请先完成步骤 4 的本地 Syncthing 安装"
    }
    Invoke-SyncthingApi -Method $Method -Url "$LOCAL_API_URL$Path" -ApiKey $global:LOCAL_API_KEY -Body $Body -Retries $Retries
}

# 生成安全随机字符串（字母+数字，长度 N）
function New-RandomString {
    param([int]$Length = 20)
    $chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    # 用 System.Security.Cryptography.RandomNumberGenerator 保证密码强度
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        [void]$sb.Append($chars[$b % $chars.Length])
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# 模块：remote-tunnel —— 远端 API 通道与 GUI 凭证（步骤 3/8）
# ---------------------------------------------------------------------------

# 建立 SSH 端口转发：127.0.0.1:$REMOTE_API_LOCAL_PORT -> 远端 127.0.0.1:8384
function New-SSHTunnel {
    Write-Info "建立 SSH 端口转发 127.0.0.1:$REMOTE_API_LOCAL_PORT -> 远端 :8384 ..."
    
    # 1) 端口占用则先清理
    $occupied = $false
    try {
        $null = Get-NetTCPConnection -LocalPort $REMOTE_API_LOCAL_PORT -State Listen -ErrorAction Stop
        $occupied = $true
    } catch { }
    
    if ($occupied) {
        Write-Warn "本地端口 $REMOTE_API_LOCAL_PORT 已占用；尝试结束旧隧道..."
        # 尝试 kill 已记录的旧隧道 Process
        if ($global:SSH_TUNNEL_PROCESS -and -not $global:SSH_TUNNEL_PROCESS.HasExited) {
            try { $global:SSH_TUNNEL_PROCESS.Kill() } catch { }
        }
        # 再按命令行特征兜底清理：plink 进程 + 含 "-L 18384:" 参数
        Get-CimInstance Win32_Process -Filter "Name='plink.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -match "-L\s+$REMOTE_API_LOCAL_PORT`:127\.0\.0\.1:8384"
        } | ForEach-Object {
            Write-Hint "杀掉残留 plink PID=$($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
    
    # 2) 启动新隧道（plink -N -L 本地端口:远端地址）
    #    -N: 不执行远端命令（纯转发）
    #    -ssh -batch: 非交互、已预接收 host key
    #    -pw: 直接传密码（ps1 里 plink 已经验证过这条路能工作）
    $plinkPath = Get-PlinkPath
    if (-not $plinkPath) { throw "未找到 plink.exe" }
    
    $plinkArgs = @(
        "-ssh", "-batch", "-N",
        "-P", $global:SSH_PORT,
        "-l", $global:SSH_USER,
        "-pw", $global:SSH_PASS,
        "-L", "$($REMOTE_API_LOCAL_PORT):127.0.0.1:8384",
        $global:SSH_HOST
    )
    
    $proc = Start-Process -FilePath $plinkPath -ArgumentList $plinkArgs `
                          -WindowStyle Hidden -PassThru `
                          -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) `
                          -RedirectStandardError  ([System.IO.Path]::GetTempFileName())
    $global:SSH_TUNNEL_PROCESS = $proc
    
    # 3) 等待端口实际监听（最多 10 秒）
    $waited = 0
    $listening = $false
    while ($waited -lt 10) {
        Start-Sleep -Milliseconds 500
        $waited += 1
        try {
            $null = Get-NetTCPConnection -LocalPort $REMOTE_API_LOCAL_PORT -State Listen -ErrorAction Stop
            $listening = $true
            break
        } catch { }
        # 进程提前挂掉则直接失败
        if ($proc.HasExited) {
            throw "plink 隧道进程提前退出（ExitCode=$($proc.ExitCode)），请检查 SSH 连通性"
        }
    }
    
    if (-not $listening) {
        try { $proc.Kill() } catch { }
        throw "SSH 隧道建立失败：10 秒内端口 $REMOTE_API_LOCAL_PORT 未进入监听状态"
    }
    
    Write-Ok "SSH 隧道建立成功（plink PID=$($proc.Id)）"
    
    # 4) 先把默认 HTTP URL 同步到 global 作用域（关键修复）
    #    Wait-RemoteApiReady / Invoke-RemoteApi 都通过 $global:REMOTE_API_URL 读取，
    #    必须无条件初始化一次；TLS 分支再按需覆盖为 https。
    $global:REMOTE_API_URL = "http://127.0.0.1:$REMOTE_API_LOCAL_PORT"
    
    # 5) 探测远端 GUI 是否启用 TLS（影响 http/https 协议）
    $tlsScriptTemplate = @'
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
if $sudo_cmd grep -qE '<gui[^>]+tls="true"' "__CFG__" 2>/dev/null; then
    echo "TLS=1"
else
    echo "TLS=0"
fi
'@
    $tlsScript = $tlsScriptTemplate.Replace("__CFG__", $global:REMOTE_CONFIG_XML)
    $tlsOut = (Invoke-SSHScript -Script $tlsScript).Output
    if ($tlsOut -match "TLS=1") {
        $global:REMOTE_API_URL = "https://127.0.0.1:$REMOTE_API_LOCAL_PORT"
        # 覆盖脚本级变量（给 Invoke-RemoteApi 用）
        Set-Variable -Name REMOTE_API_URL -Value $global:REMOTE_API_URL -Scope Script
        Write-Info "检测到远端 GUI 启用了 TLS，切换为 HTTPS 访问"
    } else {
        # 非 TLS 也同步一次脚本级变量，保持一致
        Set-Variable -Name REMOTE_API_URL -Value $global:REMOTE_API_URL -Scope Script
    }
}

# 关闭 SSH 隧道（在退出或出错时调用）
function Stop-SSHTunnel {
    if ($global:SSH_TUNNEL_PROCESS) {
        try {
            if (-not $global:SSH_TUNNEL_PROCESS.HasExited) {
                $global:SSH_TUNNEL_PROCESS.Kill()
                Write-Info "已关闭 SSH 端口转发（PID=$($global:SSH_TUNNEL_PROCESS.Id)）"
            }
        } catch { }
        $global:SSH_TUNNEL_PROCESS = $null
    }
    # 兜底：按命令行特征清理任何残留
    Get-CimInstance Win32_Process -Filter "Name='plink.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -match "-L\s+$REMOTE_API_LOCAL_PORT`:127\.0\.0\.1:8384"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# 等待远端 API 响应 pong
function Wait-RemoteApiReady {
    Write-Info "验证远端 Syncthing API 可达..."
    
    # 0) 先在服务器端确认 syncthing 已监听 127.0.0.1:8384
    #    避免 plink 转发到一个不存在的服务导致客户端一直 connection refused
    $serverCheckScript = @'
if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:8384|\*:8384|:::8384'; then
    echo "LISTEN=1"
else
    echo "LISTEN=0"
    echo "--- syncthing 服务状态 ---"
    systemctl status syncthing@root --no-pager 2>&1 | head -20 || true
    echo "--- 最近 20 行日志 ---"
    journalctl -u syncthing@root -n 20 --no-pager 2>&1 || true
fi
'@
    $serverCheck = (Invoke-SSHScript -Script $serverCheckScript).Output
    if ($serverCheck -notmatch "LISTEN=1") {
        Write-Warn "远端 syncthing 尚未监听 8384 端口，服务器诊断信息："
        foreach ($line in ($serverCheck -split "`n")) {
            if ($line.Trim()) { Write-Hint $line }
        }
        Write-Info "等待 10 秒让 syncthing 初始化..."
        Start-Sleep -Seconds 10
    } else {
        Write-Hint "远端 8384 端口监听正常"
    }
    
    # 0.5) L4 TCP 探测：检查本地 18384 是否能真正 connect 到远端（绕开 HTTP 层）
    #      这一步可以立刻暴露"plink 建了监听但 SSH 握手还没完成"之类的问题
    $tcpReady = $false
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect("127.0.0.1", [int]$REMOTE_API_LOCAL_PORT, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1500)) {
                $tcp.EndConnect($async)
                $tcp.Close()
                $tcpReady = $true
                break
            } else {
                $tcp.Close()
            }
        } catch {
            # 忽略单次失败，继续重试
        }
        Start-Sleep -Milliseconds 500
    }
    if ($tcpReady) {
        Write-Hint "L4 隧道连通性正常（127.0.0.1:$REMOTE_API_LOCAL_PORT 可 connect）"
    } else {
        Write-Warn "L4 探测失败：连不通 127.0.0.1:$REMOTE_API_LOCAL_PORT（隧道可能未就绪）"
    }
    
    # 1) 开始轮询 API（60 秒）
    $waited = 0
    $maxWait = 60
    $lastErr = ""
    $firstErrPrinted = $false
    while ($waited -lt $maxWait) {
        try {
            $r = Invoke-SyncthingApi -Method GET -Url "$($global:REMOTE_API_URL)/rest/system/ping" -ApiKey $global:REMOTE_API_KEY -Retries 1 -TimeoutSec 3
            # ping 成功返回 {"ping":"pong"} 或包含 "pong" 字样
            $rStr = if ($r -is [string]) { $r } else { ($r | ConvertTo-Json -Compress) }
            if ($rStr -match "pong") {
                Write-Ok "远端 API 响应正常"
                return
            }
            $lastErr = "API 返回非 pong 响应：$rStr"
        } catch {
            $lastErr = $_.Exception.Message
            # 首次失败立刻打印一次，便于早期定位
            if (-not $firstErrPrinted) {
                Write-Hint "首次调用错误：$lastErr"
                $firstErrPrinted = $true
            }
            # 之后每 10 秒打印一次当前错误，避免用户盲等
            if (($waited % 10) -eq 0 -and $waited -gt 0) {
                Write-Hint "已等待 ${waited}s，最近一次错误：$lastErr"
            }
        }
        Start-Sleep -Seconds 1
        $waited++
    }
    
    # 失败时打印完整诊断信息 + 自动跑一次 curl.exe 对比
    Write-Warn "远端 API 在 $maxWait 秒内未能响应"
    Write-Hint "最后一次错误：$lastErr"
    Write-Hint "当前请求地址：$($global:REMOTE_API_URL)/rest/system/ping"
    Write-Hint "当前 API Key 长度：$($global:REMOTE_API_KEY.Length)"
    
    # 自动用 curl.exe 对比（curl 不走 PowerShell 的代理栈）
    $curlPath = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if ($curlPath) {
        Write-Hint "正在使用 curl.exe 对比测试..."
        try {
            $curlOut = & $curlPath -sS -m 5 -H "X-API-Key: $($global:REMOTE_API_KEY)" "$($global:REMOTE_API_URL)/rest/system/ping" 2>&1
            Write-Hint "curl.exe 返回：$curlOut"
            if ("$curlOut" -match "pong") {
                Write-Warn "curl.exe 能通，但 Invoke-WebRequest 不通 —— 大概率是系统代理（Clash/v2rayN 等）拦截了 127.0.0.1 流量"
                Write-Hint "  → 请关闭系统代理后重试，或在代理软件中把 127.0.0.1 / localhost 加入绕过列表"
            }
        } catch {
            Write-Hint "curl.exe 测试也失败：$($_.Exception.Message)"
        }
    }
    
    Write-Hint "诊断建议："
    Write-Hint "  1) 本地手动测试：curl.exe -v http://127.0.0.1:$REMOTE_API_LOCAL_PORT/rest/system/ping"
    Write-Hint "  2) 服务器直连测试：ssh $($global:SSH_USER)@$($global:SSH_HOST) `"curl -s -H 'X-API-Key: $($global:REMOTE_API_KEY)' http://127.0.0.1:8384/rest/system/ping`""
    Write-Hint "  3) 查看远端 GUI 绑定地址：ssh $($global:SSH_USER)@$($global:SSH_HOST) `"grep -E '<gui|<address' $($global:REMOTE_CONFIG_XML)`""
    throw "远端 API 在 $maxWait 秒内未能响应，请根据上方诊断信息排查"
}

# 通过 REST 更新远端 GUI 用户名/密码（Syncthing 会自动 bcrypt）
function Set-RemoteGuiCredentials {
    param(
        [Parameter(Mandatory=$true)][string]$User,
        [Parameter(Mandatory=$true)][string]$Password
    )
    Write-Info "配置服务器 GUI 访问凭证（用户名：$User）..."
    
    # 先取当前 gui 配置
    $gui = Invoke-RemoteApi -Method GET -Path "/rest/config/gui"
    if (-not $gui) { throw "无法获取远端 GUI 配置" }
    
    # 修改字段
    $gui | Add-Member -NotePropertyName user -NotePropertyValue $User -Force
    $gui | Add-Member -NotePropertyName password -NotePropertyValue $Password -Force
    $gui | Add-Member -NotePropertyName address -NotePropertyValue "127.0.0.1:8384" -Force
    
    $bodyJson = $gui | ConvertTo-Json -Depth 20 -Compress
    $null = Invoke-RemoteApi -Method PUT -Path "/rest/config/gui" -Body $bodyJson
    Write-Ok "远端 GUI 凭证已更新"
}

# 步骤 3 主入口
function Invoke-RemoteApiTunnelSetup {
    Write-Step "步骤 3/8：建立远端 API 通道与 GUI 凭证"
    
    New-SSHTunnel
    Wait-RemoteApiReady
    
    # 生成随机 GUI 凭证
    $guiUser = "obsidian_sync"
    $guiPass = New-RandomString -Length 20
    Set-RemoteGuiCredentials -User $guiUser -Password $guiPass
    
    $global:REMOTE_GUI_USER = $guiUser
    $global:REMOTE_GUI_PASS = $guiPass
    
    # 持久化 GUI 密码到 DPAPI 加密文件（只有同一 Windows 用户能读回来）
    # 目标命名：obsidian-sync-gui-<host>，避免和 SSH 凭据冲突
    $guiCredTarget = "obsidian-sync-gui-$($global:SSH_HOST)"
    $saved = Set-WindowsCredential -Target $guiCredTarget -Username $guiUser -Password $guiPass
    
    Write-Info "远端 GUI 凭证："
    Write-Hint "  URL      : http://$($global:SSH_HOST):8384"
    Write-Hint "  用户名   : $guiUser"
    Write-Hint "  密码     : $guiPass"
    if ($saved) {
        $credFile = Get-CredentialFilePath -Target $guiCredTarget
        Write-Hint "  ↳ 已加密保存到: $credFile"
        Write-Hint "  ↳ 想再次查看密码，运行：.\show-gui-password.ps1"
    }
    Write-Warn "该密码仅在本次会话明文展示一次，请妥善保存"
}

# ---------------------------------------------------------------------------
# 模块：local-syncthing —— 本地 Windows Syncthing 安装与启动（步骤 4/8）
#
# 设计说明：
#   - 目标版本与服务器端完全一致（$LOCAL_SYNCTHING_VERSION），保证协议兼容
#   - 下载走多镜像降级（和步骤 2 服务器端一样：github-direct → ghfast → ghproxy），
#     单次最长等待 60s，失败立即换下一个镜像
#   - 不走 Windows 服务（避免 ACL/SYSTEM 账户看不到用户目录的坑），
#     改用后台进程（Start-Process -WindowStyle Hidden），PID 写入 state 目录；
#     这样普通用户权限即可跑起来，后续用户可自行挂计划任务开机自启
#   - GUI 只绑 127.0.0.1:8384（本机访问），和服务器端一致
#   - 首次启动用 `-generate` 生成 config.xml，再启动常驻进程；
#     避免主进程启动瞬间 race 导致 config 不完整
# ---------------------------------------------------------------------------

# 判断本地 syncthing.exe 是否已就位并满足版本要求
function Test-LocalSyncthingInstalled {
    if (-not (Test-Path $LOCAL_SYNCTHING_EXE)) { return @{ Installed = $false; Version = "" } }
    try {
        $verOut = & $LOCAL_SYNCTHING_EXE --version 2>&1 | Select-Object -First 1
        # 输出形如：syncthing v2.0.16 "Hafnium Hornet" ...
        if ($verOut -match 'v(\d+)\.(\d+)\.(\d+)') {
            $full = "v$($Matches[1]).$($Matches[2]).$($Matches[3])"
            $major = [int]$Matches[1]
            return @{ Installed = $true; Version = $full; Major = $major }
        }
        return @{ Installed = $true; Version = "unknown"; Major = 0 }
    } catch {
        return @{ Installed = $false; Version = ""; Error = $_.Exception.Message }
    }
}

# 下载本地 syncthing zip（多镜像降级）
function Get-LocalSyncthingBinary {
    $ver = $LOCAL_SYNCTHING_VERSION
    $fileName = "syncthing-windows-amd64-$ver.zip"
    $tmpDir = Join-Path $env:TEMP "obsidian-sync-dl"
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $zipPath = Join-Path $tmpDir $fileName

    # 如果之前下载过，直接复用（zip 本身有校验，解压失败时再重下）
    if ((Test-Path $zipPath) -and ((Get-Item $zipPath).Length -gt 1MB)) {
        Write-Hint "已检测到本地缓存：$zipPath （$([Math]::Round((Get-Item $zipPath).Length/1MB, 2)) MB），直接复用"
        return $zipPath
    }

    $directUrl = "https://github.com/syncthing/syncthing/releases/download/$ver/$fileName"
    # 镜像顺序 & 最低速度阈值（单位 KB/s）：任何镜像在 15 秒窗口内平均速度低于阈值
    # 就立刻放弃并换下一个，避免像 ghfast 那样 8KB/s 拖 20 分钟的糟糕体验。
    $candidates = @(
        @{ Name = "github-direct"; Url = $directUrl;                       MinKBps = 100 },
        @{ Name = "ghproxy";       Url = "https://ghproxy.com/$directUrl";  MinKBps = 100 },
        @{ Name = "ghfast";        Url = "https://ghfast.top/$directUrl";   MinKBps = 100 }
    )

    foreach ($c in $candidates) {
        Write-Hint "---- 尝试 [$($c.Name)] : $($c.Url)（最低 $($c.MinKBps) KB/s，否则 15s 后放弃） ----"
        try {
            Invoke-DownloadWithProgress -Url $c.Url -OutFile $zipPath -TimeoutSec 60 `
                -Activity "下载 Syncthing $ver ($($c.Name))" `
                -MinSpeedKBps $c.MinKBps -StallWindowSec 15
            $size = (Get-Item $zipPath).Length
            if ($size -lt 1MB) {
                Write-Warn "[$($c.Name)] 下载文件过小（$size 字节），疑似错误页面，丢弃重试"
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Hint "[$($c.Name)] 下载成功：$zipPath（$([Math]::Round($size/1MB, 2)) MB）"
            return $zipPath
        } catch {
            Write-Warn "[$($c.Name)] 下载失败：$($_.Exception.Message)"
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
    }
    throw "所有下载源均失败，无法获取 Syncthing $ver Windows 安装包"
}

# 解压 syncthing.zip 到 $LOCAL_SYNCTHING_HOME
function Expand-LocalSyncthingBinary {
    param([Parameter(Mandatory=$true)][string]$ZipPath)

    if (-not (Test-Path $LOCAL_SYNCTHING_HOME)) {
        New-Item -ItemType Directory -Path $LOCAL_SYNCTHING_HOME -Force | Out-Null
    }

    $tmpExtract = Join-Path $env:TEMP "obsidian-sync-extract"
    if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null

    Write-Hint "正在解压：$ZipPath"
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $tmpExtract -Force
    } catch {
        throw "解压失败（zip 可能损坏）：$($_.Exception.Message)"
    }

    # 官方 zip 里是 syncthing-windows-amd64-vX.Y.Z/syncthing.exe 这样的子目录结构，兜底查找
    $found = Get-ChildItem -Path $tmpExtract -Recurse -Filter "syncthing.exe" | Select-Object -First 1
    if (-not $found) {
        throw "解压后未找到 syncthing.exe，zip 内容异常"
    }

    Copy-Item -Path $found.FullName -Destination $LOCAL_SYNCTHING_EXE -Force
    # 同目录下的 LICENSE / README 也拷过来（体积很小，方便溯源）
    foreach ($extra in @("LICENSE.txt", "README.txt", "AUTHORS.txt")) {
        $extraSrc = Join-Path $found.Directory.FullName $extra
        if (Test-Path $extraSrc) {
            Copy-Item -Path $extraSrc -Destination (Join-Path $LOCAL_SYNCTHING_HOME $extra) -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Syncthing 已解压到 $LOCAL_SYNCTHING_EXE"
}

# 生成本地 config.xml（首次）
function Initialize-LocalSyncthingConfig {
    if (Test-Path $LOCAL_SYNCTHING_CONFIG_XML) {
        Write-Ok "本地 Syncthing 配置已存在（幂等跳过生成）：$LOCAL_SYNCTHING_CONFIG_XML"
        return
    }
    if (-not (Test-Path $LOCAL_SYNCTHING_CONFIG_DIR)) {
        New-Item -ItemType Directory -Path $LOCAL_SYNCTHING_CONFIG_DIR -Force | Out-Null
    }

    # Syncthing 不同版本的 generate 语法差异巨大：
    #   v2.x (当前):       syncthing generate --home=DIR           （--no-default-folder 已移除）
    #   v1.20 ~ v1.29:     syncthing generate --home=DIR --no-default-folder
    #   v1.x 更老:         syncthing -generate=DIR
    # 所以依次尝试；每次单独运行 + 判断 config.xml 是否出现，避免输出串扰。
    Write-Info "首次运行 syncthing generate 以产生 config.xml..."
    $attempts = @(
        @{ Desc = "v2.x (generate --home=DIR)";           Args = @("generate", "--home=$LOCAL_SYNCTHING_CONFIG_DIR") },
        @{ Desc = "v1.20+ (generate --home --no-default)"; Args = @("generate", "--home=$LOCAL_SYNCTHING_CONFIG_DIR", "--no-default-folder") },
        @{ Desc = "legacy (-generate=DIR)";                Args = @("-generate=$LOCAL_SYNCTHING_CONFIG_DIR") }
    )
    $allOut = New-Object System.Text.StringBuilder
    foreach ($a in $attempts) {
        Write-Hint "尝试：$($a.Desc)"
        try {
            $out = & $LOCAL_SYNCTHING_EXE @($a.Args) 2>&1 | Out-String
            $rc = $LASTEXITCODE
            [void]$allOut.AppendLine("---- $($a.Desc) rc=$rc ----")
            [void]$allOut.AppendLine($out)
        } catch {
            [void]$allOut.AppendLine("---- $($a.Desc) threw: $($_.Exception.Message) ----")
        }
        if (Test-Path $LOCAL_SYNCTHING_CONFIG_XML) {
            Write-Ok "本地 config.xml 已生成（方式：$($a.Desc)）：$LOCAL_SYNCTHING_CONFIG_XML"
            return
        }
    }

    # 终极兜底：前台运行 syncthing 几秒钟让它自己初始化 config.xml 然后杀掉
    Write-Hint "generate 子命令均未奏效，回退到前台启动 bootstrap..."
    $bootstrapAttempts = @(
        @{ Desc = "v2.x (serve --home --no-browser)";  Args = @("serve", "--home=$LOCAL_SYNCTHING_CONFIG_DIR", "--no-browser") },
        @{ Desc = "v1.x (-home -no-browser)";          Args = @("-home=$LOCAL_SYNCTHING_CONFIG_DIR", "-no-browser") }
    )
    foreach ($b in $bootstrapAttempts) {
        if (Test-Path $LOCAL_SYNCTHING_CONFIG_XML) { break }
        Write-Hint "前台 bootstrap 尝试：$($b.Desc)"
        $tmpLog = Join-Path $env:TEMP "obsidian-sync-bootstrap.log"
        $proc = $null
        try {
            $proc = Start-Process -FilePath $LOCAL_SYNCTHING_EXE -ArgumentList $b.Args -WindowStyle Hidden `
                                  -RedirectStandardOutput $tmpLog `
                                  -RedirectStandardError  "$tmpLog.err" `
                                  -PassThru
        } catch {
            [void]$allOut.AppendLine("---- bootstrap($($b.Desc)) Start-Process 失败：$($_.Exception.Message) ----")
            continue
        }
        # 最多等 20 秒让它生成 config.xml
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-Path $LOCAL_SYNCTHING_CONFIG_XML) { break }
            if ($proc.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }
        # 停掉 bootstrap 进程（我们只想要它生成 config.xml，不想让它常驻）
        if (-not $proc.HasExited) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            try { Wait-Process -Id $proc.Id -Timeout 5 -ErrorAction SilentlyContinue } catch {}
        }
        if (Test-Path $tmpLog) {
            [void]$allOut.AppendLine("---- bootstrap($($b.Desc)) stdout tail ----")
            [void]$allOut.AppendLine((Get-Content $tmpLog -Tail 10 -ErrorAction SilentlyContinue) -join "`n")
        }
        if (Test-Path "$tmpLog.err") {
            [void]$allOut.AppendLine("---- bootstrap($($b.Desc)) stderr tail ----")
            [void]$allOut.AppendLine((Get-Content "$tmpLog.err" -Tail 10 -ErrorAction SilentlyContinue) -join "`n")
        }
        Remove-Item $tmpLog, "$tmpLog.err" -Force -ErrorAction SilentlyContinue
        if (Test-Path $LOCAL_SYNCTHING_CONFIG_XML) {
            Write-Ok "本地 config.xml 已生成（方式：前台 bootstrap - $($b.Desc)）：$LOCAL_SYNCTHING_CONFIG_XML"
            return
        }
    }

    Write-Hint "────── 所有尝试输出汇总 ──────"
    foreach ($ln in ($allOut.ToString() -split "`n")) {
        if ($ln.Trim()) { Write-Hint "  $($ln.TrimEnd())" }
    }
    Write-Hint "───────────────────────────────"
    throw "所有 generate 方式均失败，config.xml 仍未生成。请把上方诊断信息反馈给开发者。"
}

# 强制把 GUI 改到 127.0.0.1:8384 + tls=false（方便本机 HTTP 调 API）
function Update-LocalSyncthingConfigGui {
    if (-not (Test-Path $LOCAL_SYNCTHING_CONFIG_XML)) {
        throw "config.xml 不存在，无法修改 GUI 绑定"
    }
    try {
        [xml]$cfg = Get-Content -Path $LOCAL_SYNCTHING_CONFIG_XML -Raw -Encoding UTF8
    } catch {
        throw "解析 config.xml 失败：$($_.Exception.Message)"
    }
    $gui = $cfg.configuration.gui
    if (-not $gui) { throw "config.xml 中找不到 <gui> 节点" }
    $changed = $false
    if ($gui.address -ne "127.0.0.1:8384") { $gui.address = "127.0.0.1:8384"; $changed = $true }
    # 强制关 TLS：Syncthing 默认自签证书，http 通信更简单
    if ($gui.tls -ne "false") { $gui.tls = "false"; $changed = $true }
    if ($changed) {
        $cfg.Save($LOCAL_SYNCTHING_CONFIG_XML)
        Write-Hint "已将本地 GUI 绑定固定为 127.0.0.1:8384（tls=false）"
    } else {
        Write-Hint "本地 GUI 配置已符合要求（127.0.0.1:8384, tls=false）"
    }
}

# 检查 8384 端口是否被非 syncthing 进程占用
function Test-LocalPort8384 {
    try {
        $conns = Get-NetTCPConnection -LocalPort 8384 -State Listen -ErrorAction SilentlyContinue
    } catch { $conns = $null }
    if (-not $conns) { return @{ Occupied = $false } }
    $proc = $null
    try { $proc = Get-Process -Id $conns[0].OwningProcess -ErrorAction SilentlyContinue } catch {}
    return @{ Occupied = $true; ProcessName = $proc.ProcessName; Pid = $conns[0].OwningProcess }
}

# 启动本地 Syncthing 后台进程
function Start-LocalSyncthingProcess {
    # 如果 PID 文件存在且进程还活着，幂等返回
    if (Test-Path $LOCAL_SYNCTHING_PID_FILE) {
        $oldPid = Get-Content $LOCAL_SYNCTHING_PID_FILE -Raw -ErrorAction SilentlyContinue
        if ($oldPid -match '^\d+$') {
            $p = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'syncthing') {
                Write-Ok "本地 Syncthing 已在运行（PID=$oldPid），幂等跳过启动"
                $global:LOCAL_SYNCTHING_PROCESS = $p
                return
            }
        }
    }

    # 端口冲突检查
    $portInfo = Test-LocalPort8384
    if ($portInfo.Occupied) {
        if ($portInfo.ProcessName -match 'syncthing') {
            Write-Ok "已有本地 syncthing 进程占用 8384（PID=$($portInfo.Pid)），直接沿用"
            $global:LOCAL_SYNCTHING_PROCESS = Get-Process -Id $portInfo.Pid -ErrorAction SilentlyContinue
            Set-Content -Path $LOCAL_SYNCTHING_PID_FILE -Value "$($portInfo.Pid)" -Encoding ASCII -NoNewline
            return
        } else {
            throw "本地 8384 端口已被非 syncthing 进程占用（$($portInfo.ProcessName), PID=$($portInfo.Pid)），请先释放该端口再重试"
        }
    }

    Write-Info "启动本地 Syncthing 后台进程..."
    # 关键参数：
    #   serve          - 2.x 子命令，常驻运行（1.x 无此子命令，直接起主进程）
    #   --home         - 配置目录，与 generate 一致
    #   --no-browser   - 不自动弹出浏览器
    #   --no-restart   - 不自 fork 重启，便于我们管理 PID
    $args2x = @("serve", "--home=$LOCAL_SYNCTHING_CONFIG_DIR", "--no-browser", "--no-restart")
    $proc = $null
    try {
        $proc = Start-Process -FilePath $LOCAL_SYNCTHING_EXE -ArgumentList $args2x -WindowStyle Hidden `
                              -RedirectStandardOutput $LOCAL_SYNCTHING_LOG `
                              -RedirectStandardError  "$LOCAL_SYNCTHING_LOG.err" `
                              -PassThru
    } catch {
        Write-Warn "2.x 风格启动失败，回退旧语法：$($_.Exception.Message)"
    }

    # 回退（1.x）: syncthing -home ... -no-browser -no-restart
    if (-not $proc -or $proc.HasExited) {
        $args1x = @("-home=$LOCAL_SYNCTHING_CONFIG_DIR", "-no-browser", "-no-restart")
        $proc = Start-Process -FilePath $LOCAL_SYNCTHING_EXE -ArgumentList $args1x -WindowStyle Hidden `
                              -RedirectStandardOutput $LOCAL_SYNCTHING_LOG `
                              -RedirectStandardError  "$LOCAL_SYNCTHING_LOG.err" `
                              -PassThru
    }

    if (-not $proc) { throw "无法启动本地 syncthing.exe" }
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) {
        $errTail = if (Test-Path "$LOCAL_SYNCTHING_LOG.err") {
            (Get-Content "$LOCAL_SYNCTHING_LOG.err" -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
        } else { "(无 stderr 日志)" }
        throw "本地 syncthing 启动后立即退出 (ExitCode=$($proc.ExitCode))，stderr 片段：`n$errTail"
    }

    Set-Content -Path $LOCAL_SYNCTHING_PID_FILE -Value "$($proc.Id)" -Encoding ASCII -NoNewline
    $global:LOCAL_SYNCTHING_PROCESS = $proc
    Write-Ok "本地 Syncthing 已启动（PID=$($proc.Id)），日志：$LOCAL_SYNCTHING_LOG"
}

# 等待本地 API 就绪（L4 + HTTP 双阶段，与 Wait-RemoteApiReady 同构）
function Wait-LocalApiReady {
    Write-Info "验证本地 Syncthing API 可达..."

    # L4 连通性
    $tcpReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect("127.0.0.1", 8384, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000)) {
                $tcp.EndConnect($async)
                $tcp.Close()
                $tcpReady = $true
                break
            } else {
                $tcp.Close()
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if ($tcpReady) {
        Write-Hint "L4 端口 127.0.0.1:8384 已监听"
    } else {
        Write-Warn "L4 探测未通过（127.0.0.1:8384 连不通），将继续 HTTP 轮询以获取更详细错误"
    }

    # HTTP ping 轮询（60 秒）
    $waited = 0
    $maxWait = 60
    $lastErr = ""
    while ($waited -lt $maxWait) {
        try {
            # 尚未读到 API Key 时先不带 key 试 /rest/noauth/health（2.x 新端点）
            # 若仍失败，再走 /rest/system/ping（需要 API Key）
            if ([string]::IsNullOrEmpty($global:LOCAL_API_KEY)) {
                $r = Invoke-SyncthingApi -Method GET -Url "$LOCAL_API_URL/rest/noauth/health" -Retries 1 -TimeoutSec 3
                $rStr = if ($r -is [string]) { $r } else { ($r | ConvertTo-Json -Compress) }
                if ($rStr -match '"status"\s*:\s*"OK"' -or $rStr -match 'OK') {
                    Write-Ok "本地 API 响应正常（/rest/noauth/health）"
                    return
                }
                $lastErr = "health 非 OK：$rStr"
            } else {
                $r = Invoke-SyncthingApi -Method GET -Url "$LOCAL_API_URL/rest/system/ping" -ApiKey $global:LOCAL_API_KEY -Retries 1 -TimeoutSec 3
                $rStr = if ($r -is [string]) { $r } else { ($r | ConvertTo-Json -Compress) }
                if ($rStr -match "pong") {
                    Write-Ok "本地 API 响应正常（/rest/system/ping）"
                    return
                }
                $lastErr = "ping 非 pong：$rStr"
            }
        } catch {
            $lastErr = $_.Exception.Message
            if (($waited % 10) -eq 0 -and $waited -gt 0) {
                Write-Hint "已等待 ${waited}s，最近一次错误：$lastErr"
            }
        }
        Start-Sleep -Seconds 1
        $waited++
    }

    # 失败时打印最后 30 行日志
    Write-Warn "本地 API 在 $maxWait 秒内未能响应，最后一次错误：$lastErr"
    if (Test-Path $LOCAL_SYNCTHING_LOG) {
        Write-Hint "本地 Syncthing 日志末尾 30 行："
        $tail = Get-Content $LOCAL_SYNCTHING_LOG -Tail 30 -ErrorAction SilentlyContinue
        foreach ($ln in $tail) { if ($ln.Trim()) { Write-Hint "  $ln" } }
    }
    throw "本地 Syncthing API 在 $maxWait 秒内未能响应"
}

# 从本地 config.xml 解析 Device ID 与 API Key
# 注意：此时 Syncthing API 可能还没就绪，所以不能调 REST；只能读 config.xml。
# 风险：config.xml 的 <device> 列表会把"本机自身"与"远端对端"混在一起，
#       新安装时第一个 <device> 就是 self，但幂等重跑（此前已经 Pair-Devices 过）
#       会导致列表里出现多个 <device>，"第一个"未必是 self。
# 解决：
#   1) 这里仍然尽力从 config.xml 猜一个 Device ID（仅作为 fallback，用于
#      Wait-LocalApiReady 之前的日志输出与 API Key 读取）。
#   2) 在 Wait-LocalApiReady 之后调用 Confirm-LocalDeviceIdViaApi，
#      通过 /rest/system/status 的 myID 字段拿到权威的本机 Device ID 并覆盖。
function Read-LocalIdentity {
    if (-not (Test-Path $LOCAL_SYNCTHING_CONFIG_XML)) {
        throw "本地 config.xml 不存在：$LOCAL_SYNCTHING_CONFIG_XML"
    }
    try {
        [xml]$cfg = Get-Content -Path $LOCAL_SYNCTHING_CONFIG_XML -Raw -Encoding UTF8
    } catch {
        throw "解析本地 config.xml 失败：$($_.Exception.Message)"
    }
    # 尝试猜 self：取 <device> 列表第一个（首次安装时 Syncthing 就是这样排的）
    $selfDevice = $cfg.configuration.device | Select-Object -First 1
    $deviceId = $null
    if ($selfDevice) { $deviceId = $selfDevice.id }
    $apiKey = $cfg.configuration.gui.apikey
    if ([string]::IsNullOrEmpty($apiKey)) {
        throw "无法从本地 config.xml 解析 API Key"
    }
    # Device ID 允许暂时为空或不准确——Confirm-LocalDeviceIdViaApi 会兜底更正
    $global:LOCAL_DEVICE_ID = $deviceId
    $global:LOCAL_API_KEY   = $apiKey
}

# 通过 /rest/system/status 的 myID 字段，拿到权威的本机 Device ID
# 必须在 Wait-LocalApiReady 之后调用。
function Confirm-LocalDeviceIdViaApi {
    try {
        $status = Invoke-LocalApi -Method GET -Path "/rest/system/status" -Retries 3
    } catch {
        # API 拿不到就退回 config.xml 的猜测值，不中断主流程
        Write-Warn "通过 API 获取本机 Device ID 失败（$($_.Exception.Message)），沿用 config.xml 的回退值"
        if ([string]::IsNullOrEmpty($global:LOCAL_DEVICE_ID)) {
            throw "无法确定本机 Device ID：API 不可达且 config.xml 无可用回退"
        }
        return
    }
    $myId = $null
    if ($status -and $status.PSObject.Properties.Name -contains 'myID') {
        $myId = [string]$status.myID
    }
    if ([string]::IsNullOrEmpty($myId)) {
        if ([string]::IsNullOrEmpty($global:LOCAL_DEVICE_ID)) {
            throw "API 未返回 myID 字段，且 config.xml 无回退 Device ID"
        }
        Write-Warn "API 未返回 myID 字段，沿用 config.xml 的回退值"
        return
    }

    if (-not [string]::IsNullOrEmpty($global:LOCAL_DEVICE_ID) `
        -and $global:LOCAL_DEVICE_ID -ne $myId) {
        # config.xml 的猜测值和 API 权威值不一致——这是幂等重跑场景，以 API 为准
        Write-Hint "本机 Device ID 从 config.xml 猜测值修正为 API 权威值"
    }
    $global:LOCAL_DEVICE_ID = $myId

    $didMasked = "$($myId.Substring(0, [Math]::Min(14, $myId.Length)))...$($myId.Substring([Math]::Max(0, $myId.Length - 7)))"
    Write-Ok "本地 Device ID：$didMasked"
}

# 步骤 4 主入口
function Deploy-LocalSyncthing {
    Write-Step "步骤 4/8：本地 Windows Syncthing 安装与启动"

    # 1) 幂等：已安装且版本合格直接跳过下载
    $info = Test-LocalSyncthingInstalled
    if ($info.Installed -and $info.Major -ge 2) {
        Write-Ok "本地 Syncthing 已安装（版本：$($info.Version)），跳过下载步骤（幂等）"
    } else {
        if ($info.Installed) {
            Write-Warn "本地已有 Syncthing $($info.Version)，但主版本 < 2，将重新下载 $LOCAL_SYNCTHING_VERSION 以保证与服务器端协议兼容"
        } else {
            Write-Info "本地未检测到 Syncthing，开始下载 $LOCAL_SYNCTHING_VERSION (windows-amd64)..."
        }
        $zip = Get-LocalSyncthingBinary
        Expand-LocalSyncthingBinary -ZipPath $zip
    }

    # 2) 生成 config.xml（首次）
    Initialize-LocalSyncthingConfig

    # 3) 修正 GUI 绑定（127.0.0.1:8384 + tls=false）
    Update-LocalSyncthingConfigGui

    # 4) 启动后台进程
    Start-LocalSyncthingProcess

    # 5) 先从 config.xml 读 API Key（Wait-LocalApiReady 里若有 key 走 ping，否则走 /rest/noauth/health）
    #    注意：这里读出的 Device ID 只是"回退值"，幂等重跑时 config.xml 里可能已经
    #    混入了远端 device；权威的本机 Device ID 必须在 API 就绪之后从 /rest/system/status 拿。
    Read-LocalIdentity

    # 6) 等待 API 就绪
    Wait-LocalApiReady

    # 7) 从 /rest/system/status 的 myID 拿权威 Device ID，覆盖第 5) 步的回退值
    Confirm-LocalDeviceIdViaApi

    Write-Ok "本地 Syncthing 就绪：http://127.0.0.1:8384"
}

# ---------------------------------------------------------------------------
# 模块：pair-devices —— 双向 Device ID 配对（步骤 5/8）
#
# 设计说明（与 obsidian-sync.sh 中 pair_devices() 行为完全对齐）：
#   - 幂等：先 GET /rest/config/devices，若目标 deviceID 已存在则跳过 POST
#   - 本地 → 服务器：addresses = ["tcp://$SSH_HOST:22000", "dynamic"]，autoAccept=false
#   - 服务器 → 本地：addresses = ["dynamic"]，autoAccept=true（本地动态 IP，并允许自动接受文件夹）
#   - 最后轮询 /rest/system/connections，60s 超时不阻断流程（其它服务器可能临时没上线，添 folder 时会再握手）
# ---------------------------------------------------------------------------

# 判断设备是否已在指定 scope 的 Syncthing 配置中存在
function Test-DeviceExists {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("local", "remote")][string]$Scope,
        [Parameter(Mandatory=$true)][string]$DeviceId
    )
    if ($Scope -eq "local") {
        $devices = Invoke-LocalApi  -Method GET -Path "/rest/config/devices"
    } else {
        $devices = Invoke-RemoteApi -Method GET -Path "/rest/config/devices"
    }
    # Syncthing 返回数组，逐个匹配 deviceID
    if (-not $devices) { return $false }
    foreach ($d in $devices) {
        if ($d.deviceID -eq $DeviceId) { return $true }
    }
    return $false
}

# 构造符合 Syncthing 2.x 模型的 device 对象（返回 JSON 字符串）
function New-DeviceJson {
    param(
        [Parameter(Mandatory=$true)][string]$DeviceId,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string[]]$Addresses,
        [bool]$AutoAcceptFolders = $false
    )
    # PS 5.1 和 PS 7 都支持 ConvertTo-Json；-Depth 5 避免数组被截断为 null
    $obj = [ordered]@{
        deviceID                 = $DeviceId
        name                     = $Name
        addresses                = $Addresses
        compression              = "metadata"
        introducer               = $false
        skipIntroductionRemovals = $false
        paused                   = $false
        allowedNetworks          = @()
        autoAcceptFolders        = $AutoAcceptFolders
        maxSendKbps              = 0
        maxRecvKbps              = 0
        ignoredFolders           = @()
        maxRequestKiB            = 0
    }
    return ($obj | ConvertTo-Json -Depth 5 -Compress)
}

# 向本地 Syncthing 添加服务器设备
function Add-RemoteDeviceToLocal {
    if (Test-DeviceExists -Scope local -DeviceId $global:REMOTE_DEVICE_ID) {
        Write-Ok "本地已存在服务器设备（幂等跳过）"
        return
    }
    Write-Info "向本地 Syncthing 添加服务器设备..."
    $body = New-DeviceJson `
        -DeviceId $global:REMOTE_DEVICE_ID `
        -Name "cloud-$($global:SSH_HOST)" `
        -Addresses @("tcp://$($global:SSH_HOST):22000", "dynamic") `
        -AutoAcceptFolders $false
    $null = Invoke-LocalApi -Method POST -Path "/rest/config/devices" -Body $body
    $global:ROLLBACK_STACK += "local_device:$($global:REMOTE_DEVICE_ID)"
    Write-Ok "服务器设备已加入本地配置"
}

# 向服务器 Syncthing 添加本地设备
function Add-LocalDeviceToRemote {
    if (Test-DeviceExists -Scope remote -DeviceId $global:LOCAL_DEVICE_ID) {
        Write-Ok "服务器已存在本地设备（幂等跳过）"
        return
    }
    Write-Info "向服务器 Syncthing 添加本地设备..."
    # Windows 上用 COMPUTERNAME 作为主机名来源，对应 sh 版的 hostname -s
    $hostShort = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "windows-client" }
    $body = New-DeviceJson `
        -DeviceId $global:LOCAL_DEVICE_ID `
        -Name "win-$hostShort" `
        -Addresses @("dynamic") `
        -AutoAcceptFolders $true
    $null = Invoke-RemoteApi -Method POST -Path "/rest/config/devices" -Body $body
    $global:ROLLBACK_STACK += "remote_device:$($global:LOCAL_DEVICE_ID)"
    Write-Ok "本地设备已加入服务器配置"
}

# L4 测一下 $SSH_HOST:22000 是否 TCP 可达，给用户一个更明确的排障线索
# 注意：
#   - 这里只是一个"快速提示"，不是判决依据；真正的决断走 /rest/system/connections 轮询
#   - 超时放宽到 5s：跨国/跨区云链路 3s 往往不够（SYN 首包 RTT + 云网关 SYN-ACK 处理偶尔会 >3s）
#   - EndConnect 单独 try，把 "WaitOne 超时" 与 "SYN 被拒" 两种失败分清楚
function Test-RemoteSyncPort {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($global:SSH_HOST, 22000, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
            # 超时：SYN 没回 SYN-ACK（或回得特别慢）
            return $false
        }
        try {
            $tcp.EndConnect($async)
            return $true
        } catch {
            # 对方 RST / 不可达主机
            return $false
        }
    } catch {
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch {} }
    }
}

# 轮询 /rest/system/connections，等待双向 TCP 握手建立
function Wait-PeerConnected {
    # 允许通过环境变量 OBSIDIAN_SYNC_PEER_WAIT 覆盖默认 60s（与 sh 版对齐）
    $waitTimeout = 60
    if ($env:OBSIDIAN_SYNC_PEER_WAIT -match '^\d+$') {
        $waitTimeout = [int]$env:OBSIDIAN_SYNC_PEER_WAIT
    }
    Write-Info "等待双向 TCP 连接建立（最长 ${waitTimeout}s，可用 OBSIDIAN_SYNC_PEER_WAIT 覆盖）..."

    # 端口快速探测（L4 SYN 握手；只是一个"提前提示"，不是判决依据）
    $portProbe = Test-RemoteSyncPort
    if ($portProbe) {
        Write-Ok "端口探测：$($global:SSH_HOST):22000 TCP 可达"
    } else {
        Write-Hint "端口探测：$($global:SSH_HOST):22000 首次 SYN 未在 5s 内握手成功（可能云网关首包处理慢或安全组未放通）"
        Write-Hint "  → 若下方最终提示"双向连接已建立"，说明端口实际是通的，可忽略本条提示"
        Write-Hint "  → 若一直未建立，请放通云厂商安全组：22000/tcp 与 22000/udp（可选 21027/udp 用于 LAN 发现）"
    }

    $waited = 0
    $connected = $false
    while ($waited -lt $waitTimeout) {
        try {
            $status = Invoke-LocalApi -Method GET -Path "/rest/system/connections" -Retries 1
            # 模型：{ total: {...}, connections: { "<deviceID>": { connected: bool, ... } } }
            if ($status -and $status.connections) {
                # PSObject 下用 PSObject.Properties 或动态属性访问
                $peer = $status.connections.PSObject.Properties[$global:REMOTE_DEVICE_ID]
                if ($peer -and $peer.Value -and $peer.Value.connected -eq $true) {
                    Write-Host ""
                    Write-Ok "双向连接已建立（connected=true）"
                    $connected = $true
                    break
                }
            }
        } catch {
            # 单次失败静默重试
        }
        Start-Sleep -Seconds 2
        $waited += 2
        Write-Host "." -NoNewline
    }

    if (-not $connected) {
        Write-Host ""
        Write-Err "${waitTimeout} 秒内未检测到 connected=true"
        Write-Err "排障建议："
        Write-Err "  1. 云厂商安全组是否放通 22000/tcp、8384(可选)、22000/udp"
        Write-Err "  2. 服务器本机防火墙是否放通（ufw/firewalld）"
        Write-Err "  3. Windows 上确认 $($global:SSH_HOST):22000 可达：Test-NetConnection $($global:SSH_HOST) -Port 22000"
        
        # 如果端口探测失败且最终连接失败，抛出错误停止执行
        if (-not $portProbe) {
            throw "同步连接失败：端口 $($global:SSH_HOST):22000 不可达，请检查安全组设置"
        } else {
            Write-Warn "将继续执行后续步骤（创建 folder 会主动触发握手，通常能加速连接建立）"
        }
    }
}

# 步骤 5 主入口
function Pair-Devices {
    Write-Step "步骤 5/8：双向 Device ID 配对"
    Add-RemoteDeviceToLocal
    Add-LocalDeviceToRemote
    Wait-PeerConnected
}

# ---------------------------------------------------------------------------
# 模块：select-vaults —— Obsidian Vault 发现与多选（步骤 6/8）
#
# 与 obsidian-sync.sh select_obsidian_vaults() 行为对齐：
#   1. 确定 Vault 根目录：默认 $DEFAULT_OBSIDIAN_ROOT，不存在则让用户输入自定义路径
#   2. 列出一级子目录作为候选（忽略隐藏目录），标注大小、是否含 OneDrive/云提供商占位符
#   3. 优先用 fzf（若已安装）；否则降级为数字菜单多选（空格/逗号/'a' 全选）
#   4. 结果写入 $global:SELECTED_VAULTS
# ---------------------------------------------------------------------------

# 探测目录下是否存在云盘未下载占位符。对应 sh 版 .icloud 检测，在 Windows 上识别 OneDrive 的按需文件：
#   - FILE_ATTRIBUTE_OFFLINE (0x1000)
#   - FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000)
# 扩展名为 .icloud 的文件也算（Mac 跨端拷贝了 iCloud 占位符的情况）。
function Test-DirHasCloudPlaceholder {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        # 限制深度：最多递归 5 层，避免 Vault 巨大时卡死
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue `
                    -Depth 5 | Select-Object -First 2000
    } catch { return $false }
    $offlineMask = 0x401000   # OFFLINE | RECALL_ON_DATA_ACCESS
    foreach ($f in $items) {
        if ($f.Name -like "*.icloud") { return $true }
        if ($f.Attributes -band $offlineMask) { return $true }
    }
    return $false
}

# 确定 Vault 根目录：默认使用 $DEFAULT_OBSIDIAN_ROOT，不存在则让用户手输
function Resolve-ObsidianRoot {
    if (Test-Path -LiteralPath $DEFAULT_OBSIDIAN_ROOT -PathType Container) {
        return $DEFAULT_OBSIDIAN_ROOT
    }
    Write-Warn "未检测到默认 Obsidian 目录："
    Write-Warn "  $DEFAULT_OBSIDIAN_ROOT"
    # 提供两个常见备选：OneDrive 或普通 Documents
    $oneDriveGuess = Join-Path $env:USERPROFILE "OneDrive\Documents\Obsidian"
    $docGuess      = Join-Path $env:USERPROFILE "Documents"
    $fallback = if (Test-Path -LiteralPath $oneDriveGuess -PathType Container) { $oneDriveGuess } else { $docGuess }

    $custom = Read-WithDefault -Prompt "请手动输入 Obsidian 根目录（包含多个 Vault 的父目录）" -DefaultValue $fallback
    if (-not (Test-Path -LiteralPath $custom -PathType Container)) {
        throw "目录不存在：$custom"
    }
    return $custom
}

# 列出候选 Vault（root 下的一级子目录），返回对象数组：
#   @{ Path = ...; SizeText = "12.3 MB" / "计算中"; HasPlaceholder = $true/$false; IsVault = $true/$false }
# IsVault: 目录内包含 .obsidian 则认为是真的 Obsidian Vault
function Get-VaultCandidates {
    param([Parameter(Mandatory=$true)][string]$Root)
    $dirs = Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue `
                | Where-Object { -not $_.Name.StartsWith(".") }
    $results = @()
    foreach ($d in $dirs) {
        # 大小计算用 Measure-Object + -ErrorAction SilentlyContinue，给巨大目录加上限（则显示 "> 5 GB"）
        $sizeText = "-"
        try {
            $tot = 0
            $fileCount = 0
            foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue) {
                $tot += $f.Length
                $fileCount++
                if ($tot -gt 5GB -or $fileCount -gt 20000) { break }
            }
            if     ($tot -gt 5GB) { $sizeText = "> 5.00 GB" }
            elseif ($tot -gt 1GB) { $sizeText = "{0:N2} GB" -f ($tot / 1GB) }
            elseif ($tot -gt 1MB) { $sizeText = "{0:N2} MB" -f ($tot / 1MB) }
            elseif ($tot -gt 1KB) { $sizeText = "{0:N1} KB" -f ($tot / 1KB) }
            else                   { $sizeText = "$tot B" }
        } catch {}

        $isVault = Test-Path -LiteralPath (Join-Path $d.FullName ".obsidian") -PathType Container
        $hasPlaceholder = Test-DirHasCloudPlaceholder -Path $d.FullName

        $results += [pscustomobject]@{
            Path           = $d.FullName
            Name           = $d.Name
            SizeText       = $sizeText
            IsVault        = $isVault
            HasPlaceholder = $hasPlaceholder
        }
    }
    # Vault 置顶，同类按名字排序，方便用户较快定位
    return ($results | Sort-Object -Property @{Expression="IsVault";Descending=$true}, @{Expression="Name";Descending=$false})
}

# 格式化单行展示（用于 fzf 输入、数字菜单）
function Format-VaultCandidateLine {
    param(
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)]$Candidate,
        [switch]$WithIndex
    )
    $tag = ""
    if ($Candidate.IsVault) { $tag += " [✓ Vault]" }
    if ($Candidate.HasPlaceholder) { $tag += " [⚠ 含云未下载占位]" }
    $namePart = $Candidate.Name
    if ($namePart.Length -gt 50) { $namePart = $namePart.Substring(0, 47) + "..." }
    if ($WithIndex) {
        return ("{0,2}. {1,-50}  {2,10}{3}" -f $Index, $namePart, $Candidate.SizeText, $tag)
    } else {
        return ("{0,-50}  {1,10}{2}" -f $namePart, $Candidate.SizeText, $tag)
    }
}

# 执行多选：fzf 可用则走 fzf，否则数字菜单
function Select-VaultsInteractive {
    param([Parameter(Mandatory=$true)][object[]]$Candidates)
    if ($Candidates.Count -eq 0) {
        throw "未发现任何 Vault 目录"
    }

    # 只有 1 个候选时，跳过 fzf/数字菜单这类多选 UI，直接询问 Y/n（更符合直觉，避免误操作）
    if ($Candidates.Count -eq 1) {
        $only = $Candidates[0]
        $line = Format-VaultCandidateLine -Index 1 -Candidate $only
        Write-Host ""
        Write-Host ("  仅发现 1 个候选 Vault：{0}" -f $line) -ForegroundColor White
        Write-Host ""
        if (Confirm "是否同步该 Vault？" "Y") {
            return @($only.Path)
        } else {
            throw "已取消：未选择任何 Vault"
        }
    }

    $hasFzf = [bool](Get-Command fzf -ErrorAction SilentlyContinue)
    if ($hasFzf) {
        Write-Info ("共 {0} 个候选目录：请按 TAB 选中（可多选），再按 ENTER 确认（ESC 取消）" -f $Candidates.Count)
        Write-Hint "提示：输入关键字可快速过滤；输入完后 Ctrl+A 可全选当前过滤结果"
        # 格式：<index>|<display>，只展示 display，回获用 index
        $lines = for ($i = 0; $i -lt $Candidates.Count; $i++) {
            "{0}|{1}" -f ($i + 1), (Format-VaultCandidateLine -Index ($i+1) -Candidate $Candidates[$i])
        }
        $tmpIn  = Join-Path $env:TEMP "obsidian-sync-fzf-in.txt"
        $tmpOut = Join-Path $env:TEMP "obsidian-sync-fzf-out.txt"
        $lines -join "`n" | Set-Content -LiteralPath $tmpIn -Encoding UTF8
        # 用 cmd 重定向执行 fzf，避免 PowerShell Pipeline 在 TUI 模式下的奇怪问题
        & cmd /c "type `"$tmpIn`" | fzf --multi --height=60%% --layout=reverse --border --header=`"TAB=选中  ENTER=确认  ESC=取消  Ctrl+A=全选`" --prompt=`"> `" --delimiter=`"|`" --with-nth=2 --bind=`"ctrl-a:select-all`" > `"$tmpOut`" 2>NUL" | Out-Null
        $selectedLines = @()
        if (Test-Path $tmpOut) {
            $selectedLines = @(Get-Content -LiteralPath $tmpOut -Encoding UTF8 | Where-Object { $_ -and $_.Trim() })
            Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $tmpIn -Force -ErrorAction SilentlyContinue
        if ($selectedLines.Count -eq 0) {
            Write-Hint "⚠ fzf 中未选中任何项：请用 TAB（而非直接 ENTER）选中条目后再确认；或输入关键字过滤后按 Ctrl+A 全选"
            throw "未选择任何 Vault"
        }
        $picked = @()
        foreach ($ln in $selectedLines) {
            $idx = [int]($ln.Split('|')[0])
            if ($idx -ge 1 -and $idx -le $Candidates.Count) {
                $picked += $Candidates[$idx - 1].Path
            }
        }
        return $picked
    }

    # 降级：数字菜单
    Write-Info "fzf 未安装，使用数字菜单多选"
    Write-Host ""
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        $line = Format-VaultCandidateLine -Index ($i+1) -Candidate $Candidates[$i] -WithIndex
        Write-Host ("  " + $line)
    }
    Write-Host ""
    Write-Info "输入方式：多个编号用空格或逗号分隔，例如：1 3 5；输入 a 全选；直接回车将取消"
    $input = Read-WithDefault -Prompt "请选择要同步的 Vault" -DefaultValue ""
    if ([string]::IsNullOrWhiteSpace($input)) {
        throw "未选择任何 Vault"
    }
    $pickedIdx = @{}
    if ($input.Trim() -ieq "a") {
        for ($k = 1; $k -le $Candidates.Count; $k++) { $pickedIdx[$k] = $true }
    } else {
        foreach ($token in ($input -split '[\s,]+')) {
            if ($token -match '^\d+$') {
                $n = [int]$token
                if ($n -ge 1 -and $n -le $Candidates.Count) { $pickedIdx[$n] = $true }
                else { Write-Warn "忽略无效输入：$token" }
            } elseif ($token) {
                Write-Warn "忽略无效输入：$token"
            }
        }
    }
    $picked = @()
    foreach ($k in $pickedIdx.Keys) { $picked += $Candidates[$k - 1].Path }
    if ($picked.Count -eq 0) { throw "未选择任何 Vault" }
    return $picked
}

# 步骤 6 主入口
function Select-ObsidianVaults {
    Write-Step "步骤 6/8：选择要同步的 Obsidian Vault"
    $root = Resolve-ObsidianRoot
    Write-Info "扫描目录：$root"

    $candidates = Get-VaultCandidates -Root $root
    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "$root 下未发现任何子目录（请确认此目录包含你的 Obsidian Vault）"
    }
    # PowerShell 单元素时 Sort-Object 返回标量而非数组，强制包装
    $candidates = @($candidates)
    Write-Hint ("共发现 {0} 个候选目录（{1} 个含 .obsidian 标记）" -f `
        $candidates.Count, (($candidates | Where-Object { $_.IsVault }).Count))

    $picked = Select-VaultsInteractive -Candidates $candidates
    $picked = @($picked)
    $global:SELECTED_VAULTS = $picked

    # 构建文件夹配置映射，用于后续复用文件夹ID
    $global:SAVED_FOLDER_MAP = @{}
    if ($global:SAVED_FOLDERS -and $global:SAVED_FOLDERS.Count -gt 0) {
        foreach ($savedFolder in $global:SAVED_FOLDERS) {
            if ($savedFolder.localPath) {
                $global:SAVED_FOLDER_MAP[$savedFolder.localPath] = $savedFolder.folderID
            }
        }
        Write-Info ("已加载 {0} 个已保存的文件夹配置" -f $global:SAVED_FOLDER_MAP.Count)
    }

    Write-Host ""
    Write-Info ("已选择 {0} 个 Vault：" -f $picked.Count)
    foreach ($p in $picked) {
        $warn = ""
        if (Test-DirHasCloudPlaceholder -Path $p) {
            $warn = "  [⚠ 含云未下载占位，建议先手动下载再同步！]"
        }
        
        # 显示是否复用已保存的文件夹ID
        $folderIdInfo = ""
        if ($global:SAVED_FOLDER_MAP.ContainsKey($p)) {
            $folderIdInfo = " [复用文件夹ID: $($global:SAVED_FOLDER_MAP[$p])]"
        }
        
        Write-Host ("  • {0}{1}{2}" -f $p, $warn, $folderIdInfo) -ForegroundColor White
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 模块：share-folders —— 创建双向共享文件夹（步骤 7/8）
#
# 与 obsidian-sync.sh create_shared_folders()/...share_one_vault() 行为对齐：
#   1. folderID 规范：清洗非法字符 + 5 位随机后缀，防冲突
#   2. 本地幂等：相同 path 已存在则复用原 folder id，不重建
#   3. 服务器先建目录并赋权，再 POST folder（/data/obsidian/<目录名>）
#   4. 轮询 /rest/db/status?folder=ID 等待首次扫描 idle（最长 300s，超时仅 warn）
#   5. Windows 特制：用 中英文/空格 的 Vault 名做 label，但 remote 目录名转为 ASCII 友好
# ---------------------------------------------------------------------------

# 将任意 Vault 名清洗为 folder id：
#   - 空格 → `-`
#   - 仅保留 A-Za-z0-9_-（漫字/中文/等完全剔除）
#   - 前缀最长 32
#   - 后缀：5 位小写随机（防擞同名冲突）
# 输入纯中文时兼骤 fallback="vault"
function ConvertTo-FolderId {
    param([Parameter(Mandatory=$true)][string]$Name)
    $clean = ($Name -replace '\s+', '-')
    $clean = ($clean -replace '[^A-Za-z0-9_-]', '')
    if ([string]::IsNullOrEmpty($clean)) { $clean = "vault" }
    if ($clean.Length -gt 32) { $clean = $clean.Substring(0, 32) }
    $suffix = (New-RandomString -Length 5).ToLower()
    return "{0}-{1}" -f $clean, $suffix
}

# Vault 名转为远端目录名：同 ConvertTo-FolderId 但不加随机后缀（目录名需要稳定、可读）
# 保留 _ 与 -，替换其他所有非 ASCII 位置；全空时 fallback 为 “vault-<随机>”
function ConvertTo-RemoteSafeName {
    param([Parameter(Mandatory=$true)][string]$Name)
    $clean = ($Name -replace '\s+', '-')
    $clean = ($clean -replace '[^A-Za-z0-9_-]', '')
    if ([string]::IsNullOrEmpty($clean)) {
        $clean = "vault-" + (New-RandomString -Length 5).ToLower()
    }
    if ($clean.Length -gt 48) { $clean = $clean.Substring(0, 48) }
    return $clean
}

# 判断 folder 是否已在指定 Syncthing（local/remote）配置中存在
function Test-FolderExists {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("local","remote")][string]$Scope,
        [Parameter(Mandatory=$true)][string]$FolderId
    )
    if ($Scope -eq "local") {
        $folders = Invoke-LocalApi  -Method GET -Path "/rest/config/folders"
    } else {
        $folders = Invoke-RemoteApi -Method GET -Path "/rest/config/folders"
    }
    if (-not $folders) { return $false }
    foreach ($f in $folders) {
        if ($f.id -eq $FolderId) { return $true }
    }
    return $false
}

# 本地幂等复用：根据 path 找已存在的 folder id（存在则返回，否则 $null）
function Find-LocalFolderIdByPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $folders = Invoke-LocalApi -Method GET -Path "/rest/config/folders"
    if (-not $folders) { return $null }
    
    # 规范化输入路径（统一大小写和路径分隔符）
    $normalizedPath = ($Path -replace '\\', '/').TrimEnd('/').ToLower()
    
    foreach ($f in $folders) {
        if (-not $f.path) { continue }
        
        # 规范化存储路径（统一大小写和路径分隔符）
        $normalizedStoredPath = ($f.path -replace '\\', '/').TrimEnd('/').ToLower()
        
        # 精确匹配规范化后的路径
        if ($normalizedStoredPath -eq $normalizedPath) {
            return $f.id
        }
    }
    return $null
}

# 构造 folder JSON（sendreceive + staggered 版本控制）
#   -PeerDeviceIds：对端 device ID 数组（不包含自己）
#     • 本地端：SELECTED_REMOTE_DEVICES（可多台）
#     • 服务器端：仅 $LOCAL_DEVICE_ID 一台
function New-FolderJson {
    param(
        [Parameter(Mandatory=$true)][string]$FolderId,
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string[]]$PeerDeviceIds,
        [bool]$Paused = $false
    )
    # devices = 自己 + 对端（去重、去空、去掘自己）
    $devices = @( [ordered]@{ deviceID = $global:LOCAL_DEVICE_ID } )
    $seen = @{ ($global:LOCAL_DEVICE_ID) = $true }
    foreach ($d in $PeerDeviceIds) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if ($seen.ContainsKey($d)) { continue }
        $seen[$d] = $true
        $devices += [ordered]@{ deviceID = $d }
    }

    $obj = [ordered]@{
        id                     = $FolderId
        label                  = $Label
        path                   = $Path
        type                   = "sendreceive"
        rescanIntervalS        = 60
        fsWatcherEnabled       = $true
        fsWatcherDelayS        = 10
        ignorePerms            = $false
        autoNormalize          = $true
        devices                = $devices
        versioning             = [ordered]@{
            type   = "staggered"
            params = [ordered]@{
                cleanInterval = "3600"
                maxAge        = "2592000"
                versionsPath  = ""
            }
        }
        copiers                = 0
        puller                 = 0
        hashers                = 0
        order                  = "random"
        ignoreDelete           = $false
        scanProgressIntervalS  = 0
        pullerPauseS           = 0
        maxConflicts           = 10
        disableSparseFiles     = $false
        disableTempIndexes     = $false
        paused                 = $Paused
        weakHashThresholdPct   = 25
        markerName             = ".stfolder"
        copyOwnershipFromParent = $false
        modTimeWindowS         = 0
    }
    return ($obj | ConvertTo-Json -Depth 10 -Compress)
}

# ---------------------------------------------------------------------------
# 幂等自愈：校验并补齐 folder.devices 数组
#
# 背景（对应 obsidian-sync.sh 历史没踩的坑）：
#   - 首次部署时，若本地 config.xml 里只有远端一条 <device>（因为远端 ID 被提前写入），
#     Confirm-LocalDeviceIdViaApi 之前的旧流程可能把 $LOCAL_DEVICE_ID 猜成了远端 ID
#   - 用错的 LOCAL_DEVICE_ID 创建远端 folder 后，远端 folder.devices 里就没有
#     真正的本地 device；之后再跑脚本走"幂等跳过"，folder 共享永远修不回来
#   - 症状：device 连接成功（connected=true）、本地 idle、但远端文件夹一直空
#
# 本函数职责：
#   1) 拉取目标端指定 folder 的当前配置
#   2) 如果 devices 数组里缺了 $RequiredDeviceId，就补进去并 PUT 回去
#   3) 已存在则沉默返回 $false（表示"无需改动"）
# ---------------------------------------------------------------------------
function Update-FolderDevicesIfMissing {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("local","remote")][string]$Scope,
        [Parameter(Mandatory=$true)][string]$FolderId,
        [Parameter(Mandatory=$true)][string]$RequiredDeviceId
    )

    if ([string]::IsNullOrWhiteSpace($RequiredDeviceId)) {
        Write-Warn "Update-FolderDevicesIfMissing: RequiredDeviceId 为空，跳过"
        return $false
    }

    $apiPath = "/rest/config/folders/$FolderId"
    try {
        if ($Scope -eq "local") {
            $folder = Invoke-LocalApi  -Method GET -Path $apiPath -Retries 2
        } else {
            $folder = Invoke-RemoteApi -Method GET -Path $apiPath -Retries 2
        }
    } catch {
        Write-Warn ("读取 {0} folder [{1}] 配置失败：{2}" -f $Scope, $FolderId, $_.Exception.Message)
        return $false
    }

    if (-not $folder) {
        Write-Warn ("{0} folder [{1}] 不存在，无法补齐 devices" -f $Scope, $FolderId)
        return $false
    }

    # 已经包含就返回 false
    $hasRequired = $false
    if ($folder.devices) {
        foreach ($d in $folder.devices) {
            if ($d.deviceID -and ($d.deviceID -eq $RequiredDeviceId)) { $hasRequired = $true; break }
        }
    }

    if ($hasRequired) { return $false }

    $maskedDid = if ($RequiredDeviceId.Length -ge 7) { $RequiredDeviceId.Substring(0,7) } else { $RequiredDeviceId }
    Write-Warn ("检测到 {0} folder [{1}] 的 devices 列表缺少 {2}...，正在补齐" -f $Scope, $FolderId, $maskedDid)

    # 把 PSCustomObject 的 devices 数组转成普通 hashtable 数组后追加
    $newDevices = @()
    if ($folder.devices) {
        foreach ($d in $folder.devices) {
            $entry = [ordered]@{ deviceID = [string]$d.deviceID }
            # 保留 Syncthing 可能带的 introducedBy / encryptionPassword 字段
            foreach ($propName in @('introducedBy','encryptionPassword')) {
                if ($d.PSObject.Properties.Name -contains $propName) {
                    $entry[$propName] = $d.$propName
                }
            }
            $newDevices += $entry
        }
    }
    $newDevices += [ordered]@{ deviceID = $RequiredDeviceId }

    # 只 PATCH devices 字段，避免把其他未知字段改坏
    # Syncthing v2 的 PATCH /rest/config/folders/{id} 接受部分 JSON
    $patchBody = @{ devices = $newDevices } | ConvertTo-Json -Depth 6 -Compress

    try {
        if ($Scope -eq "local") {
            $null = Invoke-LocalApi  -Method PATCH -Path $apiPath -Body $patchBody -Retries 2
        } else {
            $null = Invoke-RemoteApi -Method PATCH -Path $apiPath -Body $patchBody -Retries 2
        }
        Write-Ok ("{0} folder [{1}] 的 devices 已补齐（新增 {2}）" -f $Scope, $FolderId, $maskedDid)
        return $true
    } catch {
        Write-Warn ("PATCH 失败，改为 PUT 整体替换：{0}" -f $_.Exception.Message)
        # 回退方案：PUT 整条 folder（某些老版本不支持 PATCH 子字段）
        # 修改后的 folder 对象（把 devices 换成新的）
        $folder | Add-Member -NotePropertyName devices -NotePropertyValue $newDevices -Force
        $putBody = $folder | ConvertTo-Json -Depth 10 -Compress
        try {
            if ($Scope -eq "local") {
                $null = Invoke-LocalApi  -Method PUT -Path $apiPath -Body $putBody -Retries 2
            } else {
                $null = Invoke-RemoteApi -Method PUT -Path $apiPath -Body $putBody -Retries 2
            }
            Write-Ok ("{0} folder [{1}] 的 devices 已通过 PUT 补齐" -f $Scope, $FolderId)
            return $true
        } catch {
            Write-Warn ("补齐 devices 失败（{0}），请到 Syncthing GUI 手动把 device {1} 添加到该 folder 的共享列表" -f $_.Exception.Message, $maskedDid)
            return $false
        }
    }
}

# 在服务器上预创建目录并赋权给 Syncthing 运行用户
# 使用单引号 here-string + __PLACEHOLDER__ 占位替换的写法，避免
# PowerShell 双引号字符串里嵌套 `$` / `"` 的转义陷阱
function Invoke-RemotePrepareFolderDir {
    param([Parameter(Mandatory=$true)][string]$RemotePath)
    # 关键：同时创建 Syncthing 的 folder marker (.stfolder)。
    # 这是 Syncthing v2 的"数据丢失保护"机制——若 folder 根目录下没有 .stfolder，
    # 服务端会拒绝接收/应用任何来自对端的文件更改，对外表现为：
    #   - state=idle、needFiles=0、但 completion 永远卡在某个百分比；
    #   - syncthing 日志出现 "folder marker missing (this indicates potential data loss...)";
    # 本脚本负责创建远端目录，于是顺手把 marker 也建好（幂等，成本几乎为零），
    # 避免依赖 Syncthing 自己在扫描时 auto-create（在某些启动顺序 / 权限组合下不会建）。
    $tmpl = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
$sudo_cmd mkdir -p "__REMOTE_PATH__"
$sudo_cmd mkdir -p "__REMOTE_PATH__/.stfolder"
$sudo_cmd chmod 755 "__REMOTE_PATH__/.stfolder"
$sudo_cmd chown -R "__RUN_USER__":"__RUN_USER__" "__REMOTE_PATH__"
echo OK
'@
    $script = $tmpl.Replace("__REMOTE_PATH__", $RemotePath)
    $script = $script.Replace("__RUN_USER__",  $global:REMOTE_RUN_USER)
    $r = Invoke-SSHScript -Script $script -ThrowOnError
    if ($r.Output -notmatch 'OK') {
        throw "创建远端目录失败：$RemotePath`n$($r.Output)"
    }
}

# ---------------------------------------------------------------------------
# 修正远端 folder 的 path 字段
# ---------------------------------------------------------------------------
# 场景：远端 folder 是被更早的脚本 / auto-accept 在错误路径（例如 ~/Sync/<id>、
# /root/Sync/<id>）下建出来的；当前脚本"幂等跳过"时不会再次指定 path，导致
# 数据始终同步到非预期的位置。
#
# 本函数职责：
#   1) 拉取远端 folder 当前 path
#   2) 与 $ExpectedPath 比较，一致直接 return
#   3) 不一致则：
#       a. 确保新目录存在并赋权（Invoke-RemotePrepareFolderDir）
#       b. 若旧目录下有数据：在远端用 mv + rsync 迁移到新目录
#       c. PATCH folder.path = $ExpectedPath
#       d. 触发 rescan
# ---------------------------------------------------------------------------
function Repair-RemoteFolderPath {
    param(
        [Parameter(Mandatory=$true)][string]$FolderId,
        [Parameter(Mandatory=$true)][string]$ExpectedPath
    )

    $apiPath = "/rest/config/folders/$FolderId"
    try {
        $folder = Invoke-RemoteApi -Method GET -Path $apiPath -Retries 2
    } catch {
        Write-Warn ("读取远端 folder [{0}] 配置失败：{1}" -f $FolderId, $_.Exception.Message)
        return $false
    }
    if (-not $folder) {
        Write-Warn ("远端 folder [{0}] 不存在，跳过路径修正" -f $FolderId)
        return $false
    }

    $curPath = [string]$folder.path
    if ([string]::IsNullOrEmpty($curPath)) {
        Write-Warn ("远端 folder [{0}] 未返回 path 字段，跳过" -f $FolderId)
        return $false
    }

    # 规范化后比较（去掉末尾斜杠）
    $norm = { param($p) ($p -replace '/+$','') }
    if ((& $norm $curPath) -eq (& $norm $ExpectedPath)) {
        # 已经是期望路径
        return $true
    }

    Write-Warn ("远端 folder [{0}] 当前 path 与期望不一致" -f $FolderId)
    Write-Host ("    当前: {0}" -f $curPath)     -ForegroundColor Yellow
    Write-Host ("    期望: {0}" -f $ExpectedPath) -ForegroundColor Yellow

    # ----------------------------------------------------------------------
    # 关键时序保护：先 PAUSE 该 folder，阻止 Syncthing 继续在错误路径下写入。
    # 因为 Syncthing v2 服务端会把 POST body 里的绝对 path 存成相对路径（bug），
    # 然后 systemd 拉起的 syncthing 进程默认 cwd=/，导致相对路径 "x" 解析到 "/x"，
    # 数据会立刻开始往错位置写。我们必须先暂停，再搬数据，再 PATCH，再恢复。
    # ----------------------------------------------------------------------
    try {
        $null = Invoke-RemoteApi -Method PATCH -Path $apiPath -Body (@{paused=$true}|ConvertTo-Json -Compress) -Retries 2
        Write-Info "已临时暂停该 folder 的同步，避免搬运过程中继续写入"
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Warn ("暂停 folder 失败（继续进行，但可能有少量文件竞争）：{0}" -f $_.Exception.Message)
    }

    # ----------------------------------------------------------------------
    # 探测"旧路径"的真实位置：
    #   - 绝对路径：直接用；
    #   - 相对路径：candidate = /<rel> 和 $REMOTE_HOME/<rel>（systemd 默认 cwd=/，
    #     但万一服务端是通过 syncthing paths 的默认 basePath 解析也要兜底），
    #     哪个存在且非空就用哪个；都非空则按优先级 /<rel> 为主，$HOME/<rel> 合并。
    # ----------------------------------------------------------------------
    $oldCandidates = @()
    if ($curPath.StartsWith("/")) {
        $oldCandidates += $curPath
    } else {
        # systemd 拉起的 syncthing cwd 是 /（unit 未设置 WorkingDirectory）
        $oldCandidates += ("/" + $curPath.TrimStart("./"))
        if (-not [string]::IsNullOrEmpty($global:REMOTE_HOME)) {
            $oldCandidates += ($global:REMOTE_HOME.TrimEnd("/") + "/" + $curPath.TrimStart("./"))
        }
    }
    # 去重
    $oldCandidates = $oldCandidates | Select-Object -Unique

    # 探测每个候选目录是否非空
    $candListShell = ($oldCandidates | ForEach-Object { "`"" + ($_ -replace '"','\"') + "`"" }) -join " "
    $probeTmpl = @'
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
for p in __CAND_LIST__; do
    if [ -d "$p" ] && [ -n "$($sudo_cmd ls -A "$p" 2>/dev/null)" ]; then
        echo "NONEMPTY:$p"
    elif [ -d "$p" ]; then
        echo "EMPTY:$p"
    else
        echo "MISSING:$p"
    fi
done
'@
    $nonEmptyOld = @()
    try {
        $probe = $probeTmpl.Replace("__CAND_LIST__", $candListShell)
        $pr = Invoke-SSHScript -Script $probe -ThrowOnError
        foreach ($line in ($pr.Output -split "`r?`n")) {
            if ($line -match '^NONEMPTY:(.+)$') { $nonEmptyOld += $Matches[1] }
        }
    } catch {
        Write-Warn ("探测旧路径失败：{0}" -f $_.Exception.Message)
    }

    if ($nonEmptyOld.Count -gt 0) {
        Write-Warn ("检测到旧数据所在目录：")
        foreach ($d in $nonEmptyOld) { Write-Host ("      ▸ {0}" -f $d) -ForegroundColor Yellow }
    } else {
        Write-Info "未检测到旧路径下的残留数据，将直接修正配置"
    }

    # 1) 新目录就绪
    try {
        Invoke-RemotePrepareFolderDir -RemotePath $ExpectedPath
    } catch {
        Write-Warn ("创建目标目录失败：{0}" -f $_.Exception.Message)
        # 取消暂停（不然 folder 一直卡住）
        try { $null = Invoke-RemoteApi -Method PATCH -Path $apiPath -Body (@{paused=$false}|ConvertTo-Json -Compress) -Retries 1 } catch {}
        return $false
    }

    # 2) 远端迁移数据（可能有多个源）
    foreach ($src in $nonEmptyOld) {
        $tmpl = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
SRC="__SRC__"
DST="__DST__"
RUNUSER="__RUN_USER__"

if [ ! -d "$SRC" ]; then
    echo "NO_SRC"
    exit 0
fi

# 若 src 为空目录，不需要搬数据，直接清掉避免残留
if [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    $sudo_cmd rmdir "$SRC" 2>/dev/null || true
    echo "SRC_EMPTY"
    exit 0
fi

# 如果 DST 已经非空，把 src 内容并入（同名保留 dst 版本）
if [ -n "$(ls -A "$DST" 2>/dev/null)" ]; then
    if command -v rsync >/dev/null 2>&1; then
        $sudo_cmd rsync -a --ignore-existing "$SRC"/ "$DST"/
    else
        $sudo_cmd cp -an "$SRC"/. "$DST"/
    fi
    $sudo_cmd rm -rf "$SRC"
    echo "MERGED"
else
    # 同文件系统下用 mv 速度最快；跨文件系统自动回退
    $sudo_cmd mv "$SRC"/. "$DST"/ 2>/dev/null || {
        if command -v rsync >/dev/null 2>&1; then
            $sudo_cmd rsync -a "$SRC"/ "$DST"/
        else
            $sudo_cmd cp -a "$SRC"/. "$DST"/
        fi
        $sudo_cmd rm -rf "$SRC"
    }
    [ -d "$SRC" ] && $sudo_cmd rmdir "$SRC" 2>/dev/null || true
    echo "MOVED"
fi

$sudo_cmd chown -R "$RUNUSER":"$RUNUSER" "$DST"
echo DONE
'@
        $script = $tmpl.Replace("__SRC__", $src)
        $script = $script.Replace("__DST__", $ExpectedPath)
        $script = $script.Replace("__RUN_USER__", $global:REMOTE_RUN_USER)

        try {
            $r = Invoke-SSHScript -Script $script -ThrowOnError
            if ($r.Output -match 'MERGED') {
                Write-Ok ("已合并：{0} -> {1}（同名以目标为准）" -f $src, $ExpectedPath)
            } elseif ($r.Output -match 'MOVED') {
                Write-Ok ("已搬运：{0} -> {1}" -f $src, $ExpectedPath)
            } elseif ($r.Output -match 'SRC_EMPTY') {
                Write-Info ("源目录为空已清理：{0}" -f $src)
            } elseif ($r.Output -match 'NO_SRC') {
                # 静默
            } else {
                Write-Warn ("迁移脚本返回异常：{0}" -f $r.Output)
            }
        } catch {
            Write-Warn ("远端数据迁移失败（{0}）：{1}" -f $src, $_.Exception.Message)
            # 取消暂停再返回
            try { $null = Invoke-RemoteApi -Method PATCH -Path $apiPath -Body (@{paused=$false}|ConvertTo-Json -Compress) -Retries 1 } catch {}
            return $false
        }
    }

    # 3) PATCH folder.path 并恢复 paused=false
    #    Syncthing v2 某些版本会在每次 POST/PATCH 时把绝对 path 相对化（bug），
    #    所以这里 PATCH 之后立刻 GET 验证；如仍是相对路径则 fallback 到 PUT 整条。
    $patched = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $patchBody = @{ path = $ExpectedPath; paused = $false } | ConvertTo-Json -Depth 3 -Compress
        try {
            $null = Invoke-RemoteApi -Method PATCH -Path $apiPath -Body $patchBody -Retries 2
        } catch {
            Write-Warn ("PATCH path 失败（第 {0} 次）：{1}" -f $attempt, $_.Exception.Message)
        }
        # 验证
        Start-Sleep -Milliseconds 400
        try {
            $verify = Invoke-RemoteApi -Method GET -Path $apiPath -Retries 2
            $newPath = [string]$verify.path
            if ((& $norm $newPath) -eq (& $norm $ExpectedPath)) {
                Write-Ok ("远端 folder [{0}] 的 path 已更新为 {1}" -f $FolderId, $ExpectedPath)
                $patched = $true
                break
            } else {
                Write-Warn ("第 {0} 次 PATCH 后 path 仍为 '{1}'，即将重试..." -f $attempt, $newPath)
            }
        } catch {
            Write-Warn ("验证 folder.path 失败（第 {0} 次）：{1}" -f $attempt, $_.Exception.Message)
        }
    }

    if (-not $patched) {
        # fallback：PUT 整条
        Write-Warn "PATCH 多次未能修正 path，改为 PUT 整体替换"
        $folder | Add-Member -NotePropertyName path   -NotePropertyValue $ExpectedPath -Force
        $folder | Add-Member -NotePropertyName paused -NotePropertyValue $false        -Force
        $putBody = $folder | ConvertTo-Json -Depth 10 -Compress
        try {
            $null = Invoke-RemoteApi -Method PUT -Path $apiPath -Body $putBody -Retries 2
            Start-Sleep -Milliseconds 400
            $verify = Invoke-RemoteApi -Method GET -Path $apiPath -Retries 2
            $newPath = [string]$verify.path
            if ((& $norm $newPath) -eq (& $norm $ExpectedPath)) {
                Write-Ok ("远端 folder [{0}] 的 path 已通过 PUT 更新为 {1}" -f $FolderId, $ExpectedPath)
                $patched = $true
            } else {
                Write-Warn ("PUT 后 path 仍为 '{0}'" -f $newPath)
            }
        } catch {
            Write-Warn ("PUT 整条替换失败：{0}" -f $_.Exception.Message)
        }
    }

    if (-not $patched) {
        # 终极 fallback：停服务 → 直接改 config.xml → 起服务
        Write-Warn "API 方式均无法让服务端保存绝对 path，尝试离线直接修改 config.xml"
        $stopStartTmpl = @'
set -e
sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
RUN_USER="__RUN_USER__"
RUN_HOME="__RUN_HOME__"
FOLDER_ID="__FOLDER_ID__"
NEW_PATH="__NEW_PATH__"

# 定位 config.xml
CFG=""
for p in "$RUN_HOME/.local/state/syncthing/config.xml" "$RUN_HOME/.config/syncthing/config.xml"; do
    [ -f "$p" ] && CFG="$p" && break
done
if [ -z "$CFG" ]; then
    echo "CFG_NOT_FOUND"
    exit 0
fi

# 停服务
$sudo_cmd systemctl stop "syncthing@${RUN_USER}.service" >/dev/null 2>&1 || true
sleep 1

# 用 python 改 xml（Debian/Ubuntu 默认带 python3）
$sudo_cmd python3 - <<PYEOF
import xml.etree.ElementTree as ET, sys
cfg = r"$CFG"
fid = r"$FOLDER_ID"
newp = r"$NEW_PATH"
tree = ET.parse(cfg)
root = tree.getroot()
changed = False
for f in root.findall("folder"):
    if f.get("id") == fid:
        if f.get("path") != newp:
            f.set("path", newp); changed = True
if changed:
    tree.write(cfg, encoding="utf-8", xml_declaration=True)
    print("XML_UPDATED")
else:
    print("XML_NOCHANGE")
PYEOF

# 起服务
$sudo_cmd systemctl start "syncthing@${RUN_USER}.service"
echo DONE
'@
        $s = $stopStartTmpl.Replace("__RUN_USER__", $global:REMOTE_RUN_USER)
        $s = $s.Replace("__RUN_HOME__", $global:REMOTE_HOME)
        $s = $s.Replace("__FOLDER_ID__", $FolderId)
        $s = $s.Replace("__NEW_PATH__", $ExpectedPath)
        try {
            $r2 = Invoke-SSHScript -Script $s -ThrowOnError
            if ($r2.Output -match 'XML_UPDATED') {
                Write-Ok "已通过直接修改 config.xml 方式修正 folder.path"
                # 等待 Syncthing 重新启动（API 恢复可用）
                Start-Sleep -Seconds 3
                $patched = $true
            } elseif ($r2.Output -match 'XML_NOCHANGE') {
                Write-Info "config.xml 中 path 已经正确，无需改动"
                $patched = $true
            } else {
                Write-Warn ("离线修改失败：{0}" -f $r2.Output)
            }
        } catch {
            Write-Warn ("离线修改 config.xml 失败：{0}" -f $_.Exception.Message)
        }
    }

    if (-not $patched) {
        # 实在搞不定，确保至少取消暂停，让用户可以去 GUI 手工修
        try { $null = Invoke-RemoteApi -Method PATCH -Path $apiPath -Body (@{paused=$false}|ConvertTo-Json -Compress) -Retries 1 } catch {}
        Write-Warn "未能自动修正远端 folder.path，请登录 Syncthing GUI 手动把 path 改为：$ExpectedPath"
        return $false
    }

    # 4) 触发一次重新扫描
    try {
        $null = Invoke-RemoteApi -Method POST -Path "/rest/db/scan?folder=$FolderId" -Retries 1
    } catch { }

    return $true
}

function Wait-FolderScan {
    param(
        [Parameter(Mandatory=$true)][string]$FolderId,
        [int]$MaxWaitSec = 300
    )
    Write-Info "等待文件夹 [$FolderId] 完成首次扫描..."
    $waited = 0
    $done = $false
    while ($waited -lt $MaxWaitSec) {
        try {
            $status = Invoke-LocalApi -Method GET -Path "/rest/db/status?folder=$FolderId" -Retries 1
            $state = if ($status -and $status.state) { $status.state } else { "unknown" }
            switch ($state) {
                "idle" {
                    # 检查同步统计信息，确保文件实际同步
                    $syncStats = Invoke-LocalApi -Method GET -Path "/rest/db/status?folder=$FolderId" -Retries 1
                    if ($syncStats -and $syncStats.globalBytes -and $syncStats.globalBytes -gt 0) {
                        Write-Host ""
                        Write-Ok "[$FolderId] 扫描完成（idle），已同步 $($syncStats.globalBytes) 字节"
                        $done = $true
                    } else {
                        # 状态为idle但没有同步数据，可能是空文件夹或同步问题
                        Write-Host ""
                        Write-Warn "[$FolderId] 状态为idle但未检测到同步数据，继续等待..."
                        Start-Sleep -Seconds 5
                        $waited += 5
                        continue
                    }
                    break
                }
                "scanning" { Write-Host "." -NoNewline }
                "syncing"  { Write-Host "." -NoNewline }
                default    { Write-Host "?" -NoNewline }
            }
            if ($done) { break }
        } catch {
            # API 偶发失败静默重试
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if (-not $done) {
        Write-Host ""
        Write-Warn "[$FolderId] 首次扫描在 ${MaxWaitSec}s 内未结束（大 Vault 的正常行为，将后台继续）"
    }
}

# 验证文件同步状态
function Verify-SyncStatus {
    param(
        [Parameter(Mandatory=$true)][string]$FolderId,
        [Parameter(Mandatory=$true)][string]$LocalPath
    )

    Write-Info "验证文件夹 [$FolderId] 同步状态..."

    # 1. 检查本地文件夹状态
    if (-not (Test-Path $LocalPath)) {
        Write-Warn "本地文件夹路径不存在: $LocalPath"
        return $false
    }

    $localFiles = Get-ChildItem -Path $LocalPath -Recurse -File | Measure-Object
    Write-Info "本地文件夹包含 $($localFiles.Count) 个文件"

    if ($localFiles.Count -eq 0) {
        Write-Warn "本地文件夹为空，无需同步"
        return $true
    }

    # 2. 检查连接状态
    try {
        $connections = Invoke-LocalApi -Method GET -Path "/rest/system/connections" -Retries 2
        if (-not $connections -or -not $connections.connections) {
            Write-Warn "无法获取设备连接状态"
            return $false
        }

        $remoteConnected = $false
        foreach ($conn in $connections.connections.PSObject.Properties) {
            if ($conn.Name -eq $global:REMOTE_DEVICE_ID -and $conn.Value.connected -eq $true) {
                $remoteConnected = $true
                Write-Ok "远程设备连接正常"
                break
            }
        }

        if (-not $remoteConnected) {
            Write-Warn "远程设备未连接，请检查网络和端口设置"
            return $false
        }
    } catch {
        Write-Warn "连接状态检查失败：$($_.Exception.Message)"
        return $false
    }

    # 3. 检查同步统计信息
    try {
        $syncStats = Invoke-LocalApi -Method GET -Path "/rest/db/status?folder=$FolderId" -Retries 3
        if (-not $syncStats) {
            Write-Warn "无法获取同步统计信息"
            return $false
        }

        Write-Info "同步状态诊断："
        Write-Info "  - 状态: $($syncStats.state)"
        Write-Info "  - 本地字节: $($syncStats.localBytes)"
        Write-Info "  - 全局字节: $($syncStats.globalBytes)"
        Write-Info "  - 需要字节: $($syncStats.needBytes)"
    } catch {
        Write-Warn "同步状态检查失败：$($_.Exception.Message)"
        return $false
    }

    # 4. 本地和远端 folder 的 devices 列表交叉验证（这是同步是否真正建立的关键）
    try {
        $localFolder  = Invoke-LocalApi  -Method GET -Path "/rest/config/folders/$FolderId" -Retries 2
        $remoteFolder = Invoke-RemoteApi -Method GET -Path "/rest/config/folders/$FolderId" -Retries 2

        $localDevices  = @(); if ($localFolder  -and $localFolder.devices)  { $localDevices  = @($localFolder.devices  | ForEach-Object { [string]$_.deviceID }) }
        $remoteDevices = @(); if ($remoteFolder -and $remoteFolder.devices) { $remoteDevices = @($remoteFolder.devices | ForEach-Object { [string]$_.deviceID }) }

        Write-Info ("  - 本地 folder.devices: {0} 条"  -f $localDevices.Count)
        Write-Info ("  - 远端 folder.devices: {0} 条"  -f $remoteDevices.Count)

        $localHasRemote  = $localDevices  -contains $global:REMOTE_DEVICE_ID
        $remoteHasLocal  = $remoteDevices -contains $global:LOCAL_DEVICE_ID

        if (-not $localHasRemote) {
            Write-Warn "本地 folder 未把服务器 Device 列为 peer（缺 $($global:REMOTE_DEVICE_ID.Substring(0,7))...），同步不会发生"
            return $false
        }
        if (-not $remoteHasLocal) {
            Write-Warn "远端 folder 未把本地 Device 列为 peer（缺 $($global:LOCAL_DEVICE_ID.Substring(0,7))...），同步不会发生"
            return $false
        }

        Write-Ok "双向 folder.devices 互相包含，共享关系已建立"
    } catch {
        Write-Warn "folder.devices 交叉校验失败：$($_.Exception.Message)"
    }

    # 5. 综合判断：用 completion API 看"远端对这个 folder 的完成度"
    #    这是判断"服务器端是否真的收到了文件"的唯一权威判据。
    #    /rest/db/completion?folder=X&device=Y 返回 { completion: 0~100, needBytes, needItems, ... }
    #    其中 device 要填"对端"的 ID（从本地视角就是 REMOTE_DEVICE_ID），
    #    结果表示"对端相对 folder 的全局状态还差多少"。completion=100 且 needBytes=0 才算同步到位。
    try {
        $completion = Invoke-LocalApi -Method GET `
            -Path "/rest/db/completion?folder=$FolderId&device=$($global:REMOTE_DEVICE_ID)" -Retries 2
        if ($completion) {
            Write-Info "远端完成度："
            Write-Info ("  - completion: {0}%" -f $completion.completion)
            Write-Info ("  - needBytes : {0}" -f $completion.needBytes)
            Write-Info ("  - needItems : {0}" -f $completion.needItems)
            if ($completion.completion -ge 100 -and -not $completion.needBytes) {
                Write-Ok "远端已同步到 100%（文件已到达服务器）"
                return $true
            } else {
                Write-Warn ("远端尚未完成同步：completion={0}% needBytes={1} needItems={2}" -f `
                    $completion.completion, $completion.needBytes, $completion.needItems)
                Write-Hint "如果长时间卡在此处，请到 Syncthing GUI 查看 folder 页面是否有 'Out of Sync' 或红色错误"
                return $false
            }
        } else {
            Write-Warn "无法获取远端完成度"
            return $false
        }
    } catch {
        Write-Warn "远端完成度检查失败：$($_.Exception.Message)"
        return $false
    }
}

# 单个 Vault 的双向共享：本地建立 folder + 服务器建立 folder + 建目录赋权 + 等待首次扫描
function Add-OneSharedVault {
    param([Parameter(Mandatory=$true)][string]$LocalPath)

    $name = Split-Path -Path $LocalPath -Leaf
    
    # 优先使用已保存的文件夹ID，确保一致性
    $folderId = $null
    if ($global:SAVED_FOLDER_MAP -and $global:SAVED_FOLDER_MAP.ContainsKey($LocalPath)) {
        $folderId = $global:SAVED_FOLDER_MAP[$LocalPath]
        Write-Info ("═ 共享 [$name] ═（复用已保存的文件夹ID）")
    } else {
        $folderId = ConvertTo-FolderId -Name $name
        Write-Info ("═ 共享 [$name] ═（新文件夹ID）")
    }
    
    $remoteDir = ConvertTo-RemoteSafeName -Name $name
    $remotePath = "$DEFAULT_REMOTE_ROOT/$remoteDir"

    Write-Hint ("  folderID    = {0}" -f $folderId)
    Write-Hint ("  local path  = {0}" -f $LocalPath)
    Write-Hint ("  remote path = {0}" -f $remotePath)

    # 1) 本地幂等：同路径已存在 → 复用原 folder id
    $existId = Find-LocalFolderIdByPath -Path $LocalPath
    $skipServerSetup = $false
    
    if ($existId) {
        Write-Ok ("本地已存在同路径文件夹（id={0}），跳过本地添加" -f $existId)
        # 重要修复：如果已保存的文件夹ID与本地现有ID不一致，优先使用已保存的ID以确保一致性
        if ($global:SAVED_FOLDER_MAP -and $global:SAVED_FOLDER_MAP.ContainsKey($LocalPath) -and $global:SAVED_FOLDER_MAP[$LocalPath] -ne $existId) {
            Write-Warn "检测到文件夹ID不一致：本地现有=$existId，已保存=$($global:SAVED_FOLDER_MAP[$LocalPath])"
            Write-Warn "将强制使用已保存的文件夹ID以确保双向一致性"
            $folderId = $global:SAVED_FOLDER_MAP[$LocalPath]
        } else {
            $folderId = $existId
        }

        # 幂等自愈①：本地 folder 存在，但 devices 里可能缺 REMOTE_DEVICE_ID
        # （例如远端 Syncthing 重装导致远端 Device ID 变了）
        $null = Update-FolderDevicesIfMissing -Scope local -FolderId $folderId -RequiredDeviceId $global:REMOTE_DEVICE_ID

        # 如果本地已存在，检查服务器端是否也存在相同的文件夹ID
        if (Test-FolderExists -Scope remote -FolderId $folderId) {
            Write-Ok "服务器已存在 folder [$folderId]（幂等跳过）"
            # 幂等自愈⓪：即便走"幂等跳过"分支，也要确保 remotePath 目录 + .stfolder marker 存在。
            # 历史遗留：旧版脚本未建 marker，或运维手动 rm 过 marker，都会让服务端进入
            # "folder marker missing" 保护模式，表现为同步永远卡在某个百分比。
            try {
                Invoke-RemotePrepareFolderDir -RemotePath $remotePath
            } catch {
                Write-Warn ("补建远端目录/marker 失败（将继续，后续 Repair 步骤可能还会兜底）：{0}" -f $_.Exception.Message)
            }
            # 幂等自愈①：远端 folder.path 可能被早期脚本 / auto-accept 设成了非期望路径
            # （如 ~/Sync/<id>、/root/Sync/<id>），此处自动修正到 /data/obsidian/<dir>/
            $null = Repair-RemoteFolderPath -FolderId $folderId -ExpectedPath $remotePath
            # 幂等自愈②：远端 folder 存在，但 devices 里可能缺 LOCAL_DEVICE_ID
            # （这是老版本脚本的核心 bug：首次部署时本地 Device ID 读错了，
            #  导致远端 folder 自始至终没把真·本地 device 列为 peer，于是从不同步）
            $null = Update-FolderDevicesIfMissing -Scope remote -FolderId $folderId -RequiredDeviceId $global:LOCAL_DEVICE_ID
            $skipServerSetup = $true
        }
    } else {
        # 本地端：共享给 SELECTED_REMOTE_DEVICES 中所有的远端
        $peers = if ($global:SELECTED_REMOTE_DEVICES -and $global:SELECTED_REMOTE_DEVICES.Count -gt 0) {
            @($global:SELECTED_REMOTE_DEVICES)
        } else {
            @($global:REMOTE_DEVICE_ID)
        }
        $body = New-FolderJson -FolderId $folderId -Label $name -Path $LocalPath -PeerDeviceIds $peers
        $null = Invoke-LocalApi -Method POST -Path "/rest/config/folders" -Body $body
        $global:ROLLBACK_STACK += "local_folder:$folderId"
        Write-Ok "本地 folder 已添加"
    }

    # 2) 服务器端：只有在需要时才设置
    if (-not $skipServerSetup) {
        # 服务器端：先建目录 + chown
        Invoke-RemotePrepareFolderDir -RemotePath $remotePath

        # 3) 服务器端幂等：folderId 已存在 → 跳过
        if (Test-FolderExists -Scope remote -FolderId $folderId) {
            Write-Ok "服务器已存在 folder [$folderId]（幂等跳过）"
            # 幂等自愈：远端 folder.path 可能被 auto-accept 设到了默认位置，自动修正
            $null = Repair-RemoteFolderPath -FolderId $folderId -ExpectedPath $remotePath
            # 幂等自愈：远端 folder 可能缺 LOCAL_DEVICE_ID（上一次运行时本地 ID 被读错）
            $null = Update-FolderDevicesIfMissing -Scope remote -FolderId $folderId -RequiredDeviceId $global:LOCAL_DEVICE_ID
        } else {
            # 服务器端：仅与本地一台对端配对
            # 关键：Paused=$true 先行暂停，防止服务端把 path 相对化后立刻在错误目录启动同步；
            # 之后 Repair-RemoteFolderPath 会把 path 校准并恢复 paused=false
            $body = New-FolderJson -FolderId $folderId -Label $name -Path $remotePath -PeerDeviceIds @($global:LOCAL_DEVICE_ID) -Paused $true
            $null = Invoke-RemoteApi -Method POST -Path "/rest/config/folders" -Body $body
            $global:ROLLBACK_STACK += "remote_folder:$folderId"
            Write-Ok "服务器 folder 已添加（暂停中，待路径校准）"
            # 防御性兜底①：某些 Syncthing v2 版本在 POST 新 folder 时，会把 body 里的
            # 绝对 path 错误地存成相对路径（相对于 Syncthing 运行用户家目录）。
            # 这里立刻读回、比较、必要时 PATCH 修正，避免文件被同步到非预期位置。
            $null = Repair-RemoteFolderPath -FolderId $folderId -ExpectedPath $remotePath
            # 防御性兜底②：POST 之后再读回一次，若 devices 丢失则补上
            $null = Update-FolderDevicesIfMissing -Scope remote -FolderId $folderId -RequiredDeviceId $global:LOCAL_DEVICE_ID
        }
    }

    # 4) 登记共享结果
    $global:SHARED_FOLDERS += [pscustomobject]@{
        FolderId   = $folderId
        LocalPath  = $LocalPath
        RemotePath = $remotePath
        Label      = $name
    }

    # 5) 等待首次扫描
    Wait-FolderScan -FolderId $folderId

    # 6) 验证同步状态
    $syncVerified = Verify-SyncStatus -FolderId $folderId -LocalPath $LocalPath
    if (-not $syncVerified) {
        Write-Warn "文件夹 [$folderId] 同步状态验证失败，请检查连接和权限"
    } else {
        Write-Ok "文件夹 [$folderId] 同步验证通过"
    }
}

# 同步诊断工具
function Diagnose-SyncIssues {
    param(
        [Parameter(Mandatory=$false)][string]$FolderId
    )

    Write-Step "同步问题诊断"

    # 1. 检查本地Syncthing服务状态
    Write-Info "检查本地Syncthing服务..."
    try {
        $ping = Invoke-LocalApi -Method GET -Path "/rest/system/ping" -Retries 2
        if ($ping -and $ping.ping -eq "pong") {
            Write-Ok "本地Syncthing服务运行正常"
        } else {
            Write-Warn "本地Syncthing服务异常"
        }
    } catch {
        Write-Warn "无法连接本地Syncthing服务：$($_.Exception.Message)"
    }

    # 2. 检查设备连接状态
    Write-Info "检查设备连接状态..."
    try {
        $connections = Invoke-LocalApi -Method GET -Path "/rest/system/connections" -Retries 2
        if ($connections -and $connections.connections) {
            foreach ($conn in $connections.connections.PSObject.Properties) {
                $deviceId = $conn.Name
                $status = $conn.Value
                if ($deviceId -eq $global:REMOTE_DEVICE_ID) {
                    if ($status.connected) {
                        Write-Ok "远程设备连接正常"
                    } else {
                        Write-Warn "远程设备未连接"
                        Write-Info "  - 错误信息: $($status.error)"
                    }
                }
            }
        }
    } catch {
        Write-Warn "连接状态检查失败：$($_.Exception.Message)"
    }

    # 3. 检查文件夹状态
    if ($FolderId) {
        Write-Info "检查文件夹 [$FolderId] 状态..."
        try {
            $folderStatus = Invoke-LocalApi -Method GET -Path "/rest/db/status?folder=$FolderId" -Retries 2
            if ($folderStatus) {
                Write-Info "文件夹状态："
                Write-Info "  - 状态: $($folderStatus.state)"
                Write-Info "  - 本地字节: $($folderStatus.localBytes)"
                Write-Info "  - 全局字节: $($folderStatus.globalBytes)"
                Write-Info "  - 需要字节: $($folderStatus.needBytes)"
                Write-Info "  - 错误: $($folderStatus.error)"

                if ($folderStatus.error) {
                    Write-Warn "文件夹存在错误：$($folderStatus.error)"
                }
            }
        } catch {
            Write-Warn "文件夹状态检查失败：$($_.Exception.Message)"
        }
    }

    # 4. 端口连通性检查
    Write-Info "检查端口连通性..."
    try {
        $result = Test-NetConnection $global:REMOTE_HOST -Port 22000 -InformationLevel Quiet
        if ($result) {
            Write-Ok "端口22000连通性正常"
        } else {
            Write-Warn "端口22000无法连通，请检查防火墙和网络设置"
        }
    } catch {
        Write-Warn "端口检查失败：$($_.Exception.Message)"
    }

    Write-Ok "诊断完成，请根据以上信息排查问题"
}

# 步骤 7 主入口
function New-SharedFolders {
    Write-Step "步骤 7/8：建立双向文件夹共享"

    if (-not $global:SELECTED_VAULTS -or $global:SELECTED_VAULTS.Count -eq 0) {
        throw "没有待共享的 Vault（SELECTED_VAULTS 为空）"
    }

    # 如果 SELECTED_REMOTE_DEVICES 没被填充，默认只共享给本次目标服务器
    if (-not $global:SELECTED_REMOTE_DEVICES -or $global:SELECTED_REMOTE_DEVICES.Count -eq 0) {
        $global:SELECTED_REMOTE_DEVICES = @($global:REMOTE_DEVICE_ID)
    }

    # 展示本次要共享到的远端设备
    try {
        $allDevices = Invoke-LocalApi -Method GET -Path "/rest/config/devices"
        Write-Info ("本次将把新 Vault 共享给 {0} 个远端设备：" -f $global:SELECTED_REMOTE_DEVICES.Count)
        foreach ($did in $global:SELECTED_REMOTE_DEVICES) {
            $dname = "(未命名)"
            if ($allDevices) {
                foreach ($dev in $allDevices) {
                    if ($dev.deviceID -eq $did) { $dname = $dev.name; break }
                }
            }
            Write-Hint ("  ▸ {0}  ({1})" -f $dname, $did.Substring(0, [Math]::Min(7, $did.Length)))
        }
    } catch {
        # 获取失败不阻断
    }

    foreach ($v in $global:SELECTED_VAULTS) {
        Add-OneSharedVault -LocalPath $v
    }
    Write-Ok ("所有 {0} 个 Vault 共享配置已提交" -f $global:SELECTED_VAULTS.Count)
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

        # 检查是否运行诊断模式
        if ($args.Count -gt 0 -and $args[0] -eq "diagnose") {
            Write-Host "运行同步问题诊断模式..." -ForegroundColor Yellow
            Write-Host ""

            # 加载上次运行的配置
            if (Test-Path "$STATE_DIR\last-run.json") {
                $lastConfig = Get-Content "$STATE_DIR\last-run.json" | ConvertFrom-Json
                if ($lastConfig -and $lastConfig.server) {
                    $global:SSH_HOST = $lastConfig.server.host
                    $global:SSH_USER = $lastConfig.server.user
                    $global:REMOTE_DEVICE_ID = $lastConfig.server.deviceID
                    Write-Info "加载上次配置：服务器 $global:SSH_HOST，设备ID $global:REMOTE_DEVICE_ID"
                }

                if ($lastConfig.folders -and $lastConfig.folders.Count -gt 0) {
                    $folderId = $lastConfig.folders[0].folderID
                    Write-Info "诊断文件夹：$folderId"
                    Diagnose-SyncIssues -FolderId $folderId
                } else {
                    Diagnose-SyncIssues
                }
            } else {
                Diagnose-SyncIssues
            }
            return
        }

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
        
        # 步骤 2/8：服务器端 Syncthing 部署
        Deploy-RemoteSyncthing
        
        # 步骤 3/8：建立远端 API 通道与 GUI 凭证
        Invoke-RemoteApiTunnelSetup
        
        # 步骤 4/8：本地 Windows Syncthing 安装与启动
        Deploy-LocalSyncthing
        
        # 步骤 5/8：双向 Device ID 配对
        Pair-Devices

        # 步骤 6/8：选择要同步的 Obsidian Vault
        Select-ObsidianVaults

        # 步骤 7/8：建立双向共享文件夹
        New-SharedFolders
        
        # 步骤 8/8：持久化状态 + 美化总结
        Save-RunState
        Write-Summary
        
    } catch {
        Write-Err "执行失败: $($_.Exception.Message)"
        exit 1
    } finally {
        # 确保隧道被清理（即便后续步骤出错也不会遗留 plink 进程）
        Stop-SSHTunnel
    }
}

# ---------------------------------------------------------------------------
# 模块：state —— 运行状态持久化（步骤 8/8 第一部分）
#
# 与 obsidian-sync.sh save_state() 行为对齐：
#   - 写入路径：$env:USERPROFILE\.obsidian-sync\last-run.json
#   - 敏感信息（密码/API Key）绝不写入此文件，只保存结构性元数据
#   - 文件会被 Load-LastConfig 用作下次运行的默认值（主机、用户、端口）
# ---------------------------------------------------------------------------
function Save-RunState {
    if (-not (Test-Path $STATE_DIR)) {
        New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
    }

    # SHARED_FOLDERS 里每项是 [pscustomobject]@{ FolderId/LocalPath/RemotePath/Label }
    # 转成 sh 版一样的 [{folderID, localPath, remotePath}]
    $foldersArr = @()
    foreach ($f in $global:SHARED_FOLDERS) {
        $foldersArr += [pscustomobject]@{
            folderID   = $f.FolderId
            localPath  = $f.LocalPath
            remotePath = $f.RemotePath
            label      = $f.Label
        }
    }

    $state = [ordered]@{
        version   = $SCRIPT_VERSION
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        server    = [ordered]@{
            host       = $global:SSH_HOST
            user       = $global:SSH_USER
            port       = [int]$global:SSH_PORT
            deviceID   = $global:REMOTE_DEVICE_ID
            runUser    = $global:REMOTE_RUN_USER
            configPath = $global:REMOTE_CONFIG_XML
        }
        local     = [ordered]@{
            deviceID   = $global:LOCAL_DEVICE_ID
            configPath = $LOCAL_SYNCTHING_CONFIG_XML
        }
        folders   = $foldersArr
    }

    try {
        $json = $state | ConvertTo-Json -Depth 6
        # PowerShell 5.1 的 ConvertTo-Json 默认用 UTF-16；强制 UTF-8 无 BOM，便于 sh/jq 读取
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($STATE_FILE, $json, $utf8NoBom)
        Write-Ok "运行配置已保存至：$STATE_FILE"
    } catch {
        Write-Warn "保存运行配置失败（不影响本次部署结果）：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 模块：summary —— 部署总结（步骤 8/8 第二部分）
#
# 与 obsidian-sync.sh print_summary() 的内容结构对齐，但访问入口针对 Windows 特调：
#   - sh 版告诉 Mac 用户"再开一个终端 ssh -L 隧道"
#   - ps1 版直接给出 plink/ssh 两种写法；并明确 Windows 侧访问 127.0.0.1:8385
# ---------------------------------------------------------------------------
function Write-Summary {
    Write-Step "步骤 8/8：完成"
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                  🎉  部  署  完  成                      ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""

    # ── 连接信息 ────────────────────────────────
    Write-Host "🔗  连接信息" -ForegroundColor White
    Write-Host ("   本地 Device ID    {0}" -f $global:LOCAL_DEVICE_ID)   -ForegroundColor Cyan
    Write-Host ("   服务器 Device ID  {0}" -f $global:REMOTE_DEVICE_ID)  -ForegroundColor Cyan
    Write-Host ("   服务器地址        {0}@{1}:{2}" -f $global:SSH_USER, $global:SSH_HOST, $global:SSH_PORT) -ForegroundColor White
    Write-Host ""

    # ── 共享文件夹 ──────────────────────────────
    $folderCount = @($global:SHARED_FOLDERS).Count
    Write-Host ("📁  共享文件夹  ({0} 个)" -f $folderCount) -ForegroundColor White
    foreach ($f in $global:SHARED_FOLDERS) {
        Write-Host ("   ▸ {0}" -f $f.FolderId) -ForegroundColor Green
        Write-Host ("       本地   {0}" -f $f.LocalPath) -ForegroundColor Gray
        Write-Host  "         ↕" -ForegroundColor Magenta
        Write-Host ("       远端   {0}:{1}" -f $global:SSH_HOST, $f.RemotePath) -ForegroundColor Gray
    }
    Write-Host ""

    # ── 访问入口 ────────────────────────────────
    Write-Host "🌐  访问入口" -ForegroundColor White
    Write-Host ("   本地 Syncthing GUI   {0}" -f $LOCAL_API_URL) -ForegroundColor Cyan
    Write-Host "   远端 GUI（通过 SSH 隧道转发，安全加密）：" -ForegroundColor Gray
    Write-Host "       第 1 步  在 Windows 另开一个 PowerShell 窗口，执行（任选其一）：" -ForegroundColor White
    Write-Host ("         plink -ssh -N -L 8385:127.0.0.1:8384 -P {0} -l {1} {2}" -f $global:SSH_PORT, $global:SSH_USER, $global:SSH_HOST) -ForegroundColor DarkGray
    Write-Host ("         ssh   -N -L 8385:127.0.0.1:8384 -p {0} {1}@{2}"          -f $global:SSH_PORT, $global:SSH_USER, $global:SSH_HOST) -ForegroundColor DarkGray
    Write-Host "       第 2 步  在 Windows 浏览器访问（127.0.0.1 指的是本机，不是服务器）：" -ForegroundColor White
    Write-Host "         http://127.0.0.1:8385" -ForegroundColor Cyan
    Write-Host "       说明    远端 Syncthing GUI 只监听 127.0.0.1:8384，公网不可直连；" -ForegroundColor White
    Write-Host "               通过 SSH 隧道把它安全转发到本机 8385 端口来访问。" -ForegroundColor White
    if ($global:REMOTE_GUI_USER) {
        Write-Host ("       登录账号  {0}  /  {1}" -f $global:REMOTE_GUI_USER, $global:REMOTE_GUI_PASS) -ForegroundColor White
        Write-Host "                 (密码已加密保存到 Windows 凭据管理器，本地 Web UI 免密登录)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # ── 日志位置 ────────────────────────────────
    Write-Host "📝  日志 & 状态文件" -ForegroundColor White
    Write-Host ("   本地 Syncthing 日志  {0}" -f $LOCAL_SYNCTHING_LOG) -ForegroundColor Gray
    Write-Host ("   运行记录 (JSON)      {0}" -f $STATE_FILE)          -ForegroundColor Gray
    Write-Host ("   脚本运行日志         {0}" -f $LOG_FILE)            -ForegroundColor Gray
    Write-Host ""

    # ── 下一步提示 ──────────────────────────────
    Write-Host "💡  接下来" -ForegroundColor White
    Write-Host "   • 在任一端新增 / 修改 / 删除笔记，另一端会自动同步" -ForegroundColor Green
    Write-Host "   • 如果看到冲突文件（.sync-conflict-*），保留你想要的版本即可" -ForegroundColor Green
    Write-Host "   • 想新增同步目录？再次运行本脚本，再选一次 Vault 即可（幂等）" -ForegroundColor Green
    Write-Host "   • 本地 Syncthing 后台仍在运行（开机自启请自行加计划任务）；如需停止：" -ForegroundColor Green
    Write-Host ("     Stop-Process -Id (Get-Content '{0}') -Force" -f $LOCAL_SYNCTHING_PID_FILE) -ForegroundColor DarkGray
    Write-Host ""
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
        
        # 加载已保存的文件夹配置，确保文件夹ID一致性
        if ($config -and $config.PSObject.Properties.Name -contains 'folders') {
            $global:SAVED_FOLDERS = @($config.folders)
            if ($global:SAVED_FOLDERS.Count -gt 0) {
                Write-Info ("已加载 {0} 个已配置的文件夹" -f $global:SAVED_FOLDERS.Count)
            }
        }
    } catch {
        Write-Warn "加载上次配置失败: $($_.Exception.Message)"
    }
}

# 执行主函数
Main