<div align="center">

# OpenAudio

**macOS の音声をルーティング・キャプチャ・モニター・録音 — Audio MIDI 設定を一切触らずに。**

[English](README.md) · **日本語** · [한국어](README.ko.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Français](README.fr.md)

[**⬇ 最新リリースをダウンロード**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio は macOS 向けの「ルーティング＋キャプチャ統合型」オーディオユーティリティです（BlackHole / Loopback の統合版といえる存在）。アプリ単位・システム全体の音声をキャプチャしてミックス・ルーティングし、その結果を他のアプリや DAW から選べる仮想入力デバイスとして公開。モニターや録音も可能で、Aggregate や Multi-Output デバイスを手作業で組む必要は一切ありません。

## 主な機能

- 🎙 **アプリ単位／システム全体のキャプチャ**（Core Audio Process Tap, macOS 14.4+）— 「Spotify だけ」も全体も収録可能。
- 🎚 **ルーティング行列** — 任意のソースを任意のバスへ。ソース単位の gain / pan / mute / solo。
- 🔌 **仮想出力デバイス** — ミックス結果が任意のアプリ・DAW に **OpenAudio** 入力として現れる。
- 🎧 **リアルタイムモニタリング** — 自分の出力へパススルー、音量調整付き。
- 📊 **チャンネル単位のライブメーター**（ピークホールド付き）。
- ⏺ **録音** — 最終ミックス（または個別バス）をファイルに。
- 🎛 **複数バス**（最大 8）で並列ルーティング。
- 🎤 **マイク／オーディオIF 入力**をミックスソースとして取り込み。
- 🖥 **軽量なメニューバー常駐アプリ** — Dock を占有しません。

## 動作要件

- macOS **14.4** 以降（Apple Silicon / Intel）
- ドライバの初回インストールに管理者権限

## インストール

1. 最新リリースから [**`OpenAudio-1.0.0.pkg` をダウンロード**](https://github.com/DTMER2/openaudio/releases/latest)。
2. インストーラを開いて進めます。HAL オーディオドライバとアプリを導入し、Core Audio を再起動します。
3. アプリケーションフォルダから **OpenAudio** を起動 — メニューバーにアイコンが表示されます。
4. 初回起動時に **音声キャプチャの許可**（システム設定 › プライバシーとセキュリティ）を付与してください。アプリ／システム音声の収録に必要です。

インストーラは **Developer ID 署名**＋**Apple 公証**済みです。

> **ヒント:** メニューバー常駐アプリのため Dock アイコンは出ません。自動起動させたい場合はシステム設定 › 一般 › ログイン項目 に追加してください。

## 仕組み

OpenAudio は 2 つの macOS 技術を組み合わせています。

- **Core Audio Process Tap** が、選んだアプリまたはシステム全体の音声をキャプチャ（macOS 14.4+）。
- 同梱の **AudioServerPlugIn 仮想デバイス** が、ルーティング結果を他アプリ・DAW から選べる入力として公開。

その間のミックスとルーティングをアプリが担います。Audio MIDI 設定も、Aggregate / Multi-Output の手組みも不要です。

## アンインストール

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## Mac App Store で配布しない理由

OpenAudio はシステムオーディオドライバを `/Library/Audio/Plug-Ins/HAL` に導入し `coreaudiod` を再起動します。これは App Store のサンドボックスでは許可されないため、署名・公証済みインストーラとしてストア外で配布しています。

## ライセンス

**プロプライエタリ — 全権利留保。** ソースは透明性と評価のために公開しているのみです。詳細は [LICENSE](LICENSE) を参照してください。
