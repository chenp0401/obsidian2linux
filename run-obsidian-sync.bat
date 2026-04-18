@echo off
REM ============================================================================
REM Obsidian同步工具启动脚本
REM 解决PowerShell终端中文乱码问题
REM ============================================================================

echo.
echo ================================================
echo   Obsidian同步工具启动器
echo   解决中文乱码问题
echo ================================================
echo.

REM 设置控制台代码页为UTF-8
chcp 65001 >nul

REM 显示当前编码状态
echo [编码设置]
echo 当前代码页: 65001 (UTF-8)
echo.

REM 启动PowerShell脚本
powershell -ExecutionPolicy Bypass -File "%~dp0obsidian-sync.ps1"

REM 暂停以便查看结果
if "%errorlevel%" neq "0" (
    echo.
    echo [错误] 脚本执行失败，错误代码: %errorlevel%
    pause
) else (
    echo.
    echo [完成] 脚本执行成功
    timeout /t 3 >nul
)

exit /b %errorlevel%