# ============================================================================
# remote-execute.ps1
#   PowerShell脚本远程执行工具
#   支持SSH、WinRM、PowerShell Remoting等多种远程执行方式
# ============================================================================

param(
    [string]$RemoteHost,
    [string]$Username,
    [string]$Password,
    [string]$ScriptPath,
    [string]$Method = "ssh",
    [string]$LogPath = "remote-execution.log"
)

# 日志函数
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    $logEntry | Out-File $LogPath -Append -Encoding UTF8
}

# 方法1：SSH远程执行
function Invoke-RemoteSSH {
    param([string]$Host, [string]$User, [string]$Pass, [string]$Script)
    
    Write-Log "使用SSH方法远程执行脚本"
    
    # 检查sshpass是否安装
    if (-not (Get-Command "sshpass" -ErrorAction SilentlyContinue)) {
        throw "请先安装sshpass: sudo apt-get install sshpass"
    }
    
    # 构建SSH命令
    $remoteCommand = "powershell -ExecutionPolicy Bypass -File \"$Script\""
    $sshCommand = "sshpass -p '$Pass' ssh -o StrictHostKeyChecking=no $User@$Host `"$remoteCommand`""
    
    Write-Log "执行命令: $sshCommand"
    
    try {
        $output = Invoke-Expression $sshCommand 2>&1
        Write-Log "执行成功"
        Write-Log "输出结果: $output"
        return $output
    } catch {
        Write-Log "SSH执行失败: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# 方法2：WinRM远程执行
function Invoke-RemoteWinRM {
    param([string]$Host, [string]$User, [string]$Pass, [string]$Script)
    
    Write-Log "使用WinRM方法远程执行脚本"
    
    # 检查WinRM服务是否启用
    try {
        # 使用PowerShell Remoting作为WinRM的替代
        $securePass = ConvertTo-SecureString $Pass -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($User, $securePass)
        
        $session = New-PSSession -ComputerName $Host -Credential $credential -ErrorAction Stop
        Write-Log "远程会话建立成功"
        
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($ScriptPath)
            & $ScriptPath
        } -ArgumentList $Script
        
        Remove-PSSession $session
        Write-Log "执行完成"
        return $result
        
    } catch {
        Write-Log "WinRM/PowerShell Remoting失败: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "请确保目标机器已启用PowerShell Remoting:"
        Write-Log "  1. 以管理员身份运行: Enable-PSRemoting -Force"
        Write-Log "  2. 设置信任主机: Set-Item WSMan:localhost\client\trustedhosts * -Force"
        throw
    }
}

# 方法3：文件复制+远程执行
function Invoke-RemoteFileCopy {
    param([string]$Host, [string]$User, [string]$Pass, [string]$Script)
    
    Write-Log "使用文件复制方法远程执行"
    
    # 检查是否安装了必要的工具
    if (-not (Get-Command "scp" -ErrorAction SilentlyContinue)) {
        throw "请先安装SCP客户端"
    }
    
    # 复制文件到远程主机
    $remotePath = "/tmp/$(Get-Date -Format 'yyyyMMdd-HHmmss')-obsidian-sync.ps1"
    $scpCommand = "sshpass -p '$Pass' scp -o StrictHostKeyChecking=no '$Script' $User@$Host:$remotePath"
    
    Write-Log "复制文件: $scpCommand"
    Invoke-Expression $scpCommand
    
    # 远程执行
    $remoteCommand = "sshpass -p '$Pass' ssh -o StrictHostKeyChecking=no $User@$Host 'powershell -ExecutionPolicy Bypass -File $remotePath'"
    Write-Log "远程执行: $remoteCommand"
    
    try {
        $output = Invoke-Expression $remoteCommand 2>&1
        Write-Log "执行成功"
        return $output
    } catch {
        Write-Log "远程执行失败: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# 主函数
function Main {
    Write-Log "开始远程执行PowerShell脚本"
    Write-Log "目标主机: $RemoteHost"
    Write-Log "执行方法: $Method"
    Write-Log "脚本路径: $ScriptPath"
    
    # 参数验证
    if ([string]::IsNullOrEmpty($RemoteHost) -or [string]::IsNullOrEmpty($ScriptPath)) {
        throw "必须指定RemoteHost和ScriptPath参数"
    }
    
    if ([string]::IsNullOrEmpty($Username)) {
        $Username = Read-Host "请输入用户名"
    }
    
    if ([string]::IsNullOrEmpty($Password)) {
        $Password = Read-Host "请输入密码" -AsSecureString | ConvertFrom-SecureString
    }
    
    # 根据选择的方法执行
    switch ($Method.ToLower()) {
        "ssh" {
            return Invoke-RemoteSSH -Host $RemoteHost -User $Username -Pass $Password -Script $ScriptPath
        }
        "winrm" {
            return Invoke-RemoteWinRM -Host $RemoteHost -User $Username -Pass $Password -Script $ScriptPath
        }
        "filecopy" {
            return Invoke-RemoteFileCopy -Host $RemoteHost -User $Username -Pass $Password -Script $ScriptPath
        }
        default {
            throw "不支持的执行方法: $Method。支持的方法: ssh, winrm, filecopy"
        }
    }
}

# 使用示例和帮助信息
function Show-Usage {
    Write-Host "=== PowerShell脚本远程执行工具 ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "使用方法:" -ForegroundColor Yellow
    Write-Host "  .\remote-execute.ps1 -RemoteHost <host> -ScriptPath <script> [选项]"
    Write-Host ""
    Write-Host "必需参数:" -ForegroundColor Yellow
    Write-Host "  -RemoteHost   目标Windows主机名或IP地址"
    Write-Host "  -ScriptPath   要执行的PowerShell脚本路径"
    Write-Host ""
    Write-Host "可选参数:" -ForegroundColor Yellow
    Write-Host "  -Username     用户名（如未提供会提示输入）"
    Write-Host "  -Password     密码（如未提供会提示输入）"
    Write-Host "  -Method       执行方法: ssh, winrm, filecopy（默认: ssh）"
    Write-Host "  -LogPath      日志文件路径（默认: remote-execution.log）"
    Write-Host ""
    Write-Host "示例:" -ForegroundColor Green
    Write-Host "  1. SSH方式: .\remote-execute.ps1 -RemoteHost 192.168.1.100 -ScriptPath C:\scripts\test.ps1"
    Write-Host "  2. WinRM方式: .\remote-execute.ps1 -RemoteHost win-server -Method winrm -ScriptPath C:\scripts\test.ps1"
    Write-Host "  3. 文件复制方式: .\remote-execute.ps1 -RemoteHost 192.168.1.100 -Method filecopy -ScriptPath ./local-script.ps1"
    Write-Host ""
}

# 脚本入口
if ($args.Count -eq 0 -or $args[0] -eq "-help" -or $args[0] -eq "-h") {
    Show-Usage
    exit 0
}

try {
    Main
    Write-Log "远程执行完成" -Level "SUCCESS"
} catch {
    Write-Log "远程执行失败: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}