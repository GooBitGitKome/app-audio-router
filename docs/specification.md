# AppAudioRouter 仕様書 (Software Specification)

本ドキュメントは、`AppAudioRouter` の現行実装に基づく正式なソフトウェア仕様書です。

---

## 1. システム概要と目的

### 1.1 システムの目的
`AppAudioRouter` は、macOS 14.2 以降の CoreAudio HAL (Hardware Abstraction Layer) および Process Tap API を活用し、システム内のオーディオストリームを柔軟にキャプチャ、ミキシング、ルーティングするメニューバー常駐型の macOS アプリケーションです。
特に、カーネル拡張 (kext) やシステム整合性保護 (SIP) の無効化を必要とせず、**デスクトップ音声および複数マイクを統合した仮想マイク（`AppAudioRouter Virtual Microphone`）の動的提供** を主目的としています。

### 1.2 対象ユーザー
- macOS 上で Web 会議（Zoom, Google Meet, Microsoft Teams 等）やライブ配信（OBS, Discord 等）を行うユーザー。
- PC の内部再生音（YouTube, アプリ効果音, システム音）を通話マイクとして相手に送信したいユーザー。
- 複数の物理マイク（USB マイク、内蔵マイク等）を同時に使用して通話や録音を行いたいユーザー。

### 1.3 主なユースケース
1. **デスクトップ音声の仮想マイク配信**: ブラウザやメディアプレイヤーの音声を、通話アプリ（Brave, Chrome, Zoom 等）の入力マイクへ劣化・音割れなく直接ルーティングする。
2. **物理マイクのリアルタイムミキシング**: 接続された物理マイクの音量を調整し、デスクトップ音声とミックスして仮想マイクへ同時送出する。
3. **仮想マイク自己テスト録音・再生**: 仮想マイクに実際に流れている音声をアプリ単体で録音（WAV 形式）し、スピーカーから再生して音質や音量を即座に自己検証する。
4. **機器セット（Multi-Output / Aggregate Mic）のワンクリック構築**: macOS の「Audio MIDI 設定」を開くことなく、複数デバイスの同時出力・同時入力を自動生成する。

---

## 2. 動作環境・システム要件

| 項目 | 要件 / 制約 |
| :--- | :--- |
| **対象 OS** | macOS 14.2 (Sonoma) 以降 |
| **アーキテクチャ** | Apple Silicon (arm64) / Intel (x86_64) |
| **開発言語 / ランタイム** | Swift 5.9+ |
| **UI フレームワーク** | SwiftUI (MenuBarExtra, Observation) |
| **低レイヤ API** | CoreAudio, AudioToolbox, AVFoundation, Accelerate (vDSP) |
| **外部依存ライブラリ** | なし（Pure Apple Frameworks のみで構成） |
| **必要なシステム権限** | マイクアクセス (`NSMicrophoneUsageDescription`)<br>システムオーディオ収録 (`NSAudioCaptureUsageDescription`) |
| **前提となるサブドライバ** | CoreAudio Aggregate Input Device を形成するための双方向ループバックエンジン（BlackHole, ZoomAudioDevice 等のいずれか） |

---

## 3. 機能要件 (Functional Requirements)

### 3.1 エフェメラル仮想マイク管理 (Ephemeral Virtual Microphone)
- **デバイス名**: `AppAudioRouter Virtual Microphone`
- **デバイスUID**: `com.appaudiorouter.virtualmic.default`（決定論的固定UID。アプリ再起動時にもUIDが不変に保たれ、BraveやChrome等のWebRTCブラウザがデバイストークンを見失って物理マイクへサイレントフォールバックするのを防止）
- **ライフサイクル**:
  - アプリケーション起動時に、システム内に存在する利用可能なループバックエンジン（BlackHole 優先、次いで ZoomAudioDevice 等）を検出し、それを内包する Aggregate Input Device を動的に生成。
  - OS のオーディオデバイス一覧に正式な入力マイクとして登録され、Chrome, Brave, Zoom, Teams 等のブラウザやアプリから選択可能となる。
  - アプリケーション終了（`NSApplication.terminate` / `deinit`）時に、生成した Aggregate Device を CoreAudio HAL から完全に破棄・削除。OS 上に不要な仮想ドライバを残さない。
  - 起動時と手動セットアップで同じソースのデバイスが既に存在する場合は再利用する。作成時に macOS の標準入力デバイスは自動変更しない。
