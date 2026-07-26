param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$KeyName = 'vps-manager-ed25519',

    [string]$Comment = 'vps-manager',

    [switch]$NoPassphrase
)

$ErrorActionPreference = 'Stop'

$sshKeygen = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
if (-not $sshKeygen) {
    throw '未找到 ssh-keygen.exe。请先在 Windows“可选功能”中安装 OpenSSH 客户端。'
}

$sshDirectory = Join-Path $env:USERPROFILE '.ssh'
$privateKeyPath = Join-Path $sshDirectory $KeyName
$publicKeyPath = "$privateKeyPath.pub"

New-Item -ItemType Directory -Force -Path $sshDirectory | Out-Null

if ((Test-Path -LiteralPath $privateKeyPath) -or
    (Test-Path -LiteralPath $publicKeyPath)) {
    throw "密钥文件已经存在，已停止以避免覆盖：$privateKeyPath"
}

Write-Host "即将生成 Ed25519 SSH 密钥："
Write-Host "  私钥：$privateKeyPath"
Write-Host "  公钥：$publicKeyPath"
Write-Host ''
Write-Host '接下来可设置私钥密码；直接按回车表示不设置。'

$arguments = @(
    '-t', 'ed25519',
    '-a', '64',
    '-f', $privateKeyPath,
    '-C', $Comment
)
if ($NoPassphrase) {
    # Windows PowerShell 5.1 drops a plain empty native argument; two quotes preserve it.
    $arguments += @('-N', '""')
}

& $sshKeygen.Source @arguments

if ($LASTEXITCODE -ne 0) {
    throw "ssh-keygen 执行失败，退出码：$LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $privateKeyPath) -or
    -not (Test-Path -LiteralPath $publicKeyPath)) {
    throw 'ssh-keygen 没有生成预期的公钥和私钥文件。'
}

Write-Host ''
Write-Host 'SSH 密钥生成完成。' -ForegroundColor Green
Write-Host "私钥：$privateKeyPath"
Write-Host "公钥：$publicKeyPath"
Write-Host ''
Write-Host '公钥内容：'
Get-Content -LiteralPath $publicKeyPath
Write-Host ''
Write-Warning '私钥不要发送给任何人；需要提供给服务器或脚本的只能是 .pub 公钥内容。'
