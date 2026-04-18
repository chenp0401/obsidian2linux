# PowerShell脚本远程执行指南

## 概述

本文档提供了多种远程执行PowerShell脚本的方法，特别适合在Linux环境下远程执行Windows机器上的PowerShell脚本。

## 方法一：SSH远程执行（推荐）

### 前提条件
- 目标Windows机器已启用SSH服务
- Linux机器已安装SSH客户端和sshpass

### 安装依赖
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install openssh-client sshpass

# CentOS/RHEL
sudo yum install openssh-clients sshpass
```

### 基本用法
```bash
# 直接执行远程PowerShell脚本
ssh username@windows-host "powershell -ExecutionPolicy Bypass -File C:\\path\\to\\obsidian-sync.ps1"

# 带密码的非交互式执行
sshpass -p 'password' ssh username@windows-host "powershell -ExecutionPolicy Bypass -File C:\\path\\to\\obsidian-sync.ps1"

# 捕获输出和错误
sshpass -p 'password' ssh username@windows-host "powershell -ExecutionPolicy Bypass -File C:\\path\\to\\obsidian-sync.ps1 2>&1"

# 保存日志到文件
sshpass -p 'password' ssh username@windows-host "powershell -ExecutionPolicy Bypass -File C:\\path\\to\\obsidian-sync.ps1 2>&1" | tee remote-execution.log
```

### Windows端SSH服务配置
1. 打开"设置" → "应用" → "可选功能" → "添加功能"
2. 搜索并安装"OpenSSH服务器"
3. 启动服务：`Start-Service sshd`
4. 设置开机自启：`Set-Service sshd -StartupType Automatic`

## 方法二：WinRM远程执行

### 前提条件
- 目标Windows机器已启用WinRM服务
- Linux机器已安装Python和pywinrm

### 安装依赖
```bash
pip install pywinrm
```

### Python示例脚本
```python
#!/usr/bin/env python3
import winrm
import sys

def remote_execute_powershell(host, username, password, script_path):
    """远程执行PowerShell脚本"""
    
    # 创建会话
    session = winrm.Session(
        host,
        auth=(username, password),
        transport='ntlm'
    )
    
    # 构建PowerShell命令
    ps_command = f"powershell -ExecutionPolicy Bypass -File {script_path}"
    
    try:
        # 执行命令
        result = session.run_ps(ps_command)
        
        print("执行结果:")
        print("标准输出:", result.std_out.decode('utf-8', errors='ignore'))
        if result.std_err:
            print("错误输出:", result.std_err.decode('utf-8', errors='ignore'))
        
        return result.status_code == 0
        
    except Exception as e:
        print(f"远程执行失败: {e}")
        return False

# 使用示例
if __name__ == "__main__":
    remote_execute_powershell(
        host="192.168.1.100",
        username="administrator",
        password="your_password",
        script_path="C:\\scripts\\obsidian-sync.ps1"
    )
```

### Windows端WinRM配置
```powershell
# 以管理员身份运行PowerShell
# 启用WinRM服务
Enable-PSRemoting -Force

# 设置信任所有主机（仅测试环境）
Set-Item WSMan:\localhost\Client\TrustedHosts * -Force

# 重启WinRM服务
Restart-Service WinRM
```

## 方法三：PowerShell Remoting

### 前提条件
- 目标Windows机器已启用PowerShell Remoting
- 执行机器为Windows或安装PowerShell Core的Linux

### PowerShell Core安装（Linux）
```bash
# Ubuntu/Debian
wget -q https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get update
sudo apt-get install -y powershell

# CentOS/RHEL
sudo yum install -y powershell
```

### 使用示例
```powershell
# 建立远程会话
$credential = Get-Credential
$session = New-PSSession -ComputerName "windows-host" -Credential $credential

# 远程执行脚本
Invoke-Command -Session $session -ScriptBlock {
    & "C:\path\to\obsidian-sync.ps1"
}

# 关闭会话
Remove-PSSession $session
```

## 使用提供的远程执行工具

### 安装依赖
确保Linux机器已安装：
- PowerShell Core（可选，用于PowerShell Remoting）
- OpenSSH客户端
- sshpass

### 基本用法
```bash
# 使用SSH方法
pwsh ./remote-execute.ps1 -RemoteHost "192.168.1.100" -ScriptPath "/path/to/obsidian-sync.ps1" -Method ssh

