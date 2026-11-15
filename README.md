# Edge Icon Guard 🛡️

Edge 浏览器黑金主题图标自动守护工具 —— **Edge 一更新，图标自动变回黑金**。

## ✨ 功能特性

- **桌面 / 任务栏 / 开始菜单快捷方式** → 统一替换为黑金漩涡图标
- **开始菜单磁贴** → 大磁贴、小磁贴全覆盖黑金主题
- **Edge 更新自动跟随** → 自动探测新版本目录并重新铺设黑金磁贴
- **跨机器通用** → 自动识别 Edge 安装位置（Stable / Beta / Dev / Canary、Program Files / Program Files (x86) / 用户级安装）
- **自愈巡检** → 登录时 + 每 15 分钟巡检，磁贴被重置 / 缺失 / 快捷方式被覆盖都会自动修回
- **零依赖** → 只需要系统自带的 Windows PowerShell 5.1，不需要装 PowerShell 7
- **白纸修复** → 自动规避 ACL 导致的图标白纸问题

## 📦 安装

### 方式一：一键安装（推荐）

1. 下载并解压到任意目录（如 `C:\EdgeIconGuard`）
2. 右键「Windows PowerShell」→ **以管理员身份运行**，执行：

```powershell
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\install.ps1"
```

安装脚本会复制文件到 `C:\EdgeIconGuard`，然后调用主脚本完成部署与计划任务注册。

也可以直接装到任意目录（不复制）：

```powershell
# 在解压目录里以管理员身份运行
powershell -ExecutionPolicy Bypass -File .\Update-EdgeIcon.ps1 -Install
```

### 方式二：手动触发部署 / 修复

```powershell
# 管理员运行；强制全量替换 + 重建图标缓存
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\Update-EdgeIcon.ps1" -Force -RebuildCache
```

### 卸载

```powershell
# 管理员运行；恢复默认图标并删除计划任务
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\Update-EdgeIcon.ps1" -Uninstall
```

## 🖥️ 命令行参数

| 参数 | 说明 |
|------|------|
| （无参数） | 常规巡检：版本变化 / 磁贴被重置才动手，否则只做只读检查 |
| `-Install` | 部署 + 注册计划任务（需管理员） |
| `-Uninstall` | 恢复默认图标 + 删除计划任务（需管理员） |
| `-Force` | 跳过版本比较，强制全量替换 |
| `-RebuildCache` | 重建图标缓存（杀 explorer + 删 iconcache_*.db） |
| `-Diagnose` | **只输出环境自检报告，不修改任何东西** |
| `-MakeIcoOnly` | 只从 `logo.png` 重新生成 ico |
| `-Interval <分钟>` | 巡检间隔，默认 15 |

**出问题先跑 `-Diagnose`**，它会列出：脚本目录、权限、Edge 探测结果、所有版本目录、源文件是否齐全、计划任务状态。

```powershell
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\Update-EdgeIcon.ps1" -Diagnose
```

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `Update-EdgeIcon.ps1` | 主守护脚本（单文件全自动） |
| `install.ps1` | 一键安装包装脚本 |
| `VisualElements/Logo.png` | 600×600 大磁贴图 |
| `VisualElements/SmallLogo.png` | 176×176 小磁贴图 |
| `blackgoldedge.ico` | 桌面 / 任务栏 / 开始菜单快捷方式用的图标（多尺寸 16~256） |
| `logo.png` | 源图（用于重新生成 ico） |

## ⚙️ 工作原理

1. **自动探测 Edge**：按 `EdgeUpdate\Clients` 注册表 → `App Paths\msedge.exe` → 常见安装路径（各通道 / 32 位 / 用户级）三级探测，排除 WebView2 Runtime，只认目录里真有 `msedge.exe` 的
2. **ICO 副本防白纸**：将 ico 复制到 `%USERPROFILE%\EdgeBlackGoldIcon\` 并重置 ACL，快捷方式指向该副本
3. **磁贴全版本覆盖**：遍历探测到的每个 Edge 版本目录下的 `VisualElements`，替换 `Logo.png` 和 `SmallLogo.png`；**内容一致就跳过**，不白写盘、不刷文件时间戳
4. **变更检测**：记录上次 Edge 版本号 + 磁贴指纹（路径/大小/修改时间哈希）。版本变了、或磁贴被 Edge 重置了 → 全量替换；否则只做幂等巡检
5. **计划任务** `EdgeBlackGoldIconWatch`：登录时触发 + 每 15 分钟巡检，以最高权限运行（磁贴写入需要管理员）
6. **缓存刷新**：有改动时发 `SHChangeNotify`，必要时杀 explorer + 删 `iconcache_*.db`

## 🔧 自定义

- 换图：直接替换 `VisualElements/Logo.png`、`VisualElements/SmallLogo.png`，重新跑 `-Force`
- 换 ico：替换 `blackgoldedge.ico`，或改 `logo.png` 后跑 `-MakeIcoOnly`
- 改巡检频率：安装时加 `-Interval 30`，或直接改计划任务

## ⚠️ 注意事项

- 安装与磁贴写入需要**管理员权限**（写 Program Files、注册计划任务）。非管理员运行时 lnk 图标仍可替换，磁贴会失败并在日志记录一次
- Edge 更新后最多 **15 分钟**自动恢复黑金磁贴；想立刻生效就手动跑一次 `-Force`
- 任务栏 / 任务管理器里的小图标来自 `msedge.exe` 内嵌资源，改它会破坏数字签名，**本工具不修改**
- 右键菜单「新建窗口 / 无痕窗口」图标保持原样
- 脚本文件必须是 **UTF-8 with BOM** 保存，否则 Windows PowerShell 5.1 会把中文注释解析成乱码并报语法错误

## 📄 许可

MIT License — 随意用、改、传。

---

*Made with 🐟 by 大肥鱼*
