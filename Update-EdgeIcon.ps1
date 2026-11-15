<#
.SYNOPSIS
  Edge 黑金图标全自动守护脚本（跨机器通用版）
.DESCRIPTION
  - 自动探测所有 Edge 通道（Stable/Beta/Dev/Canary）与所有已安装版本目录
  - 自动部署/巡检 ico（桌面/任务栏/开始菜单）与开始菜单磁贴
  - Edge 更新后自动识别新版本目录并铺黑金磁贴
  - 版本变化 / 文件被重置 / 缓存失效 → 自动修复
  - 支持 -Install 注册计划任务（登录时 + 15 分钟轮询）
  - 支持 -Diagnose 输出环境自检报告
.PARAMETER Install      注册计划任务 + 首次全量部署（需管理员）
.PARAMETER Uninstall    恢复默认图标并删除计划任务（需管理员）
.PARAMETER Force        跳过版本比较，强制全量替换
.PARAMETER RebuildCache 重建图标缓存（杀 explorer + 删 iconcache）
.PARAMETER Diagnose     仅输出环境自检信息，不做任何修改
.PARAMETER MakeIcoOnly  仅生成多尺寸 ico（不做部署）
.PARAMETER Interval     巡检间隔（分钟），默认 30
#>
[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Force,
  [switch]$RebuildCache,
  [switch]$Diagnose,
  [switch]$MakeIcoOnly,
  [int]$Interval = 30
)

$ErrorActionPreference = 'Stop'

# ---------- 常量与路径 ----------
$TaskName  = 'EdgeBlackGoldIconWatch'
$WorkDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$IcoSrc    = Join-Path $WorkDir 'blackgoldedge.ico'          # 源 ico（用户原版）
$IcoDstDir = Join-Path $env:USERPROFILE 'EdgeBlackGoldIcon'  # 部署副本目录
$IcoDst    = Join-Path $IcoDstDir 'blackgoldedge.ico'
$VESrcDir  = Join-Path $WorkDir 'VisualElements'             # 源磁贴目录
$IconRef   = "$IcoDst,0"
$TileFiles = @('Logo.png','SmallLogo.png')

# 已知文件夹（尊重 OneDrive / 组策略重定向；环境变量为空时兜底）
function Get-KnownFolder([string]$name, [string]$fallback) {
  $p = $null
  try { $p = [Environment]::GetFolderPath($name) } catch {}
  if (-not $p -and $fallback) { $p = $fallback }
  return $p
}
$DesktopDir     = Get-KnownFolder 'Desktop'                "$env:USERPROFILE\Desktop"
$CommonDesktop  = Get-KnownFolder 'CommonDesktopDirectory'  "$env:PUBLIC\Desktop"
$StartMenuDir   = Get-KnownFolder 'StartMenu'               "$env:APPDATA\Microsoft\Windows\Start Menu"
$CommonStartMenu = Get-KnownFolder 'CommonStartMenu'        "$env:ProgramData\Microsoft\Windows\Start Menu"
$AppDataDir     = Get-KnownFolder 'ApplicationData'         "$env:APPDATA"

