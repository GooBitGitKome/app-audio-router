# AppAudioRouter 開発者ガイド (Development Guide)

本ドキュメントは、`AppAudioRouter` のコードベースを変更・拡張・保守する開発者（人間および AI エージェント）向けの開発ガイドラインです。

---

## 1. 開発環境

- **OS**: macOS Sonoma (14.2) 以降
- **IDE**: Xcode 15.0+ または VS Code / Cursor / Antigravity IDE (Swift 拡張機能)
- **Toolchain**: Apple Swift 5.9+
- **Build System**: Swift Package Manager (`Package.swift`)

---

## 2. ビルドと実行

### 2.1 コマンドラインでのビルド
```bash
# Debug ビルド (全ターゲット)
swift build

# Release ビルド
swift build -c release
```

### 2.2 CLI ツールの実行
デバッグや動作確認には、ビルドが高速な CLI ターゲットを活用します：
```bash
# 全デバイス情報
swift run AppAudioRouterCLI devices

# 音声パイプライン自己診断
swift run AppAudioRouterCLI diagnose

# 440Hz サイン波伝送テスト
swift run AppAudioRouterCLI test-tone

# 仮想マイク録音・再生テスト (引数: 秒数)
swift run AppAudioRouterCLI test-virtual-mic 3
```

### 2.3 macOS App Bundle のパッケージング
```bash
./scripts/package_app.sh
```
このスクリプトは以下を自動実行します：
1. `swift build -c release --product AppAudioRouterApp` による最適化バイナリ生成
2. `AppAudioRouter.app` ディレクトリ階層と `Info.plist` の構築
3. `codesign --force --deep --sign -` による Ad-hoc 署名

---

## 3. テストの実行

### 3.1 ユニットテスト (`swift test`)
```bash
swift test
```
- `AggregateDeviceManagerTests`: アグリゲート入力デバイスの動的生成とクリーンアップ、マイクソースのライフサイクル。
- `AudioBufferProcessorTests`: 音量スケーリング、ミュート、リングバッファの循環読み書き。
- `AudioDeviceManagerTests`: CoreAudio デバイス列挙。
- `ProcessTapTests`: プライベート Aggregate Device の生成・破棄、プロセス一覧の取得。

### 3.2 統合・パイプライン検証テスト
ハードウェアや CoreAudio HAL と連動する検証は CLI 診断コマンドを利用します：
```bash
# 仮想マイクのサンプリングレート同期・ループバック導通・自プロセス除外確認
swift run AppAudioRouterCLI diagnose
```

---

## 4. アーキテクチャ上の実装ルール（重要）

### 4.1 リアルタイムオーディオ処理 (IOProc) の鉄則
`AudioDeviceIOProc` や `AudioDeviceIOBlock` の内部では、以下の処理を**絶対に行ってはなりません**：
- **メモリ割り当て / 解放** (`malloc`, `free`, Swift の配列リアロケーション等)
- **ブロッキングロック** (`NSLock`, `pthread_mutex`, セマフォ等)。排他制御が必要な場合は必ず `os_unfair_lock` を使用してください。
- **ファイル I/O、ネットワーク I/O、Objective-C メッセージ送信の多用**
- **Swift Concurrency (`Task`, `await`) の起動**

### 4.2 フィードバックループ防止 (Self-Exclusion)
`CATapDescription(stereoGlobalTapButExcludeProcesses:)` を呼び出す際は、必ず `ProcessTap.getProcessObjectIDs()` を含めてください。
これを行わないと、アプリ自身が出力した音がグローバルタップで無限ループし、数ミリ秒で強烈な音割れ・歪みノイズが発生します。

### 4.3 サンプリングレート同期 (48,000Hz)
CoreAudio HAL の TapAggregateDevice は、作成直後に `kAudioDevicePropertyNominalSampleRate` を 48000.0 に設定してください。
サンプリングレートが一致していないと、リングバッファがアンダーランを起こし、音飛びやピッチの狂いが生じます。

### 4.4 バッファオーバーフローとクランプ
- リングバッファ（`AudioRingBuffer`）がいっぱいになった場合、`write` 側は最古の未読フレームを破棄して `readIndex` を進めます。これにより、レイテンシの蓄積やバッファ詰まりを防止します。
- 複数ストリームの加算後には、Accelerate フレームワークの `vDSP_vclip` を用いて Float サンプルを `[-1.0, 1.0]` にクランプしてください。

---

## 5. ディレクトリ構造

```
app-audio-router/
├── Package.swift                       // SPM マニフェスト
├── AppAudioRouter.app/                 // 生成されたアプリケーションバンドル (git ignored)
├── scripts/
│   └── package_app.sh                  // リリースパッケージングスクリプト
├── Sources/
│   ├── AppAudioRouterCore/             // コアライブラリ (CoreAudio HAL, DSP, Tap)
│   │   ├── Models/                     // デバイス・プロセス等のデータ構造
│   │   ├── Hardware/                   // HAL デバイス・集約デバイス管理
│   │   ├── Tap/                        // CATapDescription / プライベートタップ集約
│   │   └── Engine/                     // ルーティング、ミキシング、DSP、テスト録音
│   ├── AppAudioRouterApp/              // SwiftUI メニューバーアプリケーション
│   │   ├── AppAudioRouterApp.swift     // @main エントリーポイント
│   │   ├── AppState.swift              // @Observable な全体状態
│   │   └── Views/                      // メニューバー UI コンポーネント
│   └── AppAudioRouterCLI/              // CLI 管理・診断・テストツール
│       └── main.swift                  // CLI エントリーポイント
├── Tests/
│   └── AppAudioRouterTests/            // XCTest ユニットテスト群
└── docs/                               // 仕様・アーキテクチャ・運用ドキュメント群
```

---

## 6. 依存関係の追加方針

- **基本方針**: **外部サードパーティライブラリ（CocoaPods、外部 Swift パッケージ等）への依存は原則禁止**とします。
- **理由**: 低レイヤのオーディオ制御やメニューバー UI は、Apple 公式の SDK（CoreAudio, AudioToolbox, Accelerate, SwiftUI）のみで完結可能であり、外部依存を増やさないことが長期的な保守性とセキュリティの担保に直結するためです。