# 使用WinRM方法
pwsh ./remote-execute.ps1 -RemoteHost "192.168.1.100" -ScriptPath "/path/to/obsidian-sync.ps1" -Method winrm

# 指定用户名和密码
pwsh ./remote-execute.ps1 -RemoteHost "192.168.1.100" -Username "administrator" -Password "your_password" -ScriptPath "/path/to/obsidian-sync.ps1"
```

### 参数说明
- `-RemoteHost`: 目标Windows主机IP或主机名
- `-ScriptPath`: 要执行的PowerShell脚本路径
- `-Method`: 执行方法（ssh/winrm/filecopy）
- `-Username`: 用户名（可选，会提示输入）
- `-Password`: 密码（可选，会提示输入）
- `-LogPath`: 日志文件路径（默认：remote-execution.log）

## 日志和错误处理

### 日志文件位置
- 远程执行工具：`remote-execution.log`
- PowerShell脚本：`~/.obsidian-sync/run.log`

### 错误排查

#### SSH连接问题
```bash
# 测试SSH连接
ssh username@host "echo test"

# 检查SSH服务状态
ssh username@host "Get-Service sshd"

# 查看防火墙规则
ssh username@host "Get-NetFirewallRule | Where-Object {$_.DisplayName -like '*ssh*'}"
```

#### WinRM连接问题
```powershell
# 测试WinRM连接
Test-WSMan -ComputerName "host"

# 检查WinRM服务状态
Get-Service WinRM

# 查看WinRM配置
Get-Item WSMan:\localhost\Client\TrustedHosts
```

#### 脚本执行问题
```powershell
# 检查执行策略
Get-ExecutionPolicy

# 临时绕过执行策略
powershell -ExecutionPolicy Bypass -File script.ps1

# 查看详细的错误信息
try {
    & "script.ps1"
} catch {
    Write-Host "错误详情: $($_.Exception.Message)"
    Write-Host "堆栈跟踪: $($_.ScriptStackTrace)"
}
```

## 安全注意事项

1. **使用密钥认证**：避免在命令行中直接传递密码
2. **限制访问权限**：只允许必要的用户远程执行
3. **网络隔离**：在生产环境中使用VPN或专用网络
4. **日志审计**：记录所有远程执行操作
5. **定期更新**：保持系统和工具的最新版本

## 自动化部署示例

### 使用Ansible
```yaml
- name: 远程执行PowerShell脚本
  hosts: windows_servers
  tasks:
    - name: 复制脚本到远程主机
      win_copy:
        src: scripts/obsidian-sync.ps1
        dest: C:\scripts\obsidian-sync.ps1
    
    - name: 执行PowerShell脚本
      win_shell: powershell -ExecutionPolicy Bypass -File C:\scripts\obsidian-sync.ps1
      register: result
    
    - name: 显示执行结果
      debug:
        var: result.stdout
```

### 使用Jenkins Pipeline
```groovy
pipeline {
    agent any
    stages {
        stage('远程执行PowerShell') {
            steps {
                script {
                    def result = powershell script: '''
                        param($RemoteHost, $ScriptPath)
                        .\remote-execute.ps1 -RemoteHost $RemoteHost -ScriptPath $ScriptPath -Method ssh
                    ''', parameters: [[$class: 'StringParameterValue', name: 'RemoteHost', value: '192.168.1.100'],
                                     [$class: 'StringParameterValue', name: 'ScriptPath', value: 'C:\\scripts\\obsidian-sync.ps1']]
                    
                    echo "执行结果: ${result}"
                }
            }
        }
    }
}
```

## 故障排除

### 常见问题及解决方案

1. **SSH连接被拒绝**
   - 检查Windows SSH服务是否运行
   - 检查防火墙是否允许SSH端口（默认22）
   - 验证用户名和密码

2. **WinRM连接超时**
   - 检查WinRM服务状态
   - 验证网络连通性
   - 检查防火墙规则

3. **脚本执行权限错误**
   - 检查PowerShell执行策略
   - 验证脚本路径是否正确
   - 检查文件权限

4. **中文乱码问题**
   - 使用提供的编码修复功能
   - 确保远程终端支持UTF-8
   - 检查字体设置

### 获取帮助
```bash
# 查看远程执行工具帮助
pwsh ./remote-execute.ps1 -help

# 查看PowerShell脚本帮助
powershell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -help
```