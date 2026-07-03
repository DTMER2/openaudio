<div align="center">

# OpenAudio

**路由、捕获、监听并录制 macOS 音频 —— 无需触碰“音频 MIDI 设置”。**

[English](README.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Français](README.fr.md)

[**⬇ 下载最新版本**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio 是一款 macOS 上集“路由 + 捕获”于一体的音频工具，可视为 BlackHole 与 Loopback 的整合替代方案。它能按应用或全系统捕获音频，进行混音与路由，并将结果作为其他应用和 DAW 可选择的虚拟输入设备公开；同时支持监听与录制，完全无需手动搭建聚合设备或多输出设备。

## 功能特性

- 🎙 **按应用及全系统捕获** —— 基于 Core Audio Process Tap（macOS 14.4+），可只录“Spotify”也可录全部。
- 🎚 **路由矩阵** —— 将任意音源连接到任意总线，支持每个音源的增益 / 声像 / 静音 / 独奏。
- 🔌 **虚拟输出设备** —— 混音结果在任意应用或 DAW 中显示为 **OpenAudio** 输入。
- 🎧 **实时监听** —— 直通到你自己的输出，带电平控制。
- 📊 **逐通道实时电平表**（带峰值保持）。
- ⏺ **录制** —— 将最终混音（或单条总线）录制为文件。
- 🎛 **多总线**（最多 8 条）实现并行路由。
- 🎤 **麦克风 / 音频接口输入** 可作为可混音的音源。
- 🖥 **轻量菜单栏应用** —— 不占用程序坞。

## 系统要求

- macOS **14.4** 或更高版本（Apple Silicon 或 Intel）
- 首次安装驱动需要管理员权限

## 安装

1. 从最新版本 [**下载 `OpenAudio-1.0.0.pkg`**](https://github.com/DTMER2/openaudio/releases/latest)。
2. 打开安装程序并按步骤操作。它会安装 HAL 音频驱动与应用，并重启 Core Audio。
3. 从“应用程序”文件夹启动 **OpenAudio** —— 图标会出现在菜单栏。
4. 出现提示时，请授予**音频捕获权限**（系统设置 › 隐私与安全性）。这是捕获应用/系统音频所必需的。

安装程序已使用 **Developer ID 签名** 并通过 **Apple 公证**。

> **提示：** OpenAudio 是菜单栏应用，因此没有程序坞图标。若需开机自动启动，请在系统设置 › 通用 › 登录项 中添加。

## 工作原理

OpenAudio 结合了两项 macOS 技术：

- **Core Audio Process Tap** 捕获所选应用或整个系统的音频（macOS 14.4+）。
- 内置的 **AudioServerPlugIn 虚拟设备** 将路由结果作为其他应用和 DAW 可选择的输入公开。

其间的混音与路由由应用完成 —— 无需“音频 MIDI 设置”，也无需手动创建聚合或多输出设备。

## 卸载

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## 为何不在 Mac App Store 上架

OpenAudio 需要将系统音频驱动安装到 `/Library/Audio/Plug-Ins/HAL` 并重启 `coreaudiod`，而这是 App Store 沙盒所不允许的。因此它以签名并公证的安装程序形式在商店之外分发。

## 许可协议

**专有软件 —— 保留所有权利。** 源代码仅出于透明与评估目的公开。详见 [LICENSE](LICENSE)。
