# 実装計画（v0.1 — Phase 0 スパイク）

`docs/requirements.md` v0.1 に基づく。リスクの高いプリミティブから検証する方針（第9章）に従い、まず Phase 0 の 2 スパイクを実装する。

## 前提・決定事項

| 項目 | 決定 | 根拠 |
|---|---|---|
| 製品名（暫定） | OpenAudio | リポジトリ名に合わせる（要件書のコードネーム Conflux は「変更可」） |
| バンドル ID | `com.openaudio.driver` ほか | 上に同じ |
| 仮想デバイス ch 数 | 16ch / 32-bit float 固定 | F-D2、R4（ライブ可変はクライアント切断を招く） |
| ドライバ実装言語 | C（AudioServerPlugIn インターフェース直実装） | Apple サンプル系譜・GPL 回避（第10章）、realtime 制約（NF-P1） |
| ドライバのビルド | Makefile + clang（universal, arm64+x86_64） | .driver バンドル生成は Xcode 不要でスクリプト化しやすい |
| App 側ツール | Swift Package（`Tools/`）、CLI 実行ファイル | スパイク段階で UI 不要。Phase 3 で SwiftUI App に移行 |

## ディレクトリ構成

```
openaudio/
├── docs/                  # requirements.md / plan.md
├── Driver/                # Phase 0(a): AudioServerPlugIn（C）
│   ├── Source/OpenAudioDriver.c
│   ├── OpenAudioDriver-Info.plist
│   └── Makefile           # → build/OpenAudioDriver.driver（universal, ad-hoc署名）
├── Tools/                 # Swift Package（CLI スパイク群）
│   ├── Package.swift
│   └── Sources/
│       ├── looptest/      # Phase 0(a) 検証: 仮想デバイス output→input の bit 一致確認
│       └── tapcapture/    # Phase 0(b): Process Tap → ファイル録音 + ウォッチドッグ + 減衰補正
└── scripts/
    ├── install-driver.sh  # /Library/Audio/Plug-Ins/HAL へ配置 + coreaudiod kickstart（要 sudo）
    └── uninstall-driver.sh
```

## Phase 0(a) — 最小 AudioServerPlugIn（16ch ループバック）

対応要件: F-D1, F-D2, F-D3, F-D5 / NF-P1 / 受け入れ基準 Phase 0(a)

- `AudioServerPlugInDriverInterface` を C で全実装（NullAudio サンプルの構成に倣うが、コードは新規に書く）。
- デバイス 1 台を publish（複数インスタンス化＝F-D4 と制御プレーン＝F-D6 は Phase 2）。
- 16ch in / 16ch out、Float32、44.1/48/88.2/96 kHz。
- output → input はロックフリーリングバッファ（IO パスは無確保・無ロック・無 syscall）。
- `GetZeroTimeStamp` は `mach_absolute_time` ベースで単調・周期的に供給。
- 検証: `looptest` が output へ既知信号（インパルス＋ランプ）を書き、input から読み戻して bit 一致を判定。

## Phase 0(b) — 最小 Tap キャプチャ

対応要件: F-C1〜F-C6 / NF-R1, NF-R2, NF-SE1, NF-SE3 / 受け入れ基準 Phase 0(b)

- `CATapDescription` + `AudioHardwareCreateProcessTap`（対象 PID 指定 or システム全体）。
- private aggregate（実出力 = main sub-device、tap = sub-tap、`IsPrivate = true`、AutoStart）。
- 取得は `AudioDeviceCreateIOProcIDWithBlock` 直接使用（AVAudioEngine retarget 不可 = R3）。
- IOProc → SPSC リングバッファ → 別スレッドで CAF 書き出し（RT スレッドでファイル I/O しない）。
- ウォッチドッグ: RMS 継続ゼロ + running 状態の併用で無音化バグ（R1）を検知し、tap/aggregate を完全再生成。復旧はクロスフェード。
- 出力デバイスのステレオペア数に応じた減衰補正（R2）。

## 検証手順

1. `make -C Driver` → `sudo scripts/install-driver.sh` → Audio MIDI Setup に「OpenAudio 16ch」が出現すること。
2. `swift run looptest` → bit 一致 PASS。
3. `swift run tapcapture --pid <PID> -o out.caf`（初回に TCC プロンプト）→ 再生確認、レベル誤差 ±0.5dB 以内。
4. 24h 連続録音・ウォッチドッグ作動確認は長期テストとして別途（受け入れ基準 0(b) の残項目）。

## 以降のフェーズ（本計画のスコープ外）

- Phase 1: App エンジン（ミキサー + SRC/PI ドリフト補正）
- Phase 2: 制御プレーン（カスタム HAL プロパティ、複数バス）
- Phase 3: SwiftUI UI（ノードグラフ、メーター、メニューバー常駐）
- Phase 4: 署名・notarization・インストーラ
