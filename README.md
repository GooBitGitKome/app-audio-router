# AppAudioRouter

macOS 14.2+ (Sonoma / Sequoia) 向けの常駐型オーディオ管理ユーティリティ（SoundSourceライクなツール）。
アプリケーション別の音量調整・ミュート・個別出力先ルーティング、複数マイクの同時利用・機器セット（Aggregate Mic）生成、およびデスクトップ音声／アプリ音声／マイク音声の仮想マイク送出（Zoom/Discord/Teams等への配信）を実現します。

---

## 🌟 特徴 (Features)

1. **安全でモダンなCoreAudio Process Tapアーキテクチャ**
   - 危険なカーネル拡張 (kext) やプロセスへのフッキング（コードインジェクション等）を一切不要とし、macOS 14.2+公式の **`AudioHardwareCreateProcessTap`** / **`kAudioHardwarePropertyProcessObjectList`** を使用。
   - SIP（System Integrity Protection）を無効化することなく、セキュアに動作。

2. **マルチマイクの同時利用 & リアルタイムミキシング (Multiple Mics Support)**
   - 接続されている複数の物理マイク（USBマイク、内蔵マイク、ヘッドセットマイク等）を個別検知。
   - 各マイク個別の音量調整、ミュート、リアルタイムVUメーター表示。
   - **複数マイクの同時仮想マイク送出（Live Multi-Mic Mixer）**: 複数のマイク音声を同時に仮想マイク（BlackHole等）へミックス送出し、ZoomやDiscord等で複数マイクの音声をまとめて配信可能。
   - **マイク機器セット（Combine Microphones / Aggregate Input）の自動生成**: 複数のマイクを束ねたCoreAudio機器セット（Aggregate Device）をワンクリックで構築し、システム入力として設定可能。

3. **アプリケーション単位の個別コントロール**
   - 音声出力中のプロセスを自動検知（アプリアイコン・名前・PID表示）。
   - アプリ個別の音量調整（0% 〜 150%）。
   - アプリ個別のミュート切替。
   - アプリ個別の出力先デバイス切り替え（例: Spotifyだけヘッドホン、ブラウザはスピーカー等）。
   - リアルタイムピークVUメーター表示。

4. **デスクトップ音声／アプリ音声／マイク音声のマイク化（Route to Mic）**
   - ボタン1つで特定アプリの音声、デスクトップ全体の音声、および複数マイクの音声を仮想マイク（BlackHole等）へ送出。
   - Zoom、Google Meet、Discord、Microsoft Teams、OBS等の通話・配信ソフトのマイク入力として即座に利用可能。

5. **機器セット（Multi-Output / Aggregate Mic）自動生成**
   - 「Audio MIDI設定」を開くことなく、アプリ内から複数の出力デバイス（例: ヘッドホン + 仮想マイク）や複数の入力デバイス（複数マイク）を束ねる機器セットをワンクリックで自動構築。

6. **メニューバー常駐UI (SwiftUI MenuBarExtra)**
   - Dockを占有せず、メニューバーアイコンから手軽に操作できるコンパクトなポップオーバーUI。

---

## 🚀 使い方 (Usage)

### 1. GUI アプリの起動 (`AppAudioRouter.app`)

ビルド済みのアプリケーションバンドルを起動します：

```bash
open AppAudioRouter.app
```

メニューバー（ステータスバー）右上に波形アイコン（`waveform.circle.fill`）が表示されます。クリックするとポップオーバーが開き、以下の操作が行えます：
- **Master Output / Master Input**: システム全体のデフォルトデバイスを変更
- **Desktop Audio to Mic**: デスクトップ音声全体を仮想マイクへ送出
- **Microphones**: 接続中の各物理マイクの音量・ミュート・VUメーター・仮想マイクへのミックス送出を個別制御
- **Applications**: 起動中の各アプリの音量・ミュート・出力先・マイク送出を制御
- **Combine Outputs...**: 複数出力デバイスを束ねたMulti-Outputデバイスを自動作成
- **Combine Microphones...**: 複数マイクを束ねたAggregate Microphoneデバイスを自動作成

