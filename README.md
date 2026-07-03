<div align="center">

# OpenAudio

**Route, capture, monitor and record macOS audio — without touching Audio MIDI Setup.**

**English** · [日本語](README.ja.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Français](README.fr.md)

[**⬇ Download the latest release**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio is a routing + capture audio utility for macOS — an integrated alternative to BlackHole and Loopback. It captures audio per-app or system-wide, mixes and routes it, exposes the result as a virtual input device other apps and DAWs can select, lets you monitor and record — and it never asks you to hand-build aggregate or multi-output devices.

## Features

- 🎙 **Per-app & system-wide capture** via Core Audio Process Tap (macOS 14.4+) — capture "just Spotify" or everything.
- 🎚 **Routing matrix** — wire any source to any bus, with per-source gain, pan, mute and solo.
- 🔌 **Virtual output devices** — your routed mix shows up as an **OpenAudio** input in any app or DAW.
- 🎧 **Real-time monitoring** to your own output, with a level control.
- 📊 **Live per-channel meters** with peak hold.
- ⏺ **Recording** of the final mix (or an individual bus) to a file.
- 🎛 **Multiple buses** (up to 8) for parallel routes.
- 🎤 **Mic / audio interface input** as a mixable source.
- 🖥 **Lightweight menu bar app** — no Dock clutter.

## Requirements

- macOS **14.4** or later (Apple Silicon or Intel)
- Administrator rights for the one-time driver installation

## Install

1. [**Download `OpenAudio-1.0.0.pkg`**](https://github.com/DTMER2/openaudio/releases/latest) from the latest release.
2. Open the installer and follow the steps. It installs a HAL audio driver and the app, and restarts Core Audio.
3. Launch **OpenAudio** from your Applications folder — its icon appears in the menu bar.
4. When prompted, grant **audio capture permission** (System Settings › Privacy & Security). This is required to capture app/system audio.

The installer is signed with a **Developer ID** and **notarized by Apple**.

> **Tip:** OpenAudio is a menu bar app, so it has no Dock icon. To have it start automatically, add it under System Settings › General › Login Items.

## How it works

OpenAudio combines two macOS technologies:

- A **Core Audio Process Tap** captures audio from chosen apps or the whole system (macOS 14.4+).
- A bundled **AudioServerPlugIn virtual device** exposes your routed mix as an input that other apps and DAWs can select.

The app mixes and routes everything in between — no Audio MIDI Setup, no aggregate or multi-output devices to build by hand.

## Uninstall

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## Not on the Mac App Store

OpenAudio installs a system audio driver (into `/Library/Audio/Plug-Ins/HAL`) and restarts `coreaudiod`, which the App Store sandbox does not allow. It is therefore distributed outside the store as a signed, notarized installer.

## License

**Proprietary — all rights reserved.** The source is public for transparency and evaluation only. See [LICENSE](LICENSE).
