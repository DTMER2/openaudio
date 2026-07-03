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

## Phase 1 — App エンジン

対応要件: F-E1〜E5（バスは 1 本のみ）、F-C1〜C6 再利用 / NF-S1〜S3, NF-P1〜P5 / 受け入れ基準 Phase 1

ステータス: Phase 0 完了後に着手。

### 構成

```
Tools/Sources/
├── OpenAudioEngine/    # ライブラリ（エンジン本体）
└── openaudio/          # CLI（エンジン起動・メーター/ドリフト統計表示・検証用プローブ）
```

### 設計判断

- **キャプチャ側は単一 private aggregate**（NF-S1）: default output（main）+ tap + 実入力デバイス（sub-device、drift 補正有効）。実入力のドリフトは CoreAudio の aggregate 内補正に任せ、App 側の非同期 SRC は「エンジン → 仮想デバイス」の 1 境界のみ（NF-S2）。
- **クロック橋渡し**: キャプチャ IOProc（ハードウェアクロック）→ SPSC ブリッジリング → 仮想デバイス IOProc（driver クロック）。リング充填率を PI 制御器で監視し、可変比 SRC（キュービック補間。同一公称レートの ppm 級ドリフト補正用途）の比を動的調整（NF-S3）。
- **ミキサー**: ソース単位 gain/mute/pan をアトミックなパラメータスナップショットで RT スレッドへ伝達（NF-P2）。v1 スパイクはステレオバス 1 本 → 仮想デバイス ch0/1 へ書き込み。複数バス・ルーティング行列の一般化は Phase 2。
- **メーター**: ソース／バスの peak・RMS を RT 外で vDSP 計算（NF-P3）、CLI が周期表示。
- **録音**（F-E5）: バスミックスの CAF 書き出し（Phase 0(b) の writer 方式を踏襲）。
- Phase 0(b) の無音ウォッチドッグ・減衰補正・デバイス切替再構築をエンジンへ移植（tapcapture 自体は独立スパイクとして温存）。

### 既知の注意点（実測で確認）

- tap はマスター音量適用**前**の音を捕捉する（ミュート中でもフルレベルで録れる）。
- **デフォルト出力を OpenAudio 16ch 自身にしてはならない**: ソースの直接レンダリングとエンジン経由の書き込みが二重化し、クリップ・コムフィルタを起こす（減衰補正も 16ch=×8 に誤誘導される）。Phase 2/3 で「default output == 自デバイス」の検知・警告（または自動除外）を入れること。

### 検証手順

1. `swift run openaudio run --tap-system` + 別プロセスで仮想デバイス input を録音 → 実音声がエンドツーエンドで到達すること。
2. ドリフト統計（リング充填率・SRC 比 ppm）が収束・安定すること。
3. 受け入れ基準: 「Spotify → 本アプリ → 仮想デバイス → QuickTime」で 10 分間クリックノイズ・ドリフト破綻ゼロ（手動長期試験）。

## Phase 2 — 制御プレーン・複数バス

対応要件: F-D4, F-D6, F-E1（行列の一般化）/ §8 / 受け入れ基準 Phase 2「App から複数バスを動的に生成・ルーティング変更でき、音声スレッドにグリッチが出ない」

### 制御プレーン ABI（契約 — `Driver/Source/OpenAudioControl.h` が正）

- プラグインオブジェクトの解決: `kAudioHardwarePropertyTranslateBundleIDToPlugInObject`（"com.openaudio.driver"）。
- カスタムプロパティ `'OAdc'`（プラグインオブジェクト・global scope・main element、UInt32、settable）: publish するループバックデバイス数（1〜8）。
  - Set 時: driver がデバイスを生成/破棄し、`PropertiesChanged(kAudioPlugInPropertyDeviceList)` で host に通知。既存デバイスの IO は途切れない（デバイスごとに独立リング）。
  - host storage（`WriteToStorage`）で永続化し、coreaudiod 再起動後も維持。
