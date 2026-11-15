<#
.SYNOPSIS
  Edge 黑金图标全自动守护脚本
  - 自动检测所有已安装 Edge 版本目录
  - 自动部署/巡检 ico（桌面/任务栏/开始菜单）与磁贴
  - Edge 更新后自动识别新版本目录并铺黑金磁贴
  - 版本变化 / 文件被重置 / 缓存失效 → 自动修复
  - 支持 -Install 注册计划任务（登录时 + 90分钟轮询）
.PARAMETER Install   注册计划任务 + 首次全量部署（需管理员）
.PARAMETER Uninstall 恢复默认图标并删除计划任务
.PARAMETER Force     跳过版本比较，强制全量替换
.PARAMETER RebuildCache 重建图标缓存（杀 explorer + 删 iconcache）
.PARAMETER MakeIcoOnly 仅生成多尺寸 ico（不做部署）
#>
[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Force,
  [switch]$RebuildCache,
  [switch]$MakeIcoOnly
)

$ErrorActionPreference = 'Stop'

# ---------- 常量与路径 ----------
$TaskName    = 'EdgeBlackGoldIconWatch'
$WorkDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$IcoSrc      = Join-Path $WorkDir 'blackgoldedge.ico'          # 源 ico（用户原版）
$IcoDstDir   = Join-Path $env:USERPROFILE 'EdgeBlackGoldIcon'  # 部署副本目录
$IcoDst      = Join-Path $IcoDstDir 'blackgoldedge.ico'
$VESrcDir    = Join-Path $WorkDir 'VisualElements'             # 源磁贴目录
$StateFile   = Join-Path $WorkDir 'state.json'
$LogFile     = Join-Path $WorkDir 'edge-icon.log'
$IconRef     = "$IcoDst,0"

$AppBase     = 'C:\Program Files (x86)\Microsoft\Edge\Application'
$RegPaths    = @(
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\BLBeacon',
  'HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon'
)
$ExePath     = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

# ---------- 工具函数 ----------
function Write-Log([string]$msg) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
  if (-not [Environment]::UserInteractive) { } # 计划任务静默
}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 获取当前 Edge 版本（注册表 > exe 文件版本）
function Get-EdgeVersion {
  foreach ($k in $RegPaths) {
    try { $v = (Get-ItemProperty $k -ErrorAction Stop).version; if ($v) { return $v } } catch {}
  }
  if (Test-Path $ExePath) { return (Get-Item $ExePath).VersionInfo.FileVersion }
  return $null
}

# 枚举所有已安装版本的 VisualElements 目录
function Get-AllVEDirs {
  Get-ChildItem $AppBase -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    ForEach-Object { Join-Path $_.FullName 'VisualElements' } |
    Where-Object { Test-Path $_ }
}