# 状态/日志目录：优先脚本目录，不可写则退回 LOCALAPPDATA
function Test-WritableDir([string]$dir) {
  try {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $probe = Join-Path $dir ('.wtest_' + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'x')
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    return $true
  } catch { return $false }
}
$StateDir = if (Test-WritableDir $WorkDir) { $WorkDir } else {
  $alt = Join-Path $env:LOCALAPPDATA 'EdgeIconGuard'
  if (Test-WritableDir $alt) { $alt } else { $env:TEMP }
}
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'edge-icon.log'

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- Edge 安装探测（跨机器核心） ----------
function Get-EdgeAppBases {
  $candidates = New-Object System.Collections.Generic.List[string]

  # 1) EdgeUpdate Clients 注册表（最准，含通道信息）
  foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
                    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients') {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
      # 排除 WebView2 Runtime（location 指向 EdgeWebView\Application，无 msedge.exe）
      if ($p.name -like 'Microsoft Edge*' -and $p.name -notlike '*WebView*' -and $p.location) {
        $candidates.Add(($p.location -replace '/', '\').TrimEnd('\'))
      }
    }
  }

  # 2) App Paths（msedge.exe）
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe') {
    if (-not (Test-Path $k)) { continue }
    $exe = (Get-ItemProperty $k -ErrorAction SilentlyContinue).'(default)'
    if ($exe) { $candidates.Add((Split-Path -Parent $exe.Trim('"'))) }
  }

  # 3) 常见落盘路径（覆盖 32 位系统 / 各通道 / 用户级安装）
  foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
    if (-not $pf) { continue }
    foreach ($ch in 'Edge','Edge Beta','Edge Dev','Edge SxS','Edge Canary') {
      $candidates.Add((Join-Path $pf "Microsoft\$ch\Application"))
    }
  }

  # 去重 + 校验 msedge.exe 真实存在
  $seen = @{}
  foreach ($c in $candidates) {
    if (-not $c -or $seen.ContainsKey($c.ToLower())) { continue }
    $seen[$c.ToLower()] = $true
    if (Test-Path (Join-Path $c 'msedge.exe')) { Write-Output $c }
  }
}

$EdgeAppBases = @(Get-EdgeAppBases)   # 可能为空（未安装 Edge）

# 枚举所有已安装版本的 VisualElements 目录（全部通道 × 全部版本）
function Get-AllVEDirs {
  foreach ($base in $EdgeAppBases) {
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
      ForEach-Object { Join-Path $_.FullName 'VisualElements' } |
      Where-Object { Test-Path $_ }
  }
}

# 取主通道（Stable 优先，否则第一个）与其 exe
$MainBase = if ($EdgeAppBases.Count -gt 0) {
  ($EdgeAppBases | Where-Object { $_ -notmatch 'Beta|Dev|SxS|Canary' } | Select-Object -First 1)
} else { $null }
if (-not $MainBase -and $EdgeAppBases.Count -gt 0) { $MainBase = $EdgeAppBases[0] }
# 没探测到 Edge 时不猜路径（避免误把别的程序当 Edge）
$ExePath = if ($MainBase) { Join-Path $MainBase 'msedge.exe' } else { $null }

# ---------- 工具函数 ----------
$script:LastLoggedMsg = $null
function Write-Log([string]$msg) {
  if ($msg -eq $script:LastLoggedMsg) { return }   # 同一条连发去重
  $script:LastLoggedMsg = $msg
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# 版本号比较键（1.2.3.4 → 可排序整数）
function Get-VersionKey([string]$v) {
  if ($v -notmatch '^(\d+)\.(\d+)\.(\d+)\.(\d+)') { return [long]0 }
  return [long]$Matches[1] * 1000000000 + [long]$Matches[2] * 1000000 + [long]$Matches[3] * 1000 + [long]$Matches[4]
}

# 获取当前 Edge 版本：注册表 BLBeacon → 最高版本目录 → exe 文件版本
function Get-EdgeVersion {
  foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\BLBeacon',
                 'HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon') {
    try { $v = (Get-ItemProperty $k -ErrorAction Stop).version; if ($v) { return $v } } catch {}
  }
  $dirs = foreach ($base in $EdgeAppBases) {
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
      Select-Object -ExpandProperty Name
  }
  $best = $dirs | Sort-Object { Get-VersionKey $_ } | Select-Object -Last 1
  if ($best) { return $best }
  if ($ExePath -and (Test-Path $ExePath)) { return (Get-Item $ExePath).VersionInfo.FileVersion }
  return $null
}

function Get-State {
  if (Test-Path $StateFile) {
    try { Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $null }
  } else { $null }
}
function Set-State([string]$ver, [string]$action, [string]$veSig, [string]$failSig) {
  try {
    @{ lastVersion = $ver; lastRun = (Get-Date -Format o); lastAction = $action; veSig = $veSig; failSig = $failSig } |
      ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
  } catch { Write-Log "状态写入失败: $($_.Exception.Message)" }
}

