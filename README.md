# OpenAudio

macOS 向けルーティング＋キャプチャ統合型オーディオユーティリティ（BlackHole の課題を解決する Loopback 対抗）。

- 要件定義: [docs/requirements.md](docs/requirements.md)
- 実装計画: [docs/plan.md](docs/plan.md)

## 現状: Phase 0 スパイク

| コンポーネント | 内容 |
|---|---|
| `Driver/` | 16ch ループバック仮想デバイス（AudioServerPlugIn, C） |
| `Tools/looptest` | 仮想デバイスの output→input bit 一致検証 CLI |
| `Tools/tapcapture` | Process Tap によるプロセス別／システム音キャプチャ CLI（無音ウォッチドッグ・減衰補正付き） |

## ビルドと検証

要件: macOS 14.4+、Xcode コマンドラインツール。

```sh
# 1. ドライバをビルドしてインストール（要 sudo、coreaudiod を再起動します）
make -C Driver
sudo scripts/install-driver.sh

# 2. Audio MIDI Setup に「OpenAudio 16ch」が出現することを確認し、ループバックを検証
cd Tools
swift run looptest

# 3. Tap キャプチャ（初回はシステム音声収録の TCC 許可プロンプトが出ます）
swift run tapcapture --list
swift run tapcapture --system -o /tmp/capture.caf --duration 10
```

アンインストール: `sudo scripts/uninstall-driver.sh`