# 读取/写入状态
function Get-State { if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { $null } }
function Set-State([string]$ver, [string]$action) {
  @{ lastVersion = $ver; lastRun = (Get-Date -Format o); lastAction = $action } |
    ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

# 部署 ICO 副本到 C 盘用户目录（避免沙箱 ACL 导致白纸）
function Deploy-IcoCopy {
  if (-not (Test-Path $IcoDstDir)) { New-Item -ItemType Directory -Path $IcoDstDir -Force | Out-Null }
  if (-not (Test-Path $IcoDst) -or (Get-FileHash $IcoSrc -Algorithm SHA256).Hash -ne (Get-FileHash $IcoDst -Algorithm SHA256).Hash) {
    Copy-Item $IcoSrc $IcoDst -Force
    icacls $IcoDst /reset 2>&1 | Out-Null
    icacls $IcoDst /setintegritylevel M 2>&1 | Out-Null
    Write-Log "ICO 副本已部署/更新: $IcoDst"
  }
}

# 部署/巡检所有版本目录的磁贴
function Deploy-VisualElements {
  param([switch]$ProbeOnly)
  $changed = @()
  $veDirs = Get-AllVEDirs
  foreach ($veDst in $veDirs) {
    foreach ($f in 'Logo.png','SmallLogo.png') {
      $src = Join-Path $VESrcDir $f
      $dst = Join-Path $veDst $f
      if (-not (Test-Path $src)) { continue }
      if ($ProbeOnly) {
        if (-not (Test-Path $dst)) { $changed += "${veDst}\$f (missing)" }
        continue
      }
      try {
        Copy-Item $src $dst -Force
        icacls $dst /reset 2>&1 | Out-Null
        icacls $dst /setintegritylevel M 2>&1 | Out-Null
        $changed += "${veDst}\$f"
      }
      catch {
        Write-Log "VE部署失败 ${dst}: $($_.Exception.Message)"
      }
    }
  }
  [pscustomobject]@{ Changed = $changed }
}

# 替换所有 Edge 快捷方式的图标
function Set-EdgeIcon {
  param([switch]$ProbeOnly)
  $sh = New-Object -ComObject WScript.Shell
  $roots = @(
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs',
    'C:\Users\Public\Desktop',
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch",
    "$env:USERPROFILE\Desktop",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
  ) | Select-Object -Unique

  $found = @(); $changed = @(); $skipped = @()
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $l = $sh.CreateShortcut($_.FullName)
        if ($l.TargetPath -like '*msedge.exe' -or $_.BaseName -match 'Microsoft Edge') {
          $found += $_.FullName
          if ($l.IconLocation -ne $IconRef) {
            if ($ProbeOnly) { $changed += $_.FullName; return }
            $l.IconLocation = $IconRef
            $l.Save()
            $changed += $_.FullName
          }
        }
      } catch { $skipped += "$($_.FullName) ($($_.Exception.Message))" }
    }
  }

  # explorer 锁定 taskbar lnk 时保存会失败：重启 explorer 后重试一次
  if (-not $ProbeOnly -and $skipped.Count -gt 0) {
    Write-Log '部分 lnk 保存失败，重启 explorer 后重试...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    $still = @()
    foreach ($path in $skipped) {
      try {
        $l = $sh.CreateShortcut($path)
        if ($l.IconLocation -ne $IconRef) {
          $l.IconLocation = $IconRef
          $l.Save()
          $changed += $path
        }
      } catch { $still += $path }
    }
    $skipped = $still
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 2
  }
  [pscustomobject]@{ Lnks = $found; Changed = $changed; Skipped = $skipped }
}

# 刷新图标缓存 + 可选重建
function Invoke-IconRefresh {
  Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
  [Win32.Native]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero) # SHCNE_ASSOCCHANGED
  if ($RebuildCache) {
    Write-Log '重建图标缓存: 杀 explorer -> 删 iconcache -> 重启'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    $explorerDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    Get-ChildItem $explorerDir -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:LOCALAPPDATA 'IconCache.db') -Force -ErrorAction SilentlyContinue
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 3
    Write-Log '图标缓存重建完成'
  }
}

# 生成多尺寸 ICO（仅 -MakeIcoOnly 时用）
function New-MultiSizeIco {
  param([string]$Png, [string]$Out, [int[]]$Sizes = @(16,20,24,32,48,64,128,256))
  Add-Type -AssemblyName System.Drawing
  $src = [System.Drawing.Bitmap]::new($Png)
  $frames = New-Object System.Collections.Generic.List[byte[]]
  foreach ($s in $Sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($src, 0, 0, $s, $s)
    $g.Dispose()
    if ($s -ge 128) {
      $ms = New-Object System.IO.MemoryStream
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      $frames.Add($ms.ToArray()); $ms.Dispose()
    } else {
      $r = New-Object System.Drawing.Rectangle(0,0,$s,$s)
      $bd = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $px = New-Object byte[] ($s*$s*4)
      [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0,$px,0,$px.Length)
      $bmp.UnlockBits($bd)
      $flip = New-Object byte[] ($s*$s*4)
      for($y=0;$y -lt $s;$y++) { [Array]::Copy($px, ($s-1-$y)*$s*4, $flip, $y*$s*4, $s*4) }
      $maskRow = [int][Math]::Ceiling($s/32)*4
      $mask = New-Object byte[] ($maskRow*$s)
      $ms = New-Object System.IO.MemoryStream
      $bw = New-Object System.IO.BinaryWriter($ms)
      $bw.Write([UInt32]40); $bw.Write([Int32]$s); $bw.Write([Int32]($s*2))
      $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
      $bw.Write([UInt32]($flip.Length+$mask.Length)); $bw.Write([Int32]0); $bw.Write([Int32]0)
      $bw.Write([UInt32]0); $bw.Write([UInt32]0)
      $bw.Write($flip); $bw.Write($mask)
      $bw.Flush(); $frames.Add($ms.ToArray()); $bw.Dispose(); $ms.Dispose()
    }
    $bmp.Dispose()
  }
  $src.Dispose()
  $fs = [System.IO.File]::Create($Out)
  $bw = New-Object System.IO.BinaryWriter($fs)
  $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$frames.Count)
  $offset = 6 + 16*$frames.Count
  for($i=0;$i -lt $frames.Count;$i++) {
    $s=$Sizes[$i]; $b=if($s -ge 256){0}else{$s}
    $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$frames[$i].Length); $bw.Write([UInt32]$offset)
    $offset += $frames[$i].Length
  }
  foreach($f in $frames){ $bw.Write($f) }
  $bw.Flush(); $bw.Dispose()
}