# 磁贴目录指纹（检测 Edge 更新替换文件 / 目录增减）
function Get-VESignature {
  $parts = foreach ($d in (Get-AllVEDirs | Sort-Object)) {
    foreach ($f in $TileFiles) {
      $p = Join-Path $d $f
      if (Test-Path $p) {
        $i = Get-Item $p
        "$($d.ToLower())|$f|$($i.Length)|$($i.LastWriteTimeUtc.Ticks)"
      } else { "$($d.ToLower())|$f|missing" }
    }
  }
  $joined = ($parts -join "`n")
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined)) | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

# ---------- 仅自检 ----------
if ($Diagnose) {
  Write-Output '================ Edge Icon Guard 环境自检 ================'
  Write-Output ("脚本目录     : {0}" -f $WorkDir)
  Write-Output ("状态/日志目录: {0}" -f $StateDir)
  Write-Output ("管理员权限   : {0}" -f (Test-Admin))
  Write-Output ("PowerShell   : {0}" -f $PSVersionTable.PSVersion)
  Write-Output ("64 位系统    : {0}" -f [Environment]::Is64BitOperatingSystem)
  Write-Output ("桌面         : {0}" -f $DesktopDir)
  Write-Output ("公共桌面     : {0}" -f $CommonDesktop)
  Write-Output ("开始菜单     : {0}" -f $StartMenuDir)
  Write-Output ''
  Write-Output '--- Edge 安装探测 ---'
  if ($EdgeAppBases.Count -eq 0) {
    Write-Output '  ! 未检测到任何 Edge 安装（msedge.exe 不存在）'
  } else {
    foreach ($b in $EdgeAppBases) {
      $ver = (Get-ChildItem $b -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
              Select-Object -ExpandProperty Name) -join ', '
      Write-Output ("  + {0}" -f $b)
      Write-Output ("      版本目录: {0}" -f ($ver -replace '^$','(无)'))
    }
  }
  Write-Output ("  当前版本   : {0}" -f (Get-EdgeVersion))
  Write-Output ''
  Write-Output '--- 磁贴目标目录 ---'
  $ve = @(Get-AllVEDirs)
  if ($ve.Count -eq 0) { Write-Output '  ! 未找到任何 VisualElements 目录' }
  else { foreach ($d in $ve) { Write-Output ("  - {0}" -f $d) } }
  Write-Output ''
  Write-Output '--- 源文件 ---'
  foreach ($f in @($IcoSrc, (Join-Path $VESrcDir 'Logo.png'), (Join-Path $VESrcDir 'SmallLogo.png'))) {
    $ok = Test-Path $f
    Write-Output ("  {0} {1}" -f $(if($ok){'[OK]'}else{'[--]'}), $f)
  }
  Write-Output ''
  Write-Output '--- 计划任务 ---'
  $t = schtasks /Query /TN $TaskName /FO LIST 2>$null
  if ($LASTEXITCODE -eq 0) { $t | Select-Object -First 6 } else { Write-Output '  (未注册)' }
  Write-Output '=========================================================='
  return
}

# ---------- 仅生成 ICO ----------
if ($MakeIcoOnly) {
  . {
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
  } -Png (Join-Path $WorkDir 'logo.png') -Out (Join-Path $WorkDir 'edge-blackgold.ico')
  Write-Log 'ICO 生成完成'
  Write-Output ("ICO 已生成: {0}" -f (Join-Path $WorkDir 'edge-blackgold.ico'))
  return
}

# ---------- 部署 ICO 副本（避免沙箱 ACL 导致白纸） ----------
function Deploy-IcoCopy {
  if (-not (Test-Path $IcoSrc)) { Write-Log "源 ICO 不存在: $IcoSrc"; return $false }
  if (-not (Test-Path $IcoDstDir)) { New-Item -ItemType Directory -Path $IcoDstDir -Force | Out-Null }
  $needCopy = $true
  if (Test-Path $IcoDst) {
    try {
      $a = (Get-FileHash $IcoSrc -Algorithm SHA256).Hash
      $b = (Get-FileHash $IcoDst -Algorithm SHA256).Hash
      if ($a -eq $b) { $needCopy = $false }
    } catch {}
  }
  if ($needCopy) {
    Copy-Item $IcoSrc $IcoDst -Force
    icacls $IcoDst /reset 2>&1 | Out-Null
    icacls $IcoDst /setintegritylevel M 2>&1 | Out-Null
    Write-Log "ICO 副本已部署/更新: $IcoDst"
  }
  return $true
}

# ---------- 部署/巡检所有版本目录的磁贴 ----------
function Deploy-VisualElements {
  param([switch]$ProbeOnly)
  $changed = @(); $failed = @()
  $veDirs = @(Get-AllVEDirs)
  if ($veDirs.Count -eq 0) {
    Write-Log '未找到任何 VisualElements 目录（Edge 可能未安装）'
    return [pscustomobject]@{ Changed = $changed; Failed = $failed }
  }

  foreach ($veDst in $veDirs) {
    foreach ($f in $TileFiles) {
      $srcL = Join-Path $VESrcDir $f
      $dst = Join-Path $veDst $f
      if (-not (Test-Path $srcL)) { continue }
      if ($ProbeOnly) {
        if (-not (Test-Path $dst)) { $changed += "${veDst}\$f (missing)" }
        continue
      }
      # 内容一致就跳过（避免每次巡检无谓写盘 / 重置时间戳）
      if (Test-Path $dst) {
        try {
          $srcLen = (Get-Item $srcL).Length
          $dstLen = (Get-Item $dst).Length
          if ($srcLen -eq $dstLen) {
            $hs = (Get-FileHash $srcL -Algorithm SHA256).Hash
            $hd = (Get-FileHash $dst -Algorithm SHA256).Hash
            if ($hs -eq $hd) { continue }
          }
        } catch {}
      }
      try {
        Copy-Item $srcL $dst -Force
        icacls $dst /reset 2>&1 | Out-Null
        icacls $dst /setintegritylevel M 2>&1 | Out-Null
        $changed += "${veDst}\$f"
      }
      catch {
        $failed += "$dst :: $($_.Exception.Message)"
      }
    }
  }
  if ($failed.Count -gt 0) {
    Write-Verbose ("VE 部署失败 {0} 个文件" -f $failed.Count)
  }
  return [pscustomobject]@{ Changed = $changed; Failed = $failed }
}

# ---------- 替换所有 Edge 快捷方式图标 ----------
function Set-EdgeIcon {
  param([switch]$ProbeOnly)
  $sh = New-Object -ComObject WScript.Shell
  $roots = @(
    (Join-Path $CommonStartMenu 'Programs'),
    $CommonDesktop,
    (Join-Path $AppDataDir 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
    (Join-Path $AppDataDir 'Microsoft\Internet Explorer\Quick Launch'),
    $DesktopDir,
    (Join-Path $StartMenuDir 'Programs')
  ) | Where-Object { $_ } | Select-Object -Unique

  $found = @(); $changed = @(); $failedPaths = @(); $failedMsg = @()
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
      $lnk = $_.FullName
      try {
        $l = $sh.CreateShortcut($lnk)
        if ($l.TargetPath -like '*msedge.exe' -or $_.BaseName -match 'Microsoft Edge') {
          $found += $lnk
          if ($l.IconLocation -ne $IconRef) {
            if ($ProbeOnly) { $changed += $lnk; return }
            $l.IconLocation = $IconRef
            $l.Save()
            $changed += $lnk
          }
        }
      } catch {
        $failedPaths += $lnk
        $failedMsg += "$lnk :: $($_.Exception.Message)"
      }
    }
  }

  # explorer 锁定 taskbar lnk 时保存会失败：重启 explorer 后按纯路径重试一次
  if (-not $ProbeOnly -and $failedPaths.Count -gt 0) {
    Write-Log '部分 lnk 保存失败，重启 explorer 后重试...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    $stillPaths = @(); $stillMsg = @()
    foreach ($p in $failedPaths) {
      try {
        $l = $sh.CreateShortcut($p)
        if ($l.IconLocation -ne $IconRef) {
          $l.IconLocation = $IconRef
          $l.Save()
          $changed += $p
        }
      } catch { $stillPaths += $p; $stillMsg += "$p :: $($_.Exception.Message)" }
    }
    $failedPaths = $stillPaths; $failedMsg = $stillMsg
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 2
  }
  return [pscustomobject]@{ Lnks = $found; Changed = $changed; Failed = $failedMsg }
}

