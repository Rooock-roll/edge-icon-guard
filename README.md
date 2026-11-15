# Edge Icon Guard 🛡️

Edge 浏览器黑金主题图标自动守护工具。

## ✨ 功能特性

- **桌面/任务栏/开始菜单快捷方式** → 统一替换为黑金漩涡图标
- **开始菜单磁贴** → 大磁贴、小磁贴、宽磁贴全覆盖黑金主题
- **自动守护** → Edge 更新后自动检测新版本目录并重新铺设黑金磁贴
- **多版本兼容** → 自动遍历所有已安装 Edge 版本目录，一网打尽
- **定时巡检** → 登录时 + 每 90 分钟自动巡检，版本变化/文件被重置自动修复
- **白纸修复** → 自动规避 DSH 沙箱 ACL 导致的图标白纸问题

## 📦 安装使用

### 方式一：一键部署（推荐）

以管理员身份运行 PowerShell：

```powershell
# 1. 解压到任意目录（如 C:\EdgeIconGuard）
# 2. 以管理员运行：
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\Update-EdgeIcon.ps1" -Install
```

脚本会自动：
- 部署黑金图标到 C 盘用户目录（避免白纸）
- 替换所有 Edge 快捷方式图标
- 为所有已安装版本目录铺设黑金磁贴
- 注册计划任务（登录时 + 每 90 分钟巡检）
- 重建图标缓存

### 方式二：手动触发部署/修复

```powershell
# 管理员运行
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\Update-EdgeIcon.ps1" -Force -RebuildCache
```

### 卸载

```powershell
powershell -ExecutionPolicy Bypass -File "C:\EdgeIconGuard\Update-EdgeIcon.ps1" -Uninstall
```

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `Update-EdgeIcon.ps1` | 主守护脚本（单文件全自动） |
| `VisualElements/Logo.png` | 600×600 大磁贴图 |
| `VisualElements/SmallLogo.png` | 176×176 小/宽磁贴图 |
| `blackgoldedge.ico` | 桌面/任务栏/开始菜单快捷方式用的图标 |
| `logo.png` | 源图（用于重新生成 ico） |

## ⚙️ 工作原理

1. **ICO 白纸修复**：将原版 ico 复制到 `C:\Users\<User>\EdgeBlackGoldIcon\` 并重置 ACL，快捷方式指向该副本
2. **磁贴全版本覆盖**：遍历 `C:\Program Files (x86)\Microsoft\Edge\Application\` 下所有版本目录的 `VisualElements`，替换 `Logo.png` 和 `SmallLogo.png`
3. **自动巡检**：计划任务 `EdgeBlackGoldIconWatch` 在登录时 + 每 90 分钟运行，检测版本变化、文件被重置、缓存失效并自动修复
4. **缓存重建**：必要时自动杀 explorer + 删 iconcache_*.db 强制刷新

## 🔧 自定义

- 修改 `VisualElements/Logo.png` 和 `SmallLogo.png` 可换主题图
- 脚本内 `$trg2.RepetitionInterval` 可调整巡检间隔（默认 90 分钟）
- `-RebuildCache` 参数强制重建图标缓存

## ⚠️ 注意事项

- 首次安装需**管理员权限**（写 Program Files、注册计划任务、删缓存）
- Edge 更新后最多 90 分钟自动恢复黑金磁贴
- 任务栏预览/任务管理器图标来自 exe 内嵌资源，改动会破坏签名，**本工具不修改**
- 右键菜单「新建窗口/无痕窗口」图标保持原样

## 📄 许可

MIT License — 随意用、改、传。

---

*Made with 🐟 by 大肥鱼*