### 2. コマンドラインツール (`AppAudioRouterCLI`)

ターミナルやスクリプトからオーディオデバイスやプロセスの確認・テストが行えます：

```bash
# 全オーディオデバイスの確認
swift run AppAudioRouterCLI devices

# 音声を接続しているプロセス一覧の確認
swift run AppAudioRouterCLI processes

# 指定PIDの音声をタップしてリアルタイムVUメーターを表示
swift run AppAudioRouterCLI tap --pid <PID>

# 2つ以上の出力デバイスを束ねたマルチアウトプットデバイスの作成
swift run AppAudioRouterCLI multi-output <UID_1> <UID_2>

# 2つ以上のマイクを束ねたアグリゲートマイクデバイス（機器セット）の作成
swift run AppAudioRouterCLI multi-input <MIC_UID_1> <MIC_UID_2>
```

---

## 🛠 ビルドとテスト (Build & Test)

### リリースビルド & アプリバンドル生成
```bash
./scripts/package_app.sh
```

### 単体テストの実行
```bash
swift test
```

---

## 📁 プロジェクト構成

```
app-audio-router/
├── Package.swift
├── AppAudioRouter.app/             // 生成されたmacOSアプリバンドル
├── scripts/
│   └── package_app.sh              // アプリバンドル生成スクリプト
├── Sources/
│   ├── AppAudioRouterCore/         // コアロジック (Library)
│   │   ├── Models/
│   │   │   ├── AudioDevice.swift           // デバイスモデル
│   │   │   ├── AudioProcess.swift          // プロセスモデル
│   │   │   └── RoutingRule.swift           // ルーティング設定
│   │   ├── Hardware/
│   │   │   ├── AudioDeviceManager.swift    // デバイス列挙・変更監視
│   │   │   ├── AudioProcessManager.swift   // 音声プロセス検出
│   │   │   └── AggregateDeviceManager.swift // 機器統合自動生成 (Output & Mic)
│   │   ├── Tap/
│   │   │   ├── ProcessTap.swift            // CoreAudio Process Tap管理
│   │   │   └── TapAggregateDevice.swift    // Tap用プライベートAggregateデバイス
│   │   └── Engine/
│   │       ├── AudioRoutingEngine.swift    // ルーティング・ミキシングエンジン
│   │       ├── MicrophoneInputSource.swift // マイク入力キャプチャ・DSP
│   │       ├── AudioOutputRenderer.swift   // デバイス再生レンダラー
│   │       ├── AudioBufferProcessor.swift  // 音量・ミュート・VUメーターDSP
│   │       └── AudioRingBuffer.swift       // スレッドセーフ循環バッファ
│   ├── AppAudioRouterApp/          // 常駐メニューバーUI (SwiftUI)
│   │   ├── AppAudioRouterApp.swift         // エントリーポイント
│   │   ├── AppState.swift                  // Observableステート
│   │   └── Views/
│   │       ├── MenuBarContentView.swift    // メインポップオーバー (Mic & App UI)
│   │       ├── ProcessRowView.swift        // 各アプリのコントロール行
│   │       └── LevelMeterView.swift        // リアルタイムレベルメーター
│   └── AppAudioRouterCLI/          // CLIデバッグ・管理ツール
│       └── main.swift
└── Tests/
    └── AppAudioRouterTests/
        ├── AudioDeviceManagerTests.swift
        ├── AggregateDeviceManagerTests.swift // マルチマイク機器セット・マイクテスト
        ├── ProcessTapTests.swift
        └── AudioBufferProcessorTests.swift
```

---

## 🔒 権限について (Permissions)

macOS Sonoma / Sequoiaのセキュリティ仕様により、プロセス音声のキャプチャおよびルーティングには「**マイク**」および「**画面収録・システムオーディオ収録**」のシステム権限が必要です。
初回実行時にmacOSのダイアログが表示された場合は「許可」を選択してください。
