elseif ($os -eq "windows") {
    Write-Host "🔧 使用混合模式部署Windows主机 $ip ..." -ForegroundColor Yellow
    
    try {
        # 步骤1：先通过SSH上传文件
        Write-Host "📤 步骤1: 通过SSH上传文件..." -ForegroundColor Cyan
        $uploadScript = @"
open sftp://$user`:$pass@$ip:22 -hostkey="*" -timeout=120
mkdir C:/temp
put "$JMeterZip" C:/temp/
exit
"@
        
        $tempUpload = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempUpload -Value $uploadScript -Encoding UTF8
        & $WinSCPPath /script=$tempUpload /log=.\upload_$ip.log /loglevel=0 /timeout=120
        Remove-Item $tempUpload -Force
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ 文件上传失败" -ForegroundColor Red
            continue
        }
        
        Write-Host "✅ 文件上传成功" -ForegroundColor Green
        
        # 步骤2：通过WinRM部署JMeter
        Write-Host "⚙️ 步骤2: 通过WinRM部署JMeter..." -ForegroundColor Cyan
        
        # 创建凭据
        $securePass = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($user, $securePass)
        
        # 创建PSSession
        $sessionOptions = New-PSSessionOption -OperationTimeout 120000 -IdleTimeout 300000
        
        try {
            $session = New-PSSession -ComputerName $ip -Credential $cred -SessionOption $sessionOptions -ErrorAction Stop
            Write-Host "✅ WinRM连接成功" -ForegroundColor Green
            
            # 执行远程部署
            $deployResult = Invoke-Command -Session $session -ScriptBlock {
                param($LocalZipName, $IP)
                
                Write-Host "开始部署JMeter..." -ForegroundColor Yellow
                
                # 检查文件是否存在
                $zipPath = "C:\temp\$LocalZipName"
                if (!(Test-Path $zipPath)) {
                    return "ERROR: 未找到JMeter文件: $zipPath"
                }
                
                # 解压JMeter
                Write-Host "解压JMeter..." -ForegroundColor Yellow
                $jmeterDir = "C:\jmeter"
                if (Test-Path $jmeterDir) {
                    Remove-Item -Path $jmeterDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                
                try {
                    Expand-Archive -Path $zipPath -DestinationPath $jmeterDir -Force
                } catch {
                    # 备用解压方法
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $jmeterDir)
                }
                
                # 修改配置
                Write-Host "配置JMeter..." -ForegroundColor Yellow
                $jmeterProps = "$jmeterDir\apache-jmeter-5.6.3\bin\jmeter.properties"
                if (Test-Path $jmeterProps) {
                    # 备份原文件
                    Copy-Item $jmeterProps "$jmeterProps.backup" -Force
                    
                    # 读取并修改配置
                    $content = Get-Content $jmeterProps -Raw
                    $content = $content -replace 'server_port=.*', 'server_port=1099'
                    $content = $content -replace 'server\.rmi\.localport=.*', 'server.rmi.localport=1099'
                    $content = $content -replace 'server\.rmi\.ssl\.disable=.*', 'server.rmi.ssl.disable=true'
                    $content = $content -replace '#*\s*java\.rmi\.server\.hostname=.*', "java.rmi.server.hostname=$IP"
                    $content = $content -replace '#*\s*server\.rmi\.port=.*', "server.rmi.port=1099"
                    
                    Set-Content -Path $jmeterProps -Value $content -NoNewline
                }
                
                # 停止已有服务
                Write-Host "停止现有服务..." -ForegroundColor Yellow
                Get-Process -Name "java" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.CommandLine -like "*jmeter*" } | 
                    Stop-Process -Force -ErrorAction SilentlyContinue
                
                # 确保端口1099没有被占用
                Write-Host "检查端口占用..." -ForegroundColor Yellow
                $portProcess = Get-NetTCPConnection -LocalPort 1099 -ErrorAction SilentlyContinue
                if ($portProcess) {
                    Write-Host "端口1099被占用，停止相关进程..." -ForegroundColor Red
                    $portProcess | ForEach-Object {
                        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
                    }
                }
                
                # 创建日志目录
                $logDir = "C:\jmeter\logs"
                if (!(Test-Path $logDir)) {
                    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
                }
                
                # 启动服务 - 使用批处理文件确保正确启动
                Write-Host "启动JMeter服务..." -ForegroundColor Yellow
                $jmeterBinDir = "$jmeterDir\apache-jmeter-5.6.3\bin"
                $jmeterServerBat = "$jmeterBinDir\jmeter-server.bat"
                $logFile = "$logDir\jmeter-server.log"
                
                # 创建启动脚本
                $startScript = @"
@echo off
cd /d "$jmeterBinDir"
echo 启动时间: %date% %time% > "$logFile"
echo Java版本: >> "$logFile"
java -version 2>&1 >> "$logFile"
echo. >> "$logFile"
echo 开始启动JMeter Server... >> "$logFile"
jmeter-server.bat -Djava.rmi.server.hostname=$IP -Dserver.rmi.localport=1099 -Djava.rmi.server.port=1099 -Djava.rmi.dgc.client.gcInterval=3600000 -Djava.rmi.dgc.server.gcInterval=3600000 >> "$logFile" 2>&1
"@
                
                $startScriptPath = "$jmeterBinDir\start-jmeter-server.cmd"
                Set-Content -Path $startScriptPath -Value $startScript -Encoding ASCII
                
                # 以后台方式启动
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "cmd.exe"
                $psi.Arguments = "/c `"$startScriptPath`""
                $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                $psi.CreateNoWindow = $true
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                
                $process = [System.Diagnostics.Process]::Start($psi)
                
                # 等待启动
                Start-Sleep -Seconds 5
                
                # 验证服务
                Write-Host "验证服务状态..." -ForegroundColor Yellow
                
                # 检查进程
                $jmeterProcess = Get-Process -Name "java" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.CommandLine -like "*jmeter-server*" }
                
                # 检查端口
                $portStatus = Get-NetTCPConnection -LocalPort 1099 -ErrorAction SilentlyContinue
                
                # 检查日志文件
                $logExists = Test-Path $logFile
                $logContent = ""
                if ($logExists) {
                    $logContent = Get-Content $logFile -Tail 10 -ErrorAction SilentlyContinue
                }
                
                # 返回验证结果
                $result = @{
                    ProcessExists = [bool]$jmeterProcess
                    ProcessId = if ($jmeterProcess) { $jmeterProcess.Id } else { $null }
                    PortListening = [bool]$portStatus
                    LogFileExists = $logExists
                    LogLines = if ($logContent) { $logContent.Length } else { 0 }
                }
                
                if ($result.ProcessExists) {
                    return "SUCCESS: JMeter服务已启动 (PID: $($result.ProcessId), 日志: $logFile)"
                } else {
                    return "WARNING: 服务可能未正确启动。进程: $($result.ProcessExists), 端口: $($result.PortListening), 日志: $($result.LogFileExists)"
                }
                
            } -ArgumentList $localZipName, $ip
            
            Write-Host "✅ $ip 部署结果: $deployResult" -ForegroundColor Green
            
            # 关闭会话
            Remove-PSSession $session
            
        } catch {
            Write-Host "❌ WinRM连接失败: $_" -ForegroundColor Red
            Write-Host "🔄 回退到SSH方式部署..." -ForegroundColor Yellow
        }
        
    } catch {
        Write-Host "❌ Windows主机 $ip 部署失败: $_" -ForegroundColor Red
    }
}