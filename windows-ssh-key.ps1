param(
    [Alias('KeyName')]
    [string]$KeyNameSuffix,

    [string]$Comment = 'vps-manager',

    [switch]$NoPassphrase
)

$ErrorActionPreference = 'Stop'

$defaultKeyNameSuffix = 'vps-manager'
if ([string]::IsNullOrWhiteSpace($KeyNameSuffix)) {
    $inputKeyNameSuffix = Read-Host "密钥文件名后缀（将生成 id_ed25519_后缀）[$defaultKeyNameSuffix]"
    $KeyNameSuffix = if ([string]::IsNullOrWhiteSpace($inputKeyNameSuffix)) {
        $defaultKeyNameSuffix
    }
    else {
        $inputKeyNameSuffix.Trim()
    }
}

if ($KeyNameSuffix -notmatch '^[A-Za-z0-9._-]+$' -or
    $KeyNameSuffix -in @('.', '..') -or
    $KeyNameSuffix.Length -gt 80) {
    throw '密钥文件名后缀无效。只能使用英文字母、数字、点、下划线和连字符，最长 80 个字符。'
}
$keyFileName = "id_ed25519_${KeyNameSuffix}"

$sshKeygen = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
if (-not $sshKeygen) {
    throw '未找到 ssh-keygen.exe。请先在 Windows“可选功能”中安装 OpenSSH 客户端。'
}

$sshDirectory = Join-Path $env:USERPROFILE '.ssh'
$privateKeyPath = Join-Path $sshDirectory $keyFileName
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

$configureShortcut = Read-Host '是否配置 SSH 快捷名称（以后可使用 ssh 名称连接）[y/N]'
if ($configureShortcut -match '^(y|yes)$') {
    $sshConfigPath = Join-Path $sshDirectory 'config'
    while ($true) {
        $shortcutNameInput = Read-Host "SSH 快捷名称 [$KeyNameSuffix]"
        $shortcutName = if ([string]::IsNullOrWhiteSpace($shortcutNameInput)) {
            $KeyNameSuffix
        }
        else {
            $shortcutNameInput.Trim()
        }
        if ($shortcutName -notmatch '^[A-Za-z0-9._-]+$' -or
            $shortcutName -in @('.', '..')) {
            Write-Warning 'SSH 快捷名称无效。只能使用英文字母、数字、点、下划线和连字符。'
            continue
        }

        $shortcutExists = $false
        if (Test-Path -LiteralPath $sshConfigPath) {
            foreach ($line in Get-Content -LiteralPath $sshConfigPath) {
                if ($line -match '^\s*Host\s+(.+?)\s*$') {
                    $hostAliases = $Matches[1] -split '\s+'
                    if ($hostAliases -contains $shortcutName) {
                        $shortcutExists = $true
                        break
                    }
                }
            }
        }
        if (-not $shortcutExists) {
            break
        }

        Write-Warning "SSH 快捷名称 $shortcutName 已存在，不会覆盖已有 Host。"
        $retryShortcut = Read-Host '是否重新输入其他快捷名称 [Y/n]'
        if (-not [string]::IsNullOrWhiteSpace($retryShortcut) -and
            $retryShortcut -notmatch '^(y|yes)$') {
            Write-Host '已取消写入 SSH 快捷配置，现有配置没有变化。'
            return
        }
    }

    do {
        $shortcutHost = (Read-Host '服务器 IP 或域名').Trim()
        if ([string]::IsNullOrWhiteSpace($shortcutHost) -or
            $shortcutHost -match '\s' -or
            $shortcutHost.Contains('/')) {
            Write-Warning '服务器地址不能为空，也不能包含空格或斜杠。'
            $shortcutHost = ''
        }
    } while ([string]::IsNullOrWhiteSpace($shortcutHost))

    $shortcutUserInput = Read-Host 'SSH 用户名 [root]'
    $shortcutUser = if ([string]::IsNullOrWhiteSpace($shortcutUserInput)) {
        'root'
    }
    else {
        $shortcutUserInput.Trim()
    }
    if ($shortcutUser -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'SSH 用户名格式无效。'
    }

    $shortcutPortInput = Read-Host 'SSH 端口 [22]'
    $shortcutPort = 22
    if (-not [string]::IsNullOrWhiteSpace($shortcutPortInput)) {
        if (-not [int]::TryParse($shortcutPortInput, [ref]$shortcutPort) -or
            $shortcutPort -lt 1 -or $shortcutPort -gt 65535) {
            throw 'SSH 端口必须在 1-65535 之间。'
        }
    }

    $identityPathForConfig = $privateKeyPath.Replace('\', '/')
    $shortcutBlock = @"
Host $shortcutName
    HostName $shortcutHost
    User $shortcutUser
    Port $shortcutPort
    IdentityFile "$identityPathForConfig"
    IdentitiesOnly yes
"@
    $separator = ''
    if ((Test-Path -LiteralPath $sshConfigPath) -and
        (Get-Item -LiteralPath $sshConfigPath).Length -gt 0) {
        $existingConfig = [IO.File]::ReadAllText($sshConfigPath)
        if (-not $existingConfig.EndsWith("`n")) {
            $separator = "`r`n"
        }
    }
    [IO.File]::AppendAllText(
        $sshConfigPath,
        $separator + $shortcutBlock + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "SSH 快捷名称已写入：$sshConfigPath" -ForegroundColor Green
    Write-Host "以后可以直接连接：ssh $shortcutName"
}
