# AppAudioRouter ロードマップ (Roadmap)

本ドキュメントは、`AppAudioRouter` の実装状況、現在進行中のタスク、および将来の検討事項をまとめたものです。

---

## 1. 実装済み (Implemented)

- [x] **エフェメラル仮想マイク（`AppAudioRouter Virtual Microphone`）の動的構築と破棄**
  - アプリ起動時に利用可能なループバックエンジンから Aggregate Device を生成し、終了時にクリーンアップ。
- [x] **デスクトップ音声キャプチャ (Process Tap) と自プロセス除外 (Self-Exclusion)**
  - フィードバックループによる過大入力歪み・音割れを 100% 遮断。
- [x] **48,000Hz サンプリングレート同期**
  - TapAggregateDevice における HAL ネイティブなリサンプリングにより、音飛びやピッチ狂いを解消。
- [x] **複数物理マイクのリアルタイムミキシング (MicrophoneInputSource)**
  - モノラル・ステレオ・Planar マルチチャンネルマイクの正確なステレオマッピングと音量・ミュート制御。
- [x] **仮想マイク自己テスト録音・再生システム (VirtualInputTester)**
  - 仮想マイクの入力を直接 WAV ファイルに録音し、スピーカーからセルフ再生する機能。
- [x] **デスクトップ音声レベルメーター（Gauge）**
  - リアルタイムピークメーターおよび描画 ON / OFF 切替機能。
- [x] **機器セット（Multi-Output / Aggregate Mic）の自動生成機能**
- [x] **CLI 管理・診断・テストコマンド群 (`AppAudioRouterCLI`)**

---

## 2. 進行中 (In Progress)

- [ ] **リポジトリ整備とドキュメント体系化（本タスク）**
  - 人間および AI エージェントが継続的に安全開発できる標準ドキュメント・運用の確立。

---

## 3. 予定 (Planned)

- [ ] **スタンドアロン AudioServerPlugIn の検討 (TBD / 要調査)**
  - 現在は既存のループバックドライバ（BlackHole 等）をサブデバイスとして利用しているが、純粋にドライバレスで完結する AudioServerPlugIn 構成の実現可能性調査。
- [ ] **CI / 自動テストワークフローの構築**
  - GitHub Actions による `swift build` および `swift test` の自動化。
- [ ] **swift-format / SwiftLint による静的解析の導入**

---

## 4. アイデア・検討事項 (Ideas)

- [ ] **システム起動時の自動ログイン起動 (Launch at Login) オプション**
- [ ] **グローバルショートカットキーによるデスクトップ音声ミュート切替**
- [ ] **イコライザー / 簡易リミッターなどの拡張 DSP エフェクト**
