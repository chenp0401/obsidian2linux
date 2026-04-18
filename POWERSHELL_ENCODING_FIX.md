# PowerShell 中文乱码问题解决方案

## 问题描述
PowerShell脚本在VSCode中显示正常中文，但在PowerShell终端中运行时出现乱码。

## 根本原因
- **VSCode**：默认使用UTF-8编码
- **PowerShell终端**：默认使用系统代码页（如GBK/GB2312）
- **编码不一致**导致中文显示异常

## 解决方案

### 方案1：使用批处理文件启动（推荐）
```batch
# 使用 run-obsidian-sync.bat 启动
run-obsidian-sync.bat
```

**优点**：
- 自动设置UTF-8代码页
- 无需手动配置
- 兼容性好

### 方案2：手动设置PowerShell编码
```powershell
# 在PowerShell中执行以下命令
.\Set-PowerShellEncoding.ps1

# 或者永久设置
.\Set-PowerShellEncoding.ps1 -Permanent
```

**命令说明**：
- `Set-PowerShellEncoding`：临时设置当前会话
- `Set-PowerShellEncoding -Permanent`：永久修改PowerShell配置文件

### 方案3：直接运行PowerShell脚本（需手动设置）
```powershell
# 方法1：手动设置编码后运行
chcp 65001
powershell -ExecutionPolicy Bypass -File obsidian-sync.ps1

# 方法2：使用编码参数
powershell -ExecutionPolicy Bypass -File obsidian-sync.ps1 -Encoding UTF8
```

## 详细配置步骤

### 1. 检查当前编码状态
```powershell
# 查看当前编码设置
[Console]::OutputEncoding.EncodingName
$OutputEncoding.EncodingName
chcp
```

### 2. 临时修复编码
```powershell
# 设置UTF-8编码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001
```

### 3. 永久修复编码
```powershell
# 修改PowerShell配置文件
$profilePath = $PROFILE.CurrentUserAllHosts

# 添加编码设置到配置文件
Add-Content -Path $profilePath -Value @'
# UTF-8编码设置
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'UTF8'
chcp 65001 | Out-Null
'@
```

## 故障排除

### 问题1：设置后仍然乱码
**解决方案**：
1. 重启PowerShell终端
2. 检查字体是否支持中文
3. 尝试使用不同的终端（如Windows Terminal）

### 问题2：PowerShell配置文件不存在
**解决方案**：
```powershell
# 创建配置文件目录
$profileDir = Split-Path $PROFILE.CurrentUserAllHosts -Parent
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force
}

# 创建配置文件
if (-not (Test-Path $PROFILE.CurrentUserAllHosts)) {
    New-Item -ItemType File -Path $PROFILE.CurrentUserAllHosts -Force
}
```

### 问题3：chcp命令权限不足
**解决方案**：
- 以管理员身份运行PowerShell
- 或使用替代方案：
```powershell
# 使用.NET方法设置代码页
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConsoleEncoding {
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleOutputCP(uint wCodePageID);
    
    public static void SetUTF8() {
        SetConsoleOutputCP(65001);
    }
}
"@

[ConsoleEncoding]::SetUTF8()
```

## 推荐的终端设置

### Windows Terminal（推荐）
1. 安装Windows Terminal
2. 设置默认配置文件为PowerShell
3. 配置字体为支持中文的字体（如"Cascadia Code"、"微软雅黑"）

### PowerShell配置
```json
// Windows Terminal settings.json
{
    "profiles": {
        "defaults": {
            "font": {
                "face": "Cascadia Code",
                "size": 12
            },
            "experimental.retroTerminalEffect": false
        }
    }
}
```

## 验证编码设置

使用提供的测试脚本验证编码设置：
```powershell
# 运行编码测试
.\Set-PowerShellEncoding.ps1

# 或直接测试
Test-Encoding
```

**预期输出**：
```
普通中文: 这是一段测试文本
特殊符号: ✔ ✘ ℹ ⚠ ▶
标点符号: ，。！？；：""''（）【】《》
复杂中文: 饕餮耄耋龘龖
混合文本: Hello 世界！123测试
```

## 最佳实践

1. **开发时**：使用VSCode进行编辑和调试
2. **运行时**：使用批处理文件启动脚本
3. **部署时**：确保目标环境已正确设置编码
4. **测试时**：使用Test-Encoding函数验证中文显示

## 相关文件

- `obsidian-sync.ps1`：主脚本（已内置编码修复）
- `run-obsidian-sync.bat`：批处理启动器
- `Set-PowerShellEncoding.ps1`：编码设置工具
- `POWERSHELL_ENCODING_FIX.md`：本文档

## 技术支持

如果以上方案均无法解决问题，请检查：
1. 系统区域设置是否为中文
2. 系统字体是否支持中文显示
3. PowerShell版本是否过旧
4. 终端模拟器是否支持UTF-8

---
*最后更新：$(Get-Date -Format "yyyy-MM-dd")*