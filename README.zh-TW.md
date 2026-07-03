<div align="center">

# OpenAudio

**路由、擷取、監聽並錄製 macOS 音訊 —— 無需碰觸「音訊 MIDI 設定」。**

[English](README.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [Deutsch](README.de.md) · [Français](README.fr.md)

[**⬇ 下載最新版本**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio 是一款 macOS 上整合「路由 + 擷取」的音訊工具，可視為 BlackHole 與 Loopback 的整合替代方案。它能依應用程式或全系統擷取音訊，進行混音與路由，並將結果作為其他應用程式與 DAW 可選擇的虛擬輸入裝置公開；同時支援監聽與錄製，完全無需手動搭建聚合裝置或多重輸出裝置。

## 功能特色

- 🎙 **依應用程式及全系統擷取** —— 基於 Core Audio Process Tap（macOS 14.4+），可只錄「Spotify」也可錄全部。
- 🎚 **路由矩陣** —— 將任意音源連接到任意匯流排，支援每個音源的增益 / 相位 / 靜音 / 獨奏。
- 🔌 **虛擬輸出裝置** —— 混音結果在任意應用程式或 DAW 中顯示為 **OpenAudio** 輸入。
- 🎧 **即時監聽** —— 直通到你自己的輸出，附電平控制。
- 📊 **逐聲道即時電平表**（含峰值保持）。
- ⏺ **錄製** —— 將最終混音（或單一匯流排）錄製為檔案。
- 🎛 **多匯流排**（最多 8 條）實現並行路由。
- 🎤 **麥克風 / 音訊介面輸入** 可作為可混音的音源。
- 🖥 **輕量選單列應用程式** —— 不佔用 Dock。

## 系統需求

- macOS **14.4** 或更新版本（Apple Silicon 或 Intel）
- 首次安裝驅動程式需要管理者權限

## 安裝

1. 從最新版本 [**下載 `OpenAudio-1.0.0.pkg`**](https://github.com/DTMER2/openaudio/releases/latest)。
2. 開啟安裝程式並依步驟操作。它會安裝 HAL 音訊驅動程式與應用程式，並重新啟動 Core Audio。
3. 從「應用程式」資料夾啟動 **OpenAudio** —— 圖示會出現在選單列。
4. 出現提示時，請授予**音訊擷取權限**（系統設定 › 隱私權與安全性）。這是擷取應用程式/系統音訊所必需的。

安裝程式已使用 **Developer ID 簽署** 並通過 **Apple 公證**。

> **提示：** OpenAudio 是選單列應用程式，因此沒有 Dock 圖示。若需開機自動啟動，請於系統設定 › 一般 › 登入項目 中新增。

## 運作原理

OpenAudio 結合了兩項 macOS 技術：

- **Core Audio Process Tap** 擷取所選應用程式或整個系統的音訊（macOS 14.4+）。
- 內建的 **AudioServerPlugIn 虛擬裝置** 將路由結果作為其他應用程式與 DAW 可選擇的輸入公開。

其間的混音與路由由應用程式完成 —— 無需「音訊 MIDI 設定」，也無需手動建立聚合或多重輸出裝置。

## 解除安裝

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## 為何不在 Mac App Store 上架

OpenAudio 需要將系統音訊驅動程式安裝到 `/Library/Audio/Plug-Ins/HAL` 並重新啟動 `coreaudiod`，而這是 App Store 沙盒所不允許的。因此它以簽署並公證的安裝程式形式在商店之外散布。

## 授權條款

**專有軟體 —— 保留一切權利。** 原始碼僅為透明與評估目的而公開。詳見 [LICENSE](LICENSE)。
