# DailyWallpaper v1

DailyWallpaper 是一个面向 Windows 的静态 4K 壁纸自动化项目。它根据天气、昼夜和主题从 Wallhaven 选择壁纸，通过 Wallpaper Engine CLI 只更新指定显示器；不使用 Web Wallpaper、动画或常驻服务。

## 当前行为

- 固定维护 **8 张**本地候选壁纸。
- `skip.ps1` 只在这 8 张之间循环：`1 → 2 → … → 8 → 1`，不会因为走到第 8 张而重新下载候选池。
- 想主动下载一组新的 8 张图片时，运行 `force-refresh.ps1`。
- 只接受至少 `3840x2160`、近似 `16:9`、SFW、General 的 JPG/PNG。
- Wallhaven 候选按收藏数和浏览量做质量偏置随机，不固定选择单个最高分结果。
- 最近 60 天实际显示过的图片会进入历史，用于过滤**未来新建的候选池**；历史不会阻止当前 8 张本地池循环。
- 天气变化需要连续两次检查确认，自动天气切换默认至少间隔 3 小时。
- 支持 Windows PowerShell 5.1 与 PowerShell 7。
- 目标显示器由 `wallpaperEngine.monitor` 指定；示例为 `0`。
- 推荐跳过快捷键：`Ctrl + Alt + M`。

## Unicode 路径兼容

项目本身可以放在含中文或其他 Unicode 字符的目录中。为了避免部分 Wallpaper Engine/Windows 组合无法读取非 ASCII 图片路径，脚本在调用 Wallpaper Engine 前会把当前图片复制到：

```text
%LOCALAPPDATA%\DailyWallpaper\cache
```

Wallpaper Engine 实际读取的是这里的 ASCII 安全文件名；项目目录中的 `cache/` 仍然用于候选池下载与状态管理。

## Requirements

- Windows 10/11
- Wallpaper Engine 已安装并运行
- Windows PowerShell 5.1 或 PowerShell 7
- 可访问 Wallhaven 与 Open-Meteo

## Installation

1. 克隆或下载仓库。
2. 从示例配置创建本机配置：

   ```powershell
   Copy-Item .\config.example.json .\config.json
   ```

3. 编辑本机 `config.json`：
   - `location.latitude` / `location.longitude`
   - `location.timezone`
   - `wallpaperEngine.executable`
   - `wallpaperEngine.monitor`
4. 手动运行一次：

   ```powershell
   .\scripts\update.ps1
   ```

`config.json` 是本机配置，已被 `.gitignore` 忽略；仓库只维护 `config.example.json`。

## 示例配置

仓库中的 `config.example.json` 使用上海作为天气位置示例：

```json
{
  "location": {
    "latitude": 31.2304,
    "longitude": 121.4737,
    "timezone": "Asia/Shanghai"
  },
  "wallpaperEngine": {
    "executable": "C:\\Program Files (x86)\\Steam\\steamapps\\common\\wallpaper_engine\\wallpaper64.exe",
    "monitor": 0
  }
}
```

Wallpaper Engine 安装位置因机器而异。请在你自己的 `config.json` 中填写真实路径，不要把本机路径或 API key 提交到仓库。

## Commands

```powershell
# 日常检查：日期、天气、候选池状态
.\scripts\update.ps1

# 在现有 8 张候选中循环到下一张
.\scripts\skip.ps1

# 立即下载并切换到一组新的 8 张候选
.\scripts\force-refresh.ps1

# 安装登录时和每小时运行的计划任务
.\scripts\setup-task.ps1
```

## Skip shortcut

创建一个 Windows 快捷方式，目标类似：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<DailyWallpaper>\scripts\skip.ps1"
```

在快捷方式属性中将快捷键设为：

```text
Ctrl + Alt + M
```

项目不依赖 AutoHotkey。

## Task Scheduler

运行：

```powershell
.\scripts\setup-task.ps1
```

会创建：

- `DailyWallpaper - Login`：用户登录时执行 `update.ps1`
- `DailyWallpaper - Hourly`：每小时执行一次 `update.ps1`

它们不是常驻守护进程。

## Pool 与历史

候选池固定为 8 张。正常的小时检查不会因为当前索引位于第 8 张而重建池。

```text
skip: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 1 → ...
```

只有以下情况会构建新池：

- 首次运行或候选池损坏/缺失
- 新的一天需要自动更新
- 确认后的天气类别变化触发自动更新
- 手动运行 `force-refresh.ps1`

当前池里的图片即使已经写入 60 天历史，仍可继续循环。历史只在下一次从 Wallhaven 创建新池时用于去重。

## Runtime data

以下内容仅存在于本机，不应提交：

```text
config.json
state/*.json
cache/*
logs/*
%LOCALAPPDATA%\DailyWallpaper\cache\*
```

仓库中的 `.gitignore` 还排除了本地 handoff ZIP、Research Inbox OAuth 日志/venv 和常见编辑器文件。

## Failure behavior

- Open-Meteo 暂时不可用：使用最后一次天气分类，不清空当前壁纸。
- Wallhaven 新池构建失败：保留当前工作池，不以空池覆盖。
- 新池无法得到完整 8 张有效图片：视为构建失败，保留现有池。
- Wallpaper Engine CLI 失败：不把目标图片记为成功显示。
- 项目路径包含中文：Wallpaper Engine 使用 `%LOCALAPPDATA%\DailyWallpaper\cache` 中的暂存副本。

## Security / repository hygiene

不要提交：

- `config.json`
- API key、Token、账号凭据
- `state/`、`cache/`、`logs/` 的运行时内容
- 本机绝对路径
- `DailyWallpaper-v1-handoff.zip`
- `.research-inbox-oauth-logs/`
- `.research-inbox-oauth-venv/`

公开仓库应只包含脚本、README、`.gitignore`、`config.example.json` 和运行时目录的 `.gitkeep`。
