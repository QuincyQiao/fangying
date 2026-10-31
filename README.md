<p align="center"><img src="docs/icon.png" width="128" alt="放映的图标"></p>

<h1 align="center">放映</h1>

<p align="center">macOS 原生视频播放器。内核是 mpv，什么格式都能放，对中文字幕格外友好。</p>

<p align="center">A native macOS video player built on libmpv, with first-class Chinese subtitle support. The interface is in Chinese.</p>

![播放窗口：右侧是同文件夹的播放列表，进度条悬停时显示章节名和缩略图](docs/player.jpg)

## 能做什么

- **什么格式都能放**：MKV、MP4、AVI、RMVB、FLV、WebM、TS 等，ASS 特效字幕按原样渲染，VideoToolbox 硬件解码
- **记住进度**：每个视频记着看到哪，再打开接着放；首页是最近看过的画面
- **自动连播**：同一文件夹按集数排好（第 2 集在第 10 集前面），放完接下一集
- **中文字幕**：自动加载同名字幕和 `Subs`、`字幕` 子文件夹里的字幕，认得 `.chs`、`.简体`、`chs&eng` 这些写法并优先选简体；GBK、Big5 编码自动识别；可以显示第二字幕，调字号、位置和延迟
- **倍速**：0.25–4 倍自由调，常用档一键切换
- **章节**：进度条按章节分段，悬停时显示章节名和缩略图
- **沉浸界面**：鼠标不动控制条就淡出；侧栏开合时画面纹丝不动
- **系统集成**：支持键盘媒体键和控制中心，播放时屏幕不睡眠
- **只在本机**：观看记录和缩略图都存在你的电脑上，不联网

| 倍速面板 | 首页 |
|---|---|
| ![倍速面板：滑条和五个常用档](docs/speed.jpg) | ![首页：最近看过的视频和看到的位置](docs/home.jpg) |

## 安装

这个仓库发布源码，自己编译一次就能用。需要 Apple 芯片的 Mac、macOS 27、Xcode 命令行工具和 [Homebrew](https://brew.sh)，不需要完整的 Xcode。

```bash
xcode-select --install
brew install mpv
git clone https://github.com/QuincyQiao/fangying.git
cd fangying
./重新构建.command
```

脚本会编译、跑自测、把 mpv 和 FFmpeg 打进 app，然后装到 `/Applications/放映.app` 并打开。装好之后不再依赖 Homebrew。

想把放映设成所有视频的默认打开方式，或者在桌面放一个替身：

```bash
FANGYING_SET_DEFAULT=1 FANGYING_DESKTOP_ALIAS=1 ./重新构建.command
```

默认打开方式也可以在菜单「放映 → 设为视频的默认播放器」里设。

## 快捷键

| 按键 | 作用 |
|---|---|
| 空格 | 播放 / 暂停 |
| ← → | 快退 / 快进，默认 3 秒，在设置（⌘,）里改 |
| ⇧← ⇧→ | 快退 / 快进 30 秒 |
| ↑ ↓ | 音量 |
| M | 静音 |
| `[` `]` `\` | 减速 / 加速 / 恢复正常速度 |
| `,` `.` | 上一帧 / 下一帧 |
| ⌘← ⌘→ | 上一个 / 下一个 |
| Z X | 字幕提前 / 推后 0.1 秒 |
| F、回车或双击 | 全屏 |
| ⌃⌘S | 显示 / 隐藏侧栏 |

单击画面默认不做任何事，可以在设置里改成播放或暂停。

## 开发

实现上的取舍和踩过的坑见[开发说明](说明.md)。

## 许可证

放映按 [GPL-3.0-or-later](LICENSE) 发布，Copyright © 2026 Chenxu Qiao。

放映建立在这些项目之上：[mpv](https://mpv.io)（GPL-2.0-or-later）、[FFmpeg](https://ffmpeg.org)（Homebrew 版本为 GPL-3.0-or-later）、[libass](https://github.com/libass/libass)（ISC）、[libplacebo](https://code.videolan.org/videolan/libplacebo)（LGPL-2.1-or-later），以及它们依赖的其他库。分发打包好的 app 时，需要一并遵守这些库的许可证。