- デバイス命名: #1 は既存互換（UID "OpenAudioDevice-1"、名前 "OpenAudio 16ch"）。#n (n≥2) は UID "OpenAudioDevice-n"、名前 "OpenAudio 16ch n"。
- ルーティング行列は App-as-mixer 原則（§4.2）どおり **App 側に保持**（driver へは押さない。F-D6 の「チャンネルマップ/ルーティング受領」は driver-as-mixer に転じる場合の将来拡張とする）。

### エンジン側

- ルーティング行列: ソース × バス の有効フラグ（アトミックスナップショット、NF-P2）。バスごとに capture コールバック内で合算。
- バス = ClockBridge + 仮想デバイス consumer IOProc の組。実行中に off-RT で生成・破棄し、アトミックなポインタ公開で RT へ渡す（グリッチなし）。
- CLI `openaudio run` に `--buses N` / `--route <src>=<bus,...>` を追加し、さらに stdin の対話コマンド（`buses` / `route` / `gain` / `pan` / `mute` / `stats`）で実行中の動的変更を検証可能にする。

### 検証手順

1. 新ドライバ再インストール（要 sudo）後、`'OAdc'`=3 で Audio MIDI Setup に 3 デバイス出現、=1 に戻して消えること。
2. `openaudio run --tap-system --buses 2` で各バスを `probe-vdev` し、ルーティングどおりの音が録れること。
3. 実行中に route/バス数を変更してアンダーラン・グリッチが出ないこと（統計で確認）。

## Phase 3 — UI・モニタリング

対応要件: F-U1〜U6, F-M1/M2, F-E4（チャンネル単位メーター）/ 受け入れ基準 Phase 3「非開発者が説明書なしでソース選択→録音→モニタリングまで到達できる」

### 構成

```
Tools/Sources/
├── OpenAudioEngine/    # 拡張: モニタリング・ControlPlane 移設・プロセス一覧・L/R メーター
└── OpenAudioApp/       # SwiftUI アプリ（MenuBarExtra + メインウィンドウ）
scripts/build-app.sh    # .app バンドル組み立て（Info.plist + ad-hoc 署名）
```

### 設計判断

- **モニタリング（F-M1/M2）**: キャプチャ aggregate の main sub-device は default output そのものなので、キャプチャ IOProc の **output バッファに選択バスのミックスを書き込む**方式を採る。同一クロック・SRC 不要・追加 IOProc 不要で最短レイテンシ。API: `setMonitor(busIndex: Int?, gainDB: Float)`。
- **フィードバック防止**: tap（システム全体/プロセス指定とも）は**自プロセスを必ず除外**（モニタ出力が再捕捉される帰還ループを断つ）。
- **ControlPlane はライブラリへ移設**（App からデバイス数制御を使うため）。CLI は移設先を import。
- **プロセス一覧 API（F-U3）**: tapcapture の実装をエンジンライブラリへ移植し public 化。
- **ソース変更はエンジン再起動で実現**（v1 簡素化。タップ PID のライブ差し替えは将来）。
- **メーターは L/R 独立で公開**（F-U4。従来は max(L,R) のみ）。
- **UI**: メニューバー常駐（LSUIElement）+ メインウィンドウ。ウィンドウは 3 ペイン: ソース（プロセス選択・gain/mute/pan）→ ルーティンググラフ（Canvas でノード・エッジ描画、クリックで route 切替、バス追加は制御プレーン連動）→ バス（L/R メーター・モニタートグル・録音）。
- **配布形態（開発中）**: `scripts/build-app.sh` が OpenAudio.app を組み立て（NSAudioCaptureUsageDescription / NSMicrophoneUsageDescription / LSUIElement、ad-hoc 署名）。正式署名・notarization は Phase 4。

### 検証手順

1. `scripts/build-app.sh` → OpenAudio.app 起動 → メニューバー出現 → ウィンドウでソース選択 → 録音 → モニタリング ON（人手確認）。
2. モニタリング ON + システム全体 tap でハウリング（帰還）が起きないこと。
3. 受け入れ基準の非開発者テストは手動。

## 以降のフェーズ（本計画のスコープ外）

- Phase 4: 署名・notarization・インストーラ
