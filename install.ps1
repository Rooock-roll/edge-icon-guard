<#
.SYNOPSIS
  Edge Icon Guard 一键安装脚本
#>
$ErrorActionPreference = 'Stop'
$targetDir = 'C:\EdgeIconGuard'
$sourceDir = $PSScriptRoot

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "请以管理员身份运行此脚本"
    exit 1
}

Write-Host "正在安装到 $targetDir ..."
if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
Copy-Item $sourceDir $targetDir -Recurse -Force

# 注册计划任务
$ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetDir\Update-EdgeIcon.ps1`""
$trg1 = New-ScheduledTaskTrigger -AtLogOn
$trg2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 90) -RepetitionDuration (New-TimeSpan -Days 3650)
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'EdgeBlackGoldIconWatch' -Action $action -Trigger $trg1, $trg2 -Settings $set -RunLevel Highest -Force | Out-Null

# 首次部署
& "$targetDir\Update-EdgeIcon.ps1" -Force -RebuildCache

Write-Host "安装完成！"