# ---------- 刷新图标缓存 ----------
function Invoke-IconRefresh {
  if (-not ('Win32.Native' -as [type])) {
    Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
  }
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

# ---------- 卸载（需管理员） ----------
if ($Uninstall) {
  if (-not (Test-Admin)) {
    Write-Output '注册计划任务删除需要管理员权限，请右键「以管理员身份运行」后重试。'
    throw '卸载需要管理员权限'
  }
  schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
  $sh = New-Object -ComObject WScript.Shell
  # 恢复默认图标：优先用探测到的 msedge.exe；否则退回该 lnk 自身的 TargetPath
  # （注意 IconLocation 不能设为 ''，WScript.Shell 会抛 Value does not fall within the expected range.）
  foreach ($p in (Set-EdgeIcon -ProbeOnly).Lnks) {
    try {
      $l = $sh.CreateShortcut($p)
      $defIcon = if ($ExePath -and (Test-Path $ExePath)) { "$ExePath,0" }
                 elseif ($l.TargetPath) { "$($l.TargetPath),0" }
                 else { $null }
      if ($defIcon) { $l.IconLocation = $defIcon; $l.Save() }
    } catch {}
  }
  Invoke-IconRefresh
  Write-Log '已卸载：恢复默认图标，删除计划任务'
  Write-Output '已卸载：快捷方式图标已恢复默认，计划任务已删除。'
  return
}

# ---------- 安装前先校验权限（早失败，避免做一半） ----------
if ($Install -and -not (Test-Admin)) {
  Write-Output '安装需要管理员权限（写 Program Files、注册计划任务）。'
  Write-Output '请右键「以管理员身份运行」PowerShell 后重试。'
  throw '安装需要管理员权限'
}

# ---------- 常规运行 ----------
$icoReady = Deploy-IcoCopy

$current = Get-EdgeVersion
$state   = Get-State
$lastVer = if ($state) { $state.lastVersion } else { $null }
$lastSig = if ($state -and $state.PSObject.Properties['veSig']) { $state.veSig } else { $null }
$lastFail = if ($state -and $state.PSObject.Properties['failSig']) { $state.failSig } else { '' }
$curSig  = Get-VESignature

# 失败签名：同样的失败不重复刷日志（交接每日巡检 N 次）
function Get-FailSig($items) {
  if (-not $items -or $items.Count -eq 0) { return '' }
  $s = ($items -join '|')
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,16) }
  finally { $sha.Dispose() }
}

# 需要全量替换的情形：强制 / 首次 / Edge 版本变化 / 磁贴指纹变化（Edge 更新重置了文件）
$needFull = $Force -or
            (-not $lastVer) -or
            ($current -and $current -ne $lastVer) -or
            ($lastSig -and $curSig -and $lastSig -ne $curSig)