# ---------- 仅生成 ICO ----------
if ($MakeIcoOnly) {
  New-MultiSizeIco -Png (Join-Path $WorkDir 'logo.png') -Out (Join-Path $WorkDir 'edge-blackgold.ico')
  Write-Log "ICO 生成完成"
  return
}

# ---------- 卸载 ----------
if ($Uninstall) {
  schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
  $sh = New-Object -ComObject WScript.Shell
  foreach ($p in (Set-EdgeIcon -ProbeOnly).Lnks) {
    try { $l=$sh.CreateShortcut($p); $l.IconLocation='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe,0'; $l.Save() } catch {}
  }
  Invoke-IconRefresh
  Write-Log '已卸载：恢复默认图标，删除计划任务'
  return
}

# ---------- 常规运行 ----------
Deploy-IcoCopy  # 确保 C 盘副本存在且哈希一致

$current  = Get-EdgeVersion
$state    = Get-State
$lastVer  = if ($state) { $state.lastVersion } else { $null }

# 判断是否需要全量替换：版本变化 / 首次运行 / 强制
$needFull = $Force -or (-not $lastVer) -or ($current -and $current -ne $lastVer)

if ($needFull) {
  Write-Log ("Edge 版本: {0} (上次: {1}) -> 执行全量替换" -f $current, $lastVer)
  $rLnk = Set-EdgeIcon
  $rVE  = Deploy-VisualElements
  foreach ($c in $rLnk.Changed) { Write-Log "  已替换 lnk: $c" }
  foreach ($c in $rVE.Changed)   { Write-Log "  磁贴已更新: $c" }
  foreach ($s in $rLnk.Skipped)  { Write-Log "  跳过(权限?): $s" }
  if ($rLnk.Changed.Count -gt 0 -or $rVE.Changed.Count -gt 0) { Invoke-IconRefresh }
  Set-State -ver $current -action "full: lnk $($rLnk.Changed.Count), ve $($rVE.Changed.Count), skipped $($rLnk.Skipped.Count)"
}
else {
  # 幂等巡检：被 EdgeUpdate 重置的 lnk / 磁贴直接修回
  $rLnk = Set-EdgeIcon
  $rVE  = Deploy-VisualElements
  if ($rLnk.Changed.Count -gt 0 -or $rVE.Changed.Count -gt 0) {
    foreach ($c in $rLnk.Changed) { Write-Log "  巡检修复 lnk: $c" }
    foreach ($c in $rVE.Changed)   { Write-Log "  巡检修复磁贴: $c" }
    Invoke-IconRefresh
  }
  Set-State -ver $current -action "idle: lnk $($rLnk.Changed.Count), ve $($rVE.Changed.Count)"
}

# ---------- 安装计划任务 ----------
if ($Install) {
  if (-not (Test-Admin)) { throw '注册计划任务需要管理员权限，请以管理员身份运行 -Install' }
  $ps = (Get-Process -Id $PID).Path
  $action = New-ScheduledTaskAction -Execute $ps `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
  $trg1 = New-ScheduledTaskTrigger -AtLogOn
  $trg2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Minutes 90) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
           -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trg1, $trg2 `
    -Settings $set -RunLevel Highest -Force | Out-Null
  Write-Log "计划任务 $TaskName 注册完成（登录时 + 每 90 分钟）"
  # 首次全量
  $rLnk = Set-EdgeIcon; $rVE = Deploy-VisualElements
  foreach ($c in $rLnk.Changed) { Write-Log "  首次替换: $c" }
  foreach ($c in $rVE.Changed)   { Write-Log "  首次磁贴: $c" }
  if ($rLnk.Changed.Count -gt 0 -or $rVE.Changed.Count -gt 0) { Invoke-IconRefresh }
  Set-State -ver (Get-EdgeVersion) -action "installed: lnk $($rLnk.Changed.Count), ve $($rVE.Changed.Count)"
}