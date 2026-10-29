# Contributing to AppAudioRouter

`AppAudioRouter` への貢献（Contribution）をご検討いただきありがとうございます。
本プロジェクトでは、人間の開発者および AI コーディングエージェントの双方が安全かつ持続可能に開発を進められるよう、以下のガイドラインを定めています。

---

## 1. 開発フローの基本

すべての変更は以下のフローを経て取り込まれます：

```
Issue 作成 (または確認)
      ↓
トピックブランチ作成 (`feature/*`, `fix/*`, etc.)
      ↓
コード実装 & ドキュメント更新
      ↓
テスト実行 (`swift test`, CLI 診断)
      ↓
Pull Request 作成
      ↓
レビュー & 検証
      ↓
main ブランチへのマージ
```

---

## 2. ブランチ命名規則

用途に応じて以下のプレフィックスを使用してください：

| プレフィックス | 用途 | 例 |
| :--- | :--- | :--- |
| `feature/` | 新機能の追加 | `feature/custom-eq-filter` |
| `fix/` | バグ修正 | `fix/virtual-mic-reconnect` |
| `docs/` | ドキュメントの作成・更新 | `docs/update-architecture` |
| `refactor/` | 振る舞いを変えないコード整理 | `refactor/ring-buffer-lock` |
| `test/` | テストコードの追加・改善 | `test/renderer-dsp-tests` |
| `chore/` | ビルド設定、依存、雑務 | `chore/package-script-update` |

---

## 3. コミットメッセージ規約 (Conventional Commits)

コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/) の形式に準拠してください：

```
<type>(<scope>): <short description>

[optional body]

[optional footer]
```

### Type 一覧
- `feat`: 新機能の追加
- `fix`: バグ修正
- `docs`: ドキュメントのみの変更
- `refactor`: バグ修正や機能追加を含まないリファクタリング
- `test`: テストコードの追加や修正
- `chore`: パッケージ設定、スクリプトの更新等

---

## 4. テスト要件

Pull Request を提出する前に、必ず以下のチェックをパスしてください：

1. **単体テストがすべて合格すること**:
   ```bash
   swift test
   ```
2. **CLI 診断テストが正常終了すること**:
   ```bash
   swift run AppAudioRouterCLI diagnose
   swift run AppAudioRouterCLI test-tone
   ```
3. 変更によって新しい振る舞いが追加された場合、対応する単体テストを追加してください。

---

## 5. ドキュメント更新ルール

公開されている仕様や挙動、設定方法に変更が生じる場合、**コードの変更と同一の PR でドキュメントを更新すること** が必須です：

- 仕様変更: `docs/specification.md`
- 内部構造・データフロー変更: `docs/architecture.md`
- 操作方法・画面変更: `docs/usage.md`
- ユーザー向け変更の記録: `CHANGELOG.md` の `[Unreleased]` セクション

---

## 6. AI 生成コードの取り扱い

本プロジェクトでは AI コーディングエージェント（Antigravity, Claude, Copilot, ChatGPT 等）の活用を歓迎します。ただし、以下のルールを厳守してください：

- **無条件な信用は禁止**: AI が生成したコード、設定、仕様書を無検証でコミットしないでください。
- **実証主義の徹底**: 必ずローカル環境でビルド、テスト、実機動作を確認した上で PR を作成してください。
- **Source of Truth の維持**: AI とのチャット履歴を仕様の根拠とせず、必ずリポジトリ内のコード、テスト、公式ドキュメントに事実を反映させてください。
- 詳細な運用方針は [AI_USAGE.md](AI_USAGE.md) をご参照ください。

## Rust migration checks

During coexistence, retain the Swift checks above and run Cargo formatting, Clippy, and workspace tests for Rust changes. Native audio hardware tests remain opt-in and must run serially with the running app stopped. Follow [the migration guide](docs/rust-migration.md); do not remove Swift or make Rust the packaging default before its acceptance gates pass.