- **UI 表示フィルタ・ブラウザ互換性**:
  - ユーザー混乱を防ぐため、内部サブデバイスとして利用している第三者ドライバ（ZoomAudioDevice, BlackHole 等）は、Master Output / Master Input のセレクタから自動的に除外・非表示化。
  - Chromium系ブラウザ（Brave, Google Chrome）における CoreAudio AUHAL の集約デバイス認識制限に配慮し、ブラウザ側で集約デバイスが表示されない環境では直接ループバックサブデバイス（`BlackHole 2ch`）を指定して同等機能が得られる設計を担保。

### 3.2 デスクトップ音声の仮想マイクルーティング (Desktop Audio to Mic)
- **キャプチャ機構**: `CATapDescription(stereoGlobalTapButExcludeProcesses:)` によるグローバルタップ。
- **ブラウザ音声入力の用途**: YouTube 等の再生音をブラウザ上の音声入力へ渡す。アプリはデスクトップ音声を Process Tap で取得し、双方向の入出力を持つループバックデバイスの出力へ送出する。ブラウザ側ではループバックデバイス（BlackHole の場合は `BlackHole 2ch`）をマイクとして選ぶ。Aggregate Input Device がブラウザに表示される場合は `AppAudioRouter Virtual Microphone` も利用できる。
- **起動条件と状態表示**: ループバックデバイスに有効な出力チャンネルがあり、タップと出力レンダラーの開始に成功した場合に限りルーティングを有効状態とする。起動に失敗した場合は UI を有効表示にしない。
- **フィードバックループ防止機構 (Self-Exclusion)**:
  - 自プロセス（`AppAudioRouter`）の `AudioObjectID` を自動取得し、グローバルタップの除外リストに常時追加。
  - アプリが仮想マイクへレンダリングした音声や、テスト再生音が再度キャプチャされて増幅・発散する正のフィードバックループ（音割れ・強烈な矩形波ノイズ）を完全に防止。
- **アプリ単位の除外**:
  - UI で選択したアプリの Bundle ID を保存し、タップ開始時に一致する CoreAudio プロセス（Chromium helper を含む）を除外する。
  - 除外設定変更時は稼働中のタップを再作成する。CoreAudio プロセスIDがまだ存在しないアプリは未解決として表示し、タップから除外できない。
  - YouTube と Gemini Live の音声を別々に扱う場合は、YouTube を Safari、Gemini Live を Chrome で再生し、Chrome を除外する構成を案内する。
- **サンプリングレート同期**:
  - タップのアグリゲートデバイス（`TapAggregateDevice`）生成時に、公称サンプリングレート（`kAudioDevicePropertyNominalSampleRate`）を出力先デバイス（48,000Hz）と一致させ、CoreAudio HAL 内で同期リサンプリング。バッファアンダーランによる音飛びやピッチの狂いを排除。
- **音量・ミュート制御**:
  - スライダーによる音量倍率制御（0.0 〜 2.0）。
  - ミュート切替機能。
- **デスクトップ音声レベルメーター (Gauge)**:
  - リアルタイムピークメーター表示（0.0 〜 1.0）。
  - メーター更新自体の ON / OFF 切替ボタン（不要時の描画負荷低減）。

### 3.3 物理マイク管理・ミキシング (Microphone Mixer)
- **検知**: システムに接続されている純粋な物理マイク（内蔵マイク、USB マイク、オーディオインターフェース等）を自動列挙。
- **個別制御**:
  - 各マイク個別の音量調整（0.0 〜 2.0）、ミュート切替。
  - 各マイク個別のリアルタイム VU レベルメーター。
  - **Route to Virtual Mic**: 個々のマイク音声を仮想マイクへ送出するかのトグルスイッチ。
- **バッファ処理**:
  - モノラルマイクは自動的に左右両チャンネルへステレオ展開。
  - Planar (Non-interleaved) および Interleaved 形式の両方を正確にハンドリングし、チャンネル破損を防止。

