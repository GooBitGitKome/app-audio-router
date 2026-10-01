# AppAudioRouter リリース手順書 (Release Process)

本ドキュメントは、`AppAudioRouter` の正式リリースおよび配布物作成の標準手順を定めます。
人間による作業、AI エージェントによる作業を問わず、本手順に従ってリリースを実施してください。

---

## 1. リリース前チェックリスト

リリース前に必ず以下のステップをすべて完了させてください：

- [ ] **1. 全ユニットテストの実行**
  ```bash
  swift test
  ```
  すべてのテストが 0 failures で合格すること。
- [ ] **2. CLI パイプライン検証の実行**
  ```bash
  swift run AppAudioRouterCLI diagnose
  swift run AppAudioRouterCLI test-tone
  ```
  歪み率ゼロ、サンプリングレート 48kHz 同期、自プロセス除外が正常に機能していること。
- [ ] **3. ドキュメントの整合性確認**
  - 新機能や仕様変更が `docs/specification.md` に反映されているか。
  - 設計上の変更が `docs/architecture.md` に反映されているか。
  - 操作方法の変更が `docs/usage.md` に反映されているか。

---

## 2. バージョン更新と変更履歴の確定

### ステップ 1: `CHANGELOG.md` の更新
`[Unreleased]` セクションの内容を、リリース日を付与した新バージョン見出しに移動します：
```markdown
## [1.1.0] - 2026-10-15

### Added
- ...
```

### ステップ 2: バンドルバージョン番号の更新
`scripts/package_app.sh` 内のバージョン番号を更新します：
```bash
CFBundleShortVersionString = "1.1.0"
CFBundleVersion = "2"
```

### ステップ 3: コミットの作成
```bash
git add CHANGELOG.md scripts/package_app.sh docs/
git commit -m "chore(release): prepare release v1.1.0"
```

---

## 3. パッケージングとタグ付け

### ステップ 4: アプリケーションバンドルのビルド
```bash
./scripts/package_app.sh
```
`AppAudioRouter.app` が正常に生成され、署名されていることを確認します。

### ステップ 5: Git タグの作成
```bash
git tag -a v1.1.0 -m "Release v1.1.0"
git push origin main --tags
```

### ステップ 6: GitHub Release の作成（該当する場合）
- タグ: `v1.1.0`
- タイトル: `AppAudioRouter v1.1.0`
- リリースノート: `CHANGELOG.md` の該当バージョンの内容を記載
- 添付ファイル: `AppAudioRouter.app` を ZIP 圧縮した `AppAudioRouter-v1.1.0.zip`
