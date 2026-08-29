# DailyWallpaper v1

一个只依赖 Windows PowerShell、Wallpaper Engine、Windows Task Scheduler、Wallhaven 和 Open-Meteo 的静态壁纸自动化工具。

它会根据日期、天气、昼夜和可配置的视觉主题，从 Wallhaven 选择并下载 4K 以上的 16:9 SFW General 壁纸。它只调用 Wallpaper Engine 的命令行接口，不创建 Web Wallpaper、动画、叠加层或常驻后台进程。

## 特性

- 仅更新 `config.json` 指定的 Wallpaper Engine 显示器索引；不会默认假设 `monitor 0` 就是 Windows 主显示器。
- 只接受至少 `3840x2160`、近似 `16:9`、SFW、General 类别的 JPG/PNG。
- 天气分类：`CLEAR`、`CLOUDY`、`RAIN`、`FOG`、`SNOW`、`STORM`。
- 天气变化必须连续两次检查确认，自动天气切换默认至少间隔 3 小时。
- 每次创建 8 张本地候选池，手动跳过已有缓存项时不需要等待网络请求。
- `state/history.json` 保留最近 60 天实际显示过的壁纸 ID，手动跳过也会计入历史。
- API 或 Wallpaper Engine 失败时保留当前工作壁纸和旧状态，不用空池覆盖旧池。
- 状态 JSON 使用同目录临时文件和原子替换写入。

## Requirements

- Windows 10/11
- Wallpaper Engine 已安装并正在运行
- PowerShell 7（推荐）或 Windows PowerShell 5.1
- 可访问 Wallhaven 和 Open-Meteo 的网络
- 运行脚本的账户对本项目目录具有读写权限

