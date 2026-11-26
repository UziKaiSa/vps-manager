param(
  [ValidateSet('Install','Run','Preview','Status')][string]$Action='Install',
  [ValidateRange(1,36500)][int]$Days=180
)
$ErrorActionPreference='Stop'
$TaskName='KaiSa-PurgeOldTrash'
$InstallDirectory=Join-Path $env:LOCALAPPDATA 'KaiSaVpsManager'
$InstallPath=Join-Path $InstallDirectory 'windows-trash-cleanup.ps1'

function Read-DeletionTime([byte[]]$Header) {
  if ($Header.Length -lt 24) { return $null }
  $version=[BitConverter]::ToInt64($Header,0)
  if ($version -ne 1 -and $version -ne 2) { return $null }
  try { return [DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($Header,16)) }
  catch { return $null }
}
function Has-ReparsePoint([string]$Path) {
  $stack=New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($Path)
  $count=0
  while ($stack.Count -gt 0) {
    $current=$stack.Pop();$count++
    if ($count -gt 200000) { return $true }
    $attrs=[IO.File]::GetAttributes($current)
    if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    if (($attrs -band [IO.FileAttributes]::Directory) -ne 0) {
      foreach ($child in [IO.Directory]::GetFileSystemEntries($current)) {$stack.Push($child)}
    }
  }
  return $false
}
function Invoke-TrashRetention([bool]$DryRun) {
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $cutoff=[DateTime]::UtcNow.AddDays(-$Days)
  $removed=0;$retained=0;$invalid=0
  foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {continue}
    $bin=Join-Path $drive.RootDirectory.FullName '$Recycle.Bin'
    $root=Join-Path $bin $sid
    if (-not [IO.Directory]::Exists($root)) {continue}
    if (([IO.File]::GetAttributes($bin) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {$invalid++;continue}
    foreach ($info in Get-ChildItem -LiteralPath $root -Force -Filter '$I*' -File) {
      try {
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {$invalid++;continue}
        $stream=[IO.File]::Open($info.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try {$header=New-Object byte[] 24;$count=$stream.Read($header,0,24)} finally {$stream.Dispose()}
        if ($count -ne 24) {$invalid++;continue}
        $deleted=Read-DeletionTime $header
        if ($null -eq $deleted) {$invalid++;continue}
        if ($deleted -ge $cutoff) {$retained++;continue}
        $payload=Join-Path $root ('$R'+$info.Name.Substring(2))
        if (Test-Path -LiteralPath $payload) {
          if (Has-ReparsePoint $payload) {$invalid++;continue}
          if (-not $DryRun) {Remove-Item -LiteralPath $payload -Recurse -Force}
        }
        if (-not $DryRun) {Remove-Item -LiteralPath $info.FullName -Force}
        $removed++
      } catch {$invalid++;Write-Warning ('Retained an unreadable entry: '+$_.Exception.GetType().Name)}
    }
  }
  [pscustomobject]@{days=$Days;dry_run=$DryRun;matched=$removed;retained=$retained;invalid=$invalid}
}

switch ($Action) {
  'Install' {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run Install from an administrator session.'}
    if (-not $PSCommandPath) {throw 'Save this script to a file before installing.'}
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($InstallPath)) {Copy-Item -LiteralPath $PSCommandPath -Destination $InstallPath -Force}
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$InstallPath+'" -Action Run -Days '+$Days
    $taskAction=New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $nextRun=[DateTime]::Today.AddHours(3).AddMinutes(40)
    if ($nextRun -le [DateTime]::Now) {$nextRun=$nextRun.AddDays(1)}
    $trigger=New-ScheduledTaskTrigger -Daily -At $nextRun
    $trigger.RandomDelay='PT30M'
    # Run only as the current user, with a limited token; never purge other users' bins as SYSTEM.
    $taskPrincipal=New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType S4U -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description ('Permanently remove current-user Recycle Bin entries older than '+$Days+' days; never scan normal folders.') -Force | Out-Null
    Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State
    Invoke-TrashRetention $true
  }
  'Preview' {Invoke-TrashRetention $true}
  'Run' {Invoke-TrashRetention $false}
  'Status' {
    Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State,Principal,Triggers
    Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime,LastTaskResult,NextRunTime
  }
}
