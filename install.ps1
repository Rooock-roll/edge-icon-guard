<#
.SYNOPSIS
  Edge Icon Guard 一键安装脚本
.DESCRIPTION
  把脚本与素材复制到 C:\EdgeIconGuard，然后调用主脚本的 -Install 完成
  首次全量部署 + 注册计划任务（登录时触发 + 每 15 分钟巡检）。
  必须以管理员身份运行。
#>
$ErrorActionPreference = 'Stop'

$targetDir = 'C:\EdgeIconGuard'
$sourceDir = $PSScriptRoot

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '请以管理员身份运行此脚本（右键 PowerShell -> 以管理员身份运行）' -ForegroundColor Red
    exit 1
}

Write-Host "正在安装到 $targetDir ..." -ForegroundColor Cyan

# 只复制运行所需文件（不复制 .git / 日志 / 状态 / 临时测试文件）
if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
foreach ($f in @('Update-EdgeIcon.ps1', 'blackgoldedge.ico', 'logo.png', 'README.md')) {
    $src = Join-Path $sourceDir $f
    if (Test-Path $src) { Copy-Item $src $targetDir -Force }
}
$veSrc = Join-Path $sourceDir 'VisualElements'
if (Test-Path $veSrc) {
    $veDst = Join-Path $targetDir 'VisualElements'
    if (-not (Test-Path $veDst)) { New-Item -ItemType Directory -Path $veDst -Force | Out-Null }
    Copy-Item (Join-Path $veSrc '*.png') $veDst -Force -ErrorAction SilentlyContinue
}

# 交给主脚本完成：注册计划任务 + 首次全量部署
& (Join-Path $targetDir 'Update-EdgeIcon.ps1') -Install

$mainPs1 = Join-Path $targetDir 'Update-EdgeIcon.ps1'
Write-Host ''
Write-Host "安装完成！脚本目录: $targetDir" -ForegroundColor Green
Write-Host ("查看运行日志: {0}" -f (Join-Path $targetDir 'edge-icon.log')) -ForegroundColor DarkGray
Write-Host ("环境自检:     powershell -ExecutionPolicy Bypass -File `"{0}`" -Diagnose" -f $mainPs1) -ForegroundColor DarkGray
