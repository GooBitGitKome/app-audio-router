# AppAudioRouter

**Rust migration preview:** A Cargo workspace now provides a native Rust audio backend, CLI, and AppKit application. Swift remains the default until hardware/UI acceptance passes. See [Rust build and migration status](docs/rust-migration.md).

macOS 14.2+ (Sonoma / Sequoia) 向けのメニューバー常駐型オーディオルーター＆ミキサーです。  
デスクトップ全体の再生音声と複数の物理マイク音声をリアルタイムにミキシングし、通話・配信アプリ（Zoom、Brave、Discord、Google Meet、Teams等）から直接選択できる一時的な仮想入力マイク（`AppAudioRouter Virtual Input`）へ送出します。

---

## 🌟 主な機能 (Features)

1. **アプリ起動時のみ現れる一時的仮想マイク (Ephemeral Virtual Input)**
   - アプリ起動中のみ macOS の CoreAudio Aggregate Device（機器セット）として `AppAudioRouter Virtual Input` を自動生成。
   - アプリ終了時には自動破棄されるため、使わないときに余計なデバイスが残りません。
   - 会議アプリやブラウザ（Zoom、Brave等）の「マイク設定」から即座に選択可能です。

2. **デスクトップ音声のリアルタイムマイク化 (Desktop Audio to Virtual Input)**
   - macOS 14.2+ 公式の **CoreAudio Process Tap API** を使用し、カーネル拡張 (kext) や危険なプロセスフックなしでデスクトップ音声をキャプチャ。
   - 自プロセス除外機構により、無限ループ（ハウリング／自己フィードバック）を確実に防止。
   - **独立したデスクトップ音声レベルメーター** と **ワンクリック送出切替 (ON/OFF)** を装備。

3. **マルチマイクの同時検知 & ミキシング (Physical Mic Mixer)**
   - 内蔵マイク、USBマイク、ヘッドセット等の複数物理マイクを自動検出。
   - 各マイクのリアルタイムVUメーター、音量スライダー、ミュート、仮想マイク送出スイッチを個別制御。

4. **仮想マイク録音・再生テスト機能 (Virtual Input Self-Test)**
   - 仮想マイクへ送出されているミックス音声（デスクトップ音声＋物理マイク音声）をアプリ内で直接テスト録音。
   - 録音後、デフォルト出力スピーカーからワンクリックで再生し、音質や音量バランスを事前確認可能。

5. **メニューバー操作 + Dock対応UI (SwiftUI MenuBarExtra)**
   - メニューバーから音声設定と終了を操作でき、通常のアプリと同様にDockへ追加できます。

6. **CLI診断・保守ツール (`AppAudioRouterCLI`)**
   - ターミナルからオーディオデバイス一覧表示、システム診断（`diagnose`）、テストトーン送出（`test-tone`）等を実行可能。

---

## 📋 必要環境 (Requirements)

- **OS**: macOS 14.2 (Sonoma) 以上（macOS 15 Sequoia 対応確認済）
- **アーキテクチャ**: Apple Silicon (M1/M2/M3/M4) または Intel Mac
- **開発ツール**: Swift 5.9+ / Xcode 15+
- **ループバックドライバ**: BlackHole 2ch（推奨）または ZoomAudioDevice（いずれか1つ）
  - ※仮想マイクのサブデバイスとして内部的に使用されます。
- **必要権限**:
  - 「マイク」（物理マイクキャプチャ用）
  - 「画面収録・システムオーディオ収録」（デスクトップ音声 Process Tap キャプチャ用）

---

## 📥 インストール (Installation)

### ダウンロードしてインストール
配布用ZIPは `dist/AppAudioRouter-macOS.zip` です。展開後、`AppAudioRouter.app` を `/Applications` にコピーして起動してください。詳細は [docs/installation.md](docs/installation.md) を参照してください。

### 配布物の作成
```bash
./scripts/package_release.sh
```

詳細は [docs/installation.md](docs/installation.md) を参照してください。

---

## ⚡ クイックスタート (Quick Start)