Wallhaven 的搜索 API 和 Wallpaper Engine 的命令行参数分别见官方文档：[Wallhaven API v1](https://wallhaven.cc/help/api) 和 [Wallpaper Engine Command Line Controls](https://help.wallpaperengine.io/en/functionality/cli.html)。v1 使用 SFW 搜索，不需要 Wallhaven API key。

## Installation

1. 将整个项目目录放在一个稳定路径，例如 `C:\Tools\DailyWallpaper`。
2. 编辑 [config.json](config.json)，至少修改：
   - `location.latitude` / `location.longitude`
   - `wallpaperEngine.executable`
   - `wallpaperEngine.monitor`
3. 确认 Wallpaper Engine 已启动，并且当前用户允许它接受命令行控制。
4. 在项目根目录打开 PowerShell，手动执行一次：

   ```powershell
   .\scripts\update.ps1
   ```

首次成功运行会创建 `state/`、`cache/` 和 `logs/` 中的运行时文件。运行时数据已加入 `.gitignore`，不会被提交到 Git。

### 如果 config.json 不存在

脚本会生成一个带默认值的示例配置并退出。编辑它后再次运行即可。仓库内提供的配置使用上海坐标作为示例，必须按实际地点修改。

## 配置 Wallpaper Engine

### 找到可执行文件

常见位置是：

```text
C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe
```

也可以在 Steam 的 Wallpaper Engine 属性中打开“浏览本地文件”，找到 `wallpaper64.exe` 或 `wallpaper32.exe`，然后写入 `wallpaperEngine.executable`。路径含空格时不需要在 JSON 值中额外加引号；示例配置已经展示了正确形式。

### 确定主显示器索引

`wallpaperEngine.monitor` 是 Wallpaper Engine CLI 的数字索引，不能仅凭 Windows 显示设置中的“主显示器”编号推断。建议：

1. 确认 Wallpaper Engine 正在运行。
2. 将 `monitor` 设置为一个候选值，从 `0` 开始。
3. 运行 `force-refresh.ps1`，确认只有目标主显示器被更新。
4. 若目标错误，改用下一个索引重复测试。

Wallpaper Engine 官方 CLI 也支持 `getWallpaper -monitor <number>`，可用于逐个索引检查当前壁纸路径。确定后，把索引固定写入 `config.json`；不要在脚本中自动猜测主显示器。

## Manual commands

在项目根目录执行：

```powershell
# 普通更新：检查日期、天气防抖和当前候选池
.\scripts\update.ps1

# 跳过当前壁纸：优先从本地候选池即时切换
.\scripts\skip.ps1

# 忽略当前候选池，按当前天气/昼夜重新下载候选池
.\scripts\force-refresh.ps1

# 安装“登录时”和“每小时”两个任务
.\scripts\setup-task.ps1
```

脚本手动运行时会输出当前天气、昼夜、主题、查询字符串、当前壁纸和候选池位置。实际失败会返回非零退出码。

## Skip shortcut / hotkey

可以创建一个指向以下命令的 Windows 快捷方式：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\DailyWallpaper\scripts\skip.ps1"
```

在快捷方式属性中将“起始位置”设为项目根目录，并在“快捷键”字段设置 `Ctrl + Alt + N`。Windows 对带方向键的快捷键支持不一致，因此 v1 文档推荐字母 `N`；也可以按个人习惯使用其他组合。v1 不依赖 AutoHotkey。

## Task Scheduler

执行：

```powershell
.\scripts\setup-task.ps1
```

它会创建：

- `DailyWallpaper - Login`：当前用户登录时执行 `update.ps1`
- `DailyWallpaper - Hourly`：首次在约一分钟后执行，之后每小时检查一次

脚本不会创建持续运行的服务或后台守护进程。若系统策略要求管理员权限，请用当前用户确认后的 PowerShell 窗口执行任务安装；任务本身仍以当前用户上下文运行。

## Topic weights

默认 `MIXED` 权重为：

```json
"weights": {
  "NATURE": 40,
  "CITY": 30,
  "ARCHITECTURE": 20,
  "SPACE": 10
}
```

权重不要求总和必须为 100。也可以把 `topics.mode` 改为 `NATURE`、`CITY`、`ARCHITECTURE` 或 `SPACE`，固定使用一个主题。天气和主题的关键词池位于 `keywords` 配置节中，可直接编辑。

## Pool and history behavior

- `pool.size` 默认是 8；`candidateTarget` 默认请求约 72 个候选；`highQualityCandidateCount` 默认从质量最高的约 24 个候选中做质量偏置随机抽样。
- 质量分使用 `3 * log(favorites + 1) + log(views + 1)`，不会每次都选择单个收藏数最高的结果。
- 只有真正显示过的壁纸才写入历史；等待中的候选不会被提前标记为已看。
- 手动跳过的当前壁纸会写入历史，因此未来 60 天不会重新进入候选池。
- 候选池耗尽后，`skip.ps1` 才会联网构建新池；有可用缓存项时跳过路径不请求 Wallhaven。

运行时目录：

```text
state/current.json   当前实际显示的壁纸和场景
state/pool.json      当前已下载的候选池和索引
state/history.json   最近 60 天显示事件
state/weather.json   天气分类确认、防抖和自动切换时间
cache/               已下载的 JPG/PNG
logs/                dailywallpaper.log 和轮转日志
```

## Failure behavior and troubleshooting

### 桌面没有变化

1. 确认 Wallpaper Engine 正在运行。
2. 检查 `wallpaperEngine.executable` 是否指向真实文件。
3. 检查 `wallpaperEngine.monitor` 是否是已验证的 Wallpaper Engine 索引。
4. 查看 `logs/dailywallpaper.log` 中的 CLI 退出码和错误输出。

### 没有下载到图片

Wallhaven 可能暂时限流、搜索结果不足或网络不可用。脚本会依次尝试更宽的查询，但始终保留 4K、16:9、SFW、General 和 60 天排除条件。构建失败时旧候选池和当前壁纸不会被空池替换。

### Open-Meteo 不可用

有历史天气状态时使用最后一个活动分类；没有历史状态时回退到 `CLOUDY`。只要当前池仍然有效，脚本不会因为天气请求失败而切换壁纸。

### 只想重新选择一次

执行：

```powershell
.\scripts\force-refresh.ps1
```

它不会把手动操作计入自动天气切换的 3 小时限制，但实际显示的新图片仍会写入 60 天历史。

### 清理运行时数据

停止计划任务后，可以手动删除 `state/*.json`、`cache/*` 和 `logs/*` 来回到首次运行状态。不要删除本项目脚本或 `config.json`。删除缓存会让下一次更新重新下载图片。

## Acceptance checklist

部署前建议在 Wallpaper Engine 已运行、网络可用的测试机器上逐项确认：

1. 空 `state/` 时首次更新能创建不超过 8 张合格图片并显示第一张。
2. `3840x2160`、`5120x2880` 可接受；`3440x1440`、`2560x1440` 被拒绝。
3. 同一天、天气未变的小时检查不会更换壁纸。
4. 天气序列 `CLEAR → RAIN → CLEAR` 不触发切换；`CLEAR → RAIN → RAIN` 在满足 3 小时限制后才触发。
5. `skip.ps1` 在候选池未耗尽时不需要联网，并递增池索引。
6. 候选池耗尽后能重新建池，且不选择最近 60 天历史 ID。
7. 暂时断开 Open-Meteo 或 Wallhaven 时，当前工作壁纸和旧池仍保留。
8. 将 Wallpaper Engine 可执行文件改为无效路径时，脚本返回非零退出码且不把新图片写成已显示。
