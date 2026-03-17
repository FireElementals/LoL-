# PowerShell 实现修改 LOL 客户端签名并通过提示询问用户输入签名

# 自动获取 LeagueClientUx.exe 的命令行信息
$LeagueClient = Get-CimInstance -Query "SELECT * from Win32_Process WHERE name LIKE 'LeagueClientUx.exe'" | Select-Object -ExpandProperty CommandLine

# 检查是否获取到 LeagueClient 信息
if (-Not $LeagueClient) {
    Write-Output "LeagueClientUx.exe not found. Please make sure LOL is running."
    exit
}

# 输出 LeagueClient 信息供调试
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Output "LeagueClient CommandLine: $LeagueClient"

# 从命令行信息中提取端口和 Token
if ($LeagueClient -match "--app-port=(\d+)") {
    $Port = $matches[1]
} else {
    Write-Output "Failed to extract port from LeagueClientUx.exe command line."
    exit
}

if ($LeagueClient -match "--remoting-auth-token=([a-zA-Z0-9-_]+)") {
    $Token = $matches[1]
} else {
    Write-Output "Failed to extract token from LeagueClientUx.exe command line."
    exit
}

# 输出提取到的端口和 Token 供调试
Write-Output "Extracted Port: $Port"
Write-Output "Extracted Token: $Token"

# 从同目录下的 txt 文件中读取默认签名内容
$DefaultMessage = "这是我的新签名！"

# 从同目录下读取签名内容
$SignatureFilePaths = @("./signature.txt", "./signature")
foreach ($Path in $SignatureFilePaths) {
    if (Test-Path $Path) {
        $NewStatusMessage = Get-Content $Path -Raw -Encoding UTF8 | Out-String
        
        Write-Output "Signature loaded from file: $Path"
        break
    }
}

# 如果没有找到文件，则使用默认签名
if (-Not $NewStatusMessage) {
    $NewStatusMessage = $DefaultMessage
}


# 对 Token 进行 Base64 编码
$AuthString = "riot:$Token"
$EncodedToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AuthString))

# 构建请求信息（手动构建 JSON 字符串）
$Url = "https://127.0.0.1:$Port/lol-chat/v1/me"
$Headers = @{ "Authorization" = "Basic $EncodedToken" }
$Body = @{ "statusMessage" = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($NewStatusMessage)) } | ConvertTo-Json -Depth 3

# 忽略 SSL 证书错误
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# 发送 PUT 请求
try {
    $Response = Invoke-RestMethod -Uri $Url -Method Put -Headers $Headers -Body $Body -ContentType 'application/json; charset=utf-8'
    Write-Output 'Successfully updated status message!'
} catch {
    Write-Output ('Failed to update status message: ' + $_.Exception.Message)
}
