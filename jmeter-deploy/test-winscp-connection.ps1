# test-basic.ps1
$ip = "172.16.125.173"
$user = "a"
$pass = "123456"

Write-Host "🔍 测试基本命令执行..." -ForegroundColor Cyan

# 测试1：简单的echo命令
$testScript = @"
open scp://$user`:$pass@$ip -hostkey="*" -timeout=60
call echo "测试命令1"
call cmd /c "echo 测试命令2"
exit
"@

$tempFile = "test_basic.txt"
Set-Content -Path $tempFile -Value $testScript -Encoding UTF8

& $WinSCPPath /script=$tempFile /log="test_basic.log" /loglevel=0 /timeout=60
Remove-Item $tempFile -Force

if (Select-String -Path "test_basic.log" -Pattern "测试命令") {
    Write-Host "✅ 基本命令测试成功" -ForegroundColor Green
} else {
    Write-Host "❌ 基本命令测试失败" -ForegroundColor Red
    Write-Host "查看日志: test_basic.log" -ForegroundColor Yellow
}