# Brave・GeForce NOW併用時のマイク分離と復旧手順

最終確認日: 2026-10-29。対象: AppAudioRouter Rust preview、Brave、Mic Lock 1.2.0。

## 維持する動作

- ゲーム（GeForce NOW）はmacOSの通常の物理マイクを使用する。
- BraveのChatGPT音声会話は、AppAudioRouterが送出するデスクトップ音声をBlackHole 2ch経由で取得する。
- ゲームのマイクを使うために、物理マイクをChatGPT用の音声へ混ぜる必要はない。macOSの標準入力をBlackHoleへ変更しない。

## 今回の症状・原因・確認結果

- **[FACT]** GeForce NOW使用中、ChatGPTがデスクトップ音声ではなく物理マイクを取得する症状が報告された。
- **[FACT]** `brave://webrtc-internals` の取得履歴には、ChatGPTがBlackHole 2chを取得した後、物理マイク（Beats Solo Buds）の`deviceId`を`exact`で指定して再取得した記録があった。単にブラウザの既定マイクをBlackHoleに設定するだけでは、この明示指定への対策にならない。
- **[FACT]** Mic LockのポップアップはONだったが、ChatGPTの既存タブには設定反映のための再読み込みを求める表示があった。拡張機能の管理画面では1.2.0が読み込まれていた。
- **[FACT]** ChatGPTタブの再読み込みと拡張機能本体の再読み込みを実施し、使用タブの再読み込み・音声会話の再接続を案内した。その後、ユーザーから「修正されました」と確認を得た。
- **[INFERENCE]** 今回の復旧経過は、更新された入力固定処理が既存ページに適用されていなかったことと整合する。拡張機能本体とページの両方への更新適用を、復旧手順に含める。
- **[UNKNOWN]** GeForce NOWがChatGPTのデバイス選択を直接変更したかは未確認。更新前のどの実行コンテキストが固定処理を通らなかったかも特定していない。RustやCoreAudio自体が原因だったと断定しない。
- **[UNKNOWN]** 復旧後の全音声トラックを診断画面で再検証したわけではない。今回の復旧結果はユーザーの実使用確認によるもので、再起動・全デバイスの抜き差しを含む保証ではない。

## 再発・作り直し時の復旧手順

1. BlackHole 2chが入力デバイスとして存在することを確認する。AppAudioRouterでデスクトップ音声を送出する。ゲーム用の物理マイクとmacOS標準入力はそのままにする。
2. `brave://extensions` で **AppAudioRouter Mic Lock** が有効か確認する。読み込み元は、このリポジトリの`BrowserExtension`フォルダー。別の古いコピーを読み込んでいないか確認する。
3. 拡張機能を更新・作り直した場合は、管理画面の当該拡張機能の **Reload（再読み込み）** を押す。ソースファイルの保存やRustアプリの再ビルドだけで完了としない。
4. 対象サイトのマイク権限を確認し、拡張機能のポップアップを **入力固定 ON** にする。
5. **使用するChatGPT/Geminiの既存タブを、それぞれ再読み込みする。** 拡張機能だけの再読み込みでは、既に動いているページの固定処理が更新されたと判断しない。
6. 音声会話を開始し直す。ON/OFF切り替え時も取得済みの音声が停止するため、会話の再接続が必要。
7. 下記の実機確認を行う。物理マイクを取得した場合は復旧済みとせず、取得履歴から切り分ける。

## 作り直しても保持する実装

ソースの正本は`BrowserExtension/`。Rustアプリだけを再実装しても、ブラウザ側の入力固定は代替されない。

- `manifest.json`: 対象サイトで`document_start`に実行。`mic-lock.js`は`MAIN`、設定橋渡しの`settings-bridge.js`は`ISOLATED`。関連フレーム用の`all_frames`と`match_origin_as_fallback`も保持する。
- `mic-lock.js`: 音声を要求する`getUserMedia()`をラップし、要求ごとに現在のループバック入力を探す。BlackHole 2chを優先し、なければAppAudioRouter Virtual Microphoneを選ぶ。
- サイトが物理マイクや`default`を明示指定しても、ON時は`deviceId: { exact: 選択したループバックID }`へ置き換える。競合する`groupId`は除去する。
- 取得後も`getSettings().deviceId`を検証し、想定外の入力は停止してページへ渡さない。ループバックが見つからない場合はエラーとし、物理マイクへフォールバックしない。再取得時に古いIDを使い回さない。
- `devicechange`時に取得済み入力を再確認する。ON/OFF変更時は取得済み音声と取得中の要求を停止対象とする。
- `settings-bridge.js`、`popup.html`、`popup.js`、`storage`権限を含めて復元する。OFF時はサイト本来の選択を許すため、物理マイクを取得し得る。音声を要求しない呼び出しは変更しない。
- macOS標準入力・GeForce NOWの入力は拡張機能で変更しない。CoreAudioの自己プロセス除外も維持する。

## 確認方法

自動確認（リポジトリルート）:

```sh
node --test BrowserExtension/mic-lock.test.cjs
```

**[FACT]** 今回の復旧作業時は8件成功、0件失敗、終了コード0。これは要求の置き換え・想定外入力の拒否・再取得・ON/OFF等の単体テストであり、実ブラウザへの適用を証明するものではない。

実機では`brave://webrtc-internals`を開いてから、GeForce NOWを使用した状態でChatGPTの音声会話を開始・再接続する。`getUserMedia/getDisplayMedia`の該当要求で、制約と取得結果の音声トラックラベルを確認する。結果はBlackHole 2ch、または選択したAppAudioRouter Virtual Microphoneであること。物理マイクや`Default – 物理マイク名`なら不合格。

Consoleでは現在の実装のログ`[AppAudioRouter Mic Lock] Verified voice input: BlackHole 2ch`（または仮想マイク名）も確認できる。ポップアップがONであること、サイトの選択表示、無音であることだけでは実際の取得先の証拠にしない。

会話の初回開始、終了後の再接続、GFN起動前後を確認する。ON/OFFを試す場合、OFFでは物理マイクが使われ得ることに注意し、終了時は目的に合わせてONへ戻す。音声を外部へ送る実機試験はユーザーが意図する会話で行い、診断用の録音は不要。診断履歴を保存する場合は会話URL・デバイスID等の個人情報を含めない。

## 再発時に記録する情報

拡張機能のバージョン・読み込み元、有効状態、ON/OFF、拡張機能とタブの再読み込み実施有無、再発操作と時刻、要求制約の種類（既定／物理ID／仮想ID）、実際のトラック名を記録する。観測事実と推測を分け、OS標準入力の変更やRust移行に原因を決めつけない。