### 3.4 仮想マイク録音・再生自己テスト (VirtualInputTester)
- **機能概要**:
  - 仮想マイクから入力されている音声を実際にキャプチャし、WAV ファイルとして保存した上で、デフォルトスピーカーから再生して音質をセルフチェックできる機能。
- **動作フロー**:
  1. 「Record Test」押下で録音開始（デフォルト 5.0 秒、CLI では秒数指定可能）。
  2. CoreAudio IOProc により 48kHz / 2ch Float32 でサンプルをキャプチャ。
  3. 録音中は経過時間とピークメーターをリアルタイム表示。
  4. 録音完了後、一時ディレクトリ（`virtual_input_test.wav`）に 16-bit PCM WAV ファイルを生成。
  5. 自動または手動で `AVAudioPlayer` を用いてスピーカーから再生。
  6. 再生完了後、再録音（Re-record）やクリアが可能。

### 3.5 機器セットの自動生成 (Aggregate Devices)
- **Multi-Output Device**: 複数の出力デバイスを選択し、同一の音声をミラーリング再生する機器セットを CoreAudio HAL レベルで即座に生成。
- **Aggregate Microphone**: 複数のマイクを選択し、1 つのマルチチャンネル入力マイクとして束ねる機器セットを生成。

---

## 4. 非機能要件 (Non-Functional Requirements)

1. **超低レイテンシ・リアルタイム性**:
   - オーディオコールバック内での排他制御には `os_unfair_lock` を使用し、優先度逆転やブロッキングを防止。
   - `AudioRingBuffer` による循環バッファリングにより、最短レイテンシでストリームを転送。
2. **音質保護・クリッピング防止**:
   - 複数ストリームのミックス時、Accelerate フレームワークの `vDSP_vclip` を用いて `[-1.0, 1.0]` の範囲へ安全にクランプ。デジタル歪みの発生を抑制。
   - バッファオーバーフロー時は最古のフレームを安全に破棄し、ストリームの継続性を最優先。
3. **メモリ・リソース効率**:
   - メニューバー常駐ツールとして最小限のフットプリント（メモリ数十 MB 程度）。
   - 不要なポーリングを排除し、CoreAudio プロパティリスナーおよび通知駆動の設計。

---

## 5. 入出力およびデータ形式

| コンポーネント | 入力データ形式 | 内部処理形式 | 出力データ形式 |
| :--- | :--- | :--- | :--- |
| **Desktop Tap** | HAL システム音声 (44.1k / 48kHz, Float32) | 48kHz, 2ch, Float32 | AudioRingBuffer (48kHz, 2ch) |
| **Physical Mic** | ハードウェア PCM (Float32, Interleaved/Planar) | 48kHz, 2ch, Float32 (vDSPゲイン) | AudioRingBuffer (48kHz, 2ch) |
| **Renderer** | AudioRingBuffer (Float32) | Float32 加算ミックス + vDSP クランプ | ループバック出力 (48kHz, 2ch, Float32) |
| **Tester (WAV)** | 仮想マイク入力 (Float32) | [-1.0, 1.0] クランプ + 16-bit PCM 変換 | RIFF WAVE (48kHz, 16-bit, 2ch) |

---

## 6. 既知の制限事項 (Known Limitations)

1. **ループバックエンジンの依存**:
   macOS はカーネルレベルのカスタム AudioServerPlugIn なしには、純粋なソフトウェア入力デバイスを単独作成できません。そのため、内部サブデバイスとして既存の仮想オーディオドライバ（BlackHole, ZoomAudioDevice 等）が 1 つ以上インストールされている必要があります。
2. **ブラウザ側のデバイス列挙**:
   ブラウザや WebRTC サイトが Aggregate Input Device を列挙しない環境があります。その場合、ブラウザの入力デバイス選択肢に表示されるループバックデバイスを選ぶ方法があります。ブラウザごとの列挙動作は [UNKNOWN] であり、実機環境で確認が必要です。
3. **macOS 14.1 以前の非対応**:
   `CATapDescription` のプロセス除外付きグローバルタップ API は macOS 14.2 以降に限定されています。
4. **アプリケーション個別音量一覧機能の非表示**:
   過去の仕様ではアプリケーション個別音量リスト（`ProcessRowView`）が存在していましたが、ユーザーの要望によりメニューバー UI からは削除されています（内部 Core ロジックは残存）。
