# Security Policy

## 1. Supported Versions

| Version | Supported | Notes |
| :--- | :--- | :--- |
| `1.0.x` | :white_check_mark: | Current active release branch. |
| `< 1.0.0` | :x: | Development / deprecated versions. |

---

## 2. Reporting a Vulnerability (脆弱性の報告)

セキュリティ上の脆弱性や懸念を発見された場合は、公開の GitHub Issue ではなく、リポジトリメンテナー宛てに安全な手段でご報告ください。

- 報告内容には、影響を受けるコンポーネント、再現手順、可能であれば PoC（概念実証）を含めてください。
- 報告受領後、メンテナーが内容を精査し、修正パッチのリリース時期をお知らせします。

---

## 3. オーディオ権限とプライバシー (Audio Privacy & Permissions)

`AppAudioRouter` は macOS の低水準オーディオストリームを扱うため、以下のシステムプライバシー保護機構に依存しています：

1. **マイクアクセス権限 (`NSMicrophoneUsageDescription`)**:
   - 物理マイク入力ストリームのキャプチャに必要です。
   - アプリケーションが勝手に外部サーバー等へ音声データを送信することはありません（完全ローカル動作）。
2. **システムオーディオ収録権限 (`NSAudioCaptureUsageDescription`)**:
   - `AudioHardwareCreateProcessTap` を用いてプロセス音声またはデスクトップ全体の音声をキャプチャするために macOS 14.2+ が要求する公式権限です。
   - 画面の描画内容（ピクセルデータ）は一切キャプチャせず、音声波形データ（PCM Float32）のみを取得します。
3. **ネットワーク通信について**:
   - 本アプリケーションにはネットワーク送受信を行うコードは一切含まれていません。完全オフラインで動作します。

---

## 4. 秘密情報の管理

本リポジトリには、API キー、パスワード、暗号化秘密鍵、個人情報、および認証トークンは一切含まれておらず、コミットも禁止されています。
