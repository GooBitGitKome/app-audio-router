# AppAudioRouter 利用マニュアル (User Guide)

本ドキュメントは、エンドユーザー向けに `AppAudioRouter` の操作方法、機能、および通話ソフト（Zoom, Google Meet, Brave/Chrome）との連携手順を説明します。

---

## 1. 起動と終了

### 1.1 起動
アプリケーション（`AppAudioRouter.app`）をダブルクリックまたはターミナルから起動します：
```bash
open AppAudioRouter.app
```
起動すると、macOS のメニューバー（画面右上の時計や Wi-Fi の並び）に波形アイコン（`waveform.circle.fill`）が表示されます。

> [!NOTE]
> AppAudioRouter はメニューバー常駐アプリ（Dock に表示されない Accessory アプリ）です。

### 1.2 終了
メニューバーの波形アイコンをクリックし、ポップオーバー最下部の **「Quit」** ボタンをクリックします。
アプリが終了すると、公開されていた `AppAudioRouter Virtual Microphone` は OS から自動的に削除・クリーンアップされます。

---

## 2. メニューバーの基本操作

メニューバーアイコンをクリックすると、以下の各セクションが並んだポップオーバー画面が開きます。

### 2.1 Master Section (デフォルトデバイスの選択)
- **Master Output**: システム全体の標準音声出力（MacBook のスピーカー、ヘッドホン、外部ディスプレイ等）をプルダウンから切り替えます。
- **Master Input**: システム全体の標準音声入力（物理マイク、または AppAudioRouter Virtual Microphone）を切り替えます。

### 2.2 Desktop Audio to Virtual Mic (デスクトップ音声の送出)
Mac 上で鳴っているすべての音（YouTube, BGM, ゲーム音, 効果音等）を仮想マイクへ送出するカードです。

- **ON / OFF スイッチ**: 右上のトグルスイッチで送出の有効/無効を切り替えます。
  - 送出中は緑色の「LIVE」または音声シグナル検出時に「LIVE • SIGNAL」バッジが表示されます。
- **Gauge (レベルメーター)**:
  - デスクトップ音声のリアルタイム音量を緑/黄/赤のバーで表示します。
  - **Gauge: ON / OFF ボタン**: メーターの描画を停止して負荷を下げたい場合にクリックします。
- **Volume スライダー**: 仮想マイクへ送るデスクトップ音声の音量を 0% 〜 200% の範囲で調整できます。
- **Mute ボタン**: 送出中のデスクトップ音声だけを一時的に無音（ミュート）にします。

### 2.3 Microphones (物理マイクのミキシング)
接続されている物理マイク（MacBook 内蔵マイク、USB マイク等）が一覧表示されます。

- **VU メーター**: 各マイクの入力レベルをリアルタイム表示。
- **Slider**: 各マイクの入力ゲイン（音量）を個別に調整。
- **Mute**: 特定のマイクを一時的にミュート。
- **Route to Virtual Mic (緑色アイコン)**:
  - このボタンを ON にすると、そのマイクの音声が仮想マイク（`AppAudioRouter Virtual Microphone`）へミックス送出されます。
  - デスクトップ音声と物理マイク音声を同時に ON にすることで、**「BGM を流しながら自分の声を通話マイクに流す」** ことが可能です。

### 2.4 Test Virtual Mic (録音・再生テスト)
仮想マイクに実際に流れている音声が相手にどのように聞こえているかを、通話相手なしで自分一人で確認できるテスト機能です。

1. **「Record (5s)」ボタンをクリック**:
   - 仮想マイクからの音声を 5 秒間キャプチャします。
   - 録音中は経過秒数（例: `Recording 2.4s / 5.0s`）と入力レベルメーターが表示されます。
2. **自動再生**:
   - 5 秒間の録音が完了すると、直ちに Mac のデフォルトスピーカーから録音された音声が再生されます。
   - 音割れやノイズがないか、音量が適切かを確認できます。
3. **録音完了後の操作**:
   - **Play**: もう一度テスト録音を再生します。
   - **Re-record**: 再度録音をやり直します。
   - **Clear**: 一時録音データを消去してリセットします。

### 2.5 Combine Devices (機器セットの作成)
- **Combine Outputs...**: 複数のスピーカーやヘッドホンを束ねて同時に同じ音を鳴らす「Multi-Output Device」を作成します。
- **Combine Microphones...**: 複数のマイクを 1 つに束ねた「Aggregate Microphone」を作成します。

---

## 3. Web会議・ブラウザとの連携設定

### 3.1 Brave / Google Chrome で利用する場合
1. AppAudioRouter を起動し、YouTube 等の再生を始めて「Desktop Audio to Virtual Mic」のレベルメーターが反応することを確認します。
2. ブラウザのサイト設定でマイク利用を許可し、Gemini の音声入力または通話画面のマイク設定を開きます。
3. **マイク入力** で **`BlackHole 2ch`** を選択します。AppAudioRouter はデスクトップ音声をこのデバイスの出力へ送り、BlackHole の入力を Gemini のマイクとして使います。
4. `BlackHole 2ch` が表示されない場合は、ブラウザを再起動して再確認してください。`AppAudioRouter Virtual Microphone` が表示される場合はそれも選択できますが、ブラウザによっては Aggregate Input Device を列挙できないことがあります。
5. ブラウザの入力レベル表示で音声を確認してください。アプリのデスクトップメーターはタップで音を取得したことを示しますが、ブラウザがその入力デバイスを使っていることまでは示しません。メーターが動かない場合は macOS の「プライバシーとセキュリティ」>「画面収録とシステムオーディオ収録」で AppAudioRouter の許可を確認し、アプリを再起動してください。

> YouTube と Gemini Live を同じブラウザで再生すると、どちらの音も同じタップ対象になります。YouTube を Safari、Gemini Live を Chrome に分け、除外一覧で Chrome を選ぶと、YouTube の音声を送りつつ Gemini の返答を取り込まない設定にできます。Chrome の Go Live 入力には BlackHole 2ch を選びます。

### 3.2 Brave と GeForce NOW で別々のマイクを使う
1. AppAudioRouter で **Desktop Audio to Virtual Mic** を OFF にしている場合でも、`AppAudioRouter Virtual Microphone` は物理マイクを含まない仮想入力として選択できます。デスクトップ音声を Brave に渡す場合はルーティングを ON にします。
2. Brave のサイトまたはブラウザのマイク選択で **`AppAudioRouter Virtual Microphone`** を明示的に選択し、**Automatically** は選ばないでください。アプリは macOS の標準入力を変更しません。
3. GeForce NOW の macOS アプリの音声設定では、利用する **物理マイク** を明示的に選択します。
4. これにより Brave は AppAudioRouter の仮想入力、GeForce NOW は物理入力を個別に使います。macOS のアプリ別マイク選択と Brave のサイト権限画面は OS / ブラウザ版により表示が異なる場合があります。

### 3.3 Zoom で利用する場合
1. Zoom の「設定」>「オーディオ」を開きます。
2. **マイク** のプルダウンから **`AppAudioRouter Virtual Microphone`** を選択します。
3. （推奨）「オリジナルサウンドを有効にする」を ON に設定すると、Zoom 側の強力なノイズキャンセリングによって音楽やデスクトップ音が遮断されるのを防ぐことができます。
