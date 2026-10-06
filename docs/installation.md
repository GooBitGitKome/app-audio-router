# AppAudioRouter インストール・環境構築ガイド (Installation Guide)

本ドキュメントは、新しい開発環境や実行環境で `AppAudioRouter` をゼロからセットアップするための手順書です。

---

## 1. 必要環境と前提ソフトウェア

| ソフトウェア / ツール | 必要バージョン / 詳細 |
| :--- | :--- |
| **OS** | macOS Sonoma (14.2) 以降 |
| **Xcode / Command Line Tools** | Xcode 15.0+ (Swift 5.9+) |
| **パッケージマネージャ** | Homebrew (ループバックドライバの導入用) |
| **ループバックサブデバイス** | **BlackHole 2ch** (推奨) または ZoomAudioDevice |

> [!IMPORTANT]
> macOS の制約上、仮想マイク（Aggregate Device）を動的生成するためには、内部で音声の送受信を折り返すためのサブドライバが必要です。未インストールの場合は BlackHole 2ch のインストールを推奨します。

---

## 2. ダウンロード版をインストールする

配布ZIP `AppAudioRouter-macOS.zip` を展開し、フォルダ内の `AppAudioRouter.app` を `/Applications` にコピーして起動します。アプリはメニューバーとDockの両方に表示されます。

1. `AppAudioRouter.app` を `/Applications` へドラッグします。
2. `/Applications/AppAudioRouter.app` を開き、初回のマイク・システムオーディオ権限を許可します。
3. Dockアイコンを右クリックし、「オプション」>「Dockに追加」を選ぶと、終了後もDockに固定できます。
4. 終了する場合は、メニューバーの波形アイコンから **Quit** を選びます。仮想マイクはアプリ終了時にクリーンアップされます。

配布ZIPにはBrave用の `BrowserExtension` とこのインストールガイドも含まれます。GFNとBraveの入力を分ける拡張の読み込み方法は [利用マニュアル](usage.md#32-brave-と-geforce-now-で別々のマイクを使う) を参照してください。

この配布ビルドはDeveloper IDによる署名・Apple公証を行っていません。macOSが初回起動を止めた場合は、アプリをControlキーを押しながらクリックし「開く」を選択してください。

## 3. ソースからセットアップする

### ステップ 1: リポジトリのクローン
```bash
git clone <repository_url> app-audio-router
cd app-audio-router
```

### ステップ 2: ループバックサブドライバのインストール（未導入の場合）
Homebrew を使用して BlackHole 2ch をインストールします：
```bash
brew install blackhole-2ch
```
※ インストール後、CoreAudio を再起動するか Mac を再起動してドライバを有効化してください。

### ステップ 3: ビルド
#### 開発ビルド (CLI & テスト含む)
```bash
swift build
```

#### macOS アプリケーションバンドルのビルド（推奨）
付属のパッケージングスクリプトを実行し、Ad-hoc 署名付きの `.app` を生成します：
```bash
./scripts/package_app.sh
```
成功すると、カレントディレクトリに `AppAudioRouter.app` が作成されます。

---

## 4. 動作確認

### 1. 単体テストの実行
```bash
swift test
```
テスト件数はコードの更新により変わります。テストコマンドの終了コードが 0 であることを確認します。

### 2. CLI 診断の実行
```bash
swift run AppAudioRouterCLI diagnose
```
以下が確認されます：
- 選択されたループバックエンジン（BlackHole または ZoomAudioDevice）
- `AppAudioRouter Virtual Microphone` の検出とフォーマット
- 出力レンダラーから入力へのループバック伝送
- デスクトップタップのサンプリングレート同期

### 3. トーンパイプラインテスト（440Hz 伝送検証）
```bash
swift run AppAudioRouterCLI test-tone
```
440Hz サイン波が仮想マイク経由で録音され、最大サンプル約 60.0% (-8.5 dBFS) かつ歪みなくキャプチャされることを確認します。

---

## 5. アプリケーションの初回起動と権限設定

### アプリケーションの起動
```bash
open ./AppAudioRouter.app
```
メニューバー（画面右上）に波形アイコン（`waveform.circle.fill`）が表示されます。

### システム権限の許可
初回起動時、macOS から以下の権限ダイアログが表示されます。必ず**「許可」**を選択してください：
1. **マイクへのアクセス権限 (`NSMicrophoneUsageDescription`)**
   - 物理マイクの音声をキャプチャ・ミキシングするために必要です。
2. **システムオーディオ録音権限 (`NSAudioCaptureUsageDescription`)**
   - デスクトップ音声を Process Tap で取得するために必要です。
   - ※ macOS 14.2+ では「システム設定」>「プライバシーとセキュリティ」>「システムオーディオ録音」で手動確認・許可が可能です。

---

## 6. よくあるトラブルシューティング

### Q1: `No suitable loopback device found` というエラーが出る
- **原因**: BlackHole や Zoom 等の仮想オーディオドライバがシステムに存在しない。
- **対処**: `brew install blackhole-2ch` を実行し、OS を再起動するか `sudo killall coreaudiod` を実行して CoreAudio を再読み込みしてください。

### Q2: 起動しても仮想マイクがブラウザ（Chrome, Brave）に表示されない
- **原因**: アプリが起動していないか、仮想マイクの作成に失敗している。
- **対処**:
  1. `ps aux | grep AppAudioRouterApp` でアプリが常駐しているか確認。
  2. `swift run AppAudioRouterCLI devices` を実行し、`AppAudioRouter Virtual Microphone` が一覧に存在するか確認。
  3. ブラウザを一度再起動してオーディオ入力リストを再取得させてください。

### Q3: デスクトップ音声のゲージが動かない
- **原因**: 「システム設定」>「プライバシーとセキュリティ」の「システムオーディオ録音」権限が付与されていない。
- **対処**: システム設定で AppAudioRouter のオーディオ収録権限が ON になっているか確認してください。