$allFailed = @()
if ($needFull) {
  Write-Log ("Edge 版本: {0} (上次: {1}) -> 执行全量替换" -f $current, $lastVer)
  $rLnk = Set-EdgeIcon
  $rVE  = Deploy-VisualElements
  foreach ($c in $rLnk.Changed) { Write-Log "  已替换 lnk: $c" }
  foreach ($c in $rVE.Changed)  { Write-Log "  磁贴已更新: $c" }
  $allFailed = @($rLnk.Failed) + @($rVE.Failed)
  if ($rLnk.Changed.Count -gt 0 -or $rVE.Changed.Count -gt 0) { Invoke-IconRefresh }
  $failSig = Get-FailSig $allFailed
  if ($failSig -and $failSig -ne $lastFail) {
    foreach ($s in @($rLnk.Failed) + @($rVE.Failed) | Select-Object -First 3) { Write-Log "  失败: $s" }
    if ($allFailed.Count -gt 3) { Write-Log ("  ... 共 {0} 个失败" -f $allFailed.Count) }
  }
  Set-State -ver $current -veSig (Get-VESignature) -failSig $failSig `
    -action ("full: lnk {0}, ve {1}, fail {2}" -f $rLnk.Changed.Count, $rVE.Changed.Count, $allFailed.Count)
} else {
  # 幂等巡检：被 EdgeUpdate 重置的 lnk / 磁贴直接修回
  $rLnk = Set-EdgeIcon
  $rVE  = Deploy-VisualElements
  if ($rLnk.Changed.Count -gt 0 -or $rVE.Changed.Count -gt 0) {
    foreach ($c in $rLnk.Changed) { Write-Log "  巡检修复 lnk: $c" }
    foreach ($c in $rVE.Changed)  { Write-Log "  巡检修复磁贴: $c" }
    Invoke-IconRefresh
  }
  $allFailed = @($rLnk.Failed) + @($rVE.Failed)
  $failSig = Get-FailSig $allFailed
  if ($failSig -and $failSig -ne $lastFail) {
    foreach ($s in @($rLnk.Failed) + @($rVE.Failed) | Select-Object -First 3) { Write-Log "  失败: $s" }
    if ($allFailed.Count -gt 3) { Write-Log ("  ... 共 {0} 个失败" -f $allFailed.Count) }
  }
  Set-State -ver $current -veSig (Get-VESignature) -failSig $failSig `
    -action ("idle: lnk {0}, ve {1}, fail {2}" -f $rLnk.Changed.Count, $rVE.Changed.Count, $allFailed.Count)
}

# ---------- 安装计划任务 ----------
if ($Install) {
  if ($EdgeAppBases.Count -eq 0) { Write-Log '警告: 未检测到 Edge 安装，图标可能无法生效' }

  # 固定用系统 PowerShell 5.1（每台 Windows 都有，避免别的机器没装 PS7）
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path $psExe)) { $psExe = (Get-Process -Id $PID).Path }

  $scriptPath = Join-Path $WorkDir 'Update-EdgeIcon.ps1'
  $minutes = [Math]::Max(1, $Interval)
  $action = New-ScheduledTaskAction -Execute $psExe `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
  $trg1 = New-ScheduledTaskTrigger -AtLogOn
  $trg2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $minutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
           -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trg1, $trg2 `
    -Settings $set -RunLevel Highest -Force | Out-Null
  Write-Log "计划任务 $TaskName 注册完成（登录时 + 每 $minutes 分钟巡检）"

  # 首次全量
  $rLnk = Set-EdgeIcon; $rVE = Deploy-VisualElements
  foreach ($c in $rLnk.Changed) { Write-Log "  首次替换: $c" }
  foreach ($c in $rVE.Changed)  { Write-Log "  首次磁贴: $c" }
  if ($rLnk.Changed.Count -gt 0 -or $rVE.Changed.Count -gt 0) { Invoke-IconRefresh }
  Set-State -ver (Get-EdgeVersion) -veSig (Get-VESignature) -failSig '' `
    -action ("installed: lnk {0}, ve {1}" -f $rLnk.Changed.Count, $rVE.Changed.Count)
  Write-Output ("安装完成。计划任务: {0} | 巡检间隔 {1} 分钟 | lnk 替换 {2} 个 | 磁贴替换 {3} 个" `
    -f $TaskName, $minutes, $rLnk.Changed.Count, $rVE.Changed.Count)
}