1. **アプリの起動**:
   ```bash
   open AppAudioRouter.app
   ```
2. **メニューバーアイコンの確認**:
   - Dockにアプリのアイコン、メニューバー右上に波形アイコン（`waveform.circle.fill`）が表示されます。
   - クリックしてポップオーバーを開きます。
3. **仮想マイクの確認**:
   - ポップオーバーに `AppAudioRouter Virtual Microphone` が表示されることを確認します。
4. **音声送出の開始**:
   - デスクトップ音声を送出する場合は **Desktop Audio to Virtual Mic** を ON にします。
   - 物理マイク音声も一緒に送出する場合は、該当マイクの **To Virtual Mic** を ON にします。
5. **通話アプリ / ブラウザの設定**:
   - Gemini をブラウザで使う場合、サイトのマイクとして **`BlackHole 2ch`** を選択します。`AppAudioRouter Virtual Microphone` が表示され、入力レベルが動く環境ではそちらも選べます。
6. **Dockに固定・終了**: Dockのアイコンを右クリックして「オプション」>「Dockに追加」を選択します。終了はメニューバーの波形アイコンから **Quit** を選びます。

詳細は [docs/usage.md](docs/usage.md) を参照してください。

---

## 📚 ドキュメント (Documentation)

プロジェクトの詳細な技術資料および仕様は `docs/` ディレクトリに整備されています：

- [システム仕様書 (docs/specification.md)](docs/specification.md) - 機能要件、非機能要件、入出力仕様、既知の制約
- [アーキテクチャ設計書 (docs/architecture.md)](docs/architecture.md) - コンポーネント構成、Mermaidデータフロー図、リアルタイムオーディオ安全性
- [インストール・環境構築ガイド (docs/installation.md)](docs/installation.md) - 前提環境、ビルド手順、権限設定、トラブルシューティング
- [利用マニュアル (docs/usage.md)](docs/usage.md) - 一般ユーザー向け操作方法、Brave/Zoom設定手順
- [Brave・GeForce NOWのマイク分離と復旧記録](docs/brave-gfn-microphone-recovery.md) - 原因の確認結果、更新・作り直し時の復旧手順と実機確認
- [開発者ガイド (docs/development.md)](docs/development.md) - 開発手順、テスト実行、CoreAudioリアルタイムスレッドの制約
- [バージョニング方針 (docs/versioning.md)](docs/versioning.md) - SemVer 2.0.0 運用基準
- [リリース手順書 (docs/release-process.md)](docs/release-process.md) - リリース前チェックリスト、タグ打ち、配布手順
- [開発ロードマップ (docs/roadmap.md)](docs/roadmap.md) - 実装済み機能、進行中、今後の機能候補

---

## 💻 開発・テスト (Development & Testing)

```bash
# 単体テストの実行
swift test

# CLIツールの起動確認
swift run AppAudioRouterCLI devices

# オーディオパイプラインの自己診断
swift run AppAudioRouterCLI diagnose
```

詳細は [docs/development.md](docs/development.md) を参照してください。

---

## 🤝 コントリビューション (Contributing)

プルリクエストや Issue の起票を歓迎します。  
開発への参加ルールやコミット規約については [CONTRIBUTING.md](CONTRIBUTING.md) を確認してください。

---

## 🤖 AI 支援開発について (AI-Assisted Development)

本プロジェクトでは AI コーディングエージェント（LLM）を活用した開発手法を取り入れています。  
AI 利用方針および検証ルールについては [AI_USAGE.md](AI_USAGE.md) を、AI エージェント向けの作業規約は [AGENTS.md](AGENTS.md) を参照してください。

---

## 📌 バージョン & 変更履歴 (Version & Changelog)

- 現在のバージョン: **1.1.0**
- 変更履歴: [CHANGELOG.md](CHANGELOG.md)

---

## 📄 ライセンス (License)

[LICENSE](LICENSE)（※現在ライセンス形態は TBD / 要確認 です。商用利用・再配布については管理者へお問い合わせください。）
