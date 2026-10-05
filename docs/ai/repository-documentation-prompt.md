# Git Repository Documentation, Versioning & AI-Assisted Development Setup
# リポジトリ整備・ドキュメント作成指示書

あなたは経験豊富なソフトウェアエンジニア、
ソフトウェアアーキテクト、テクニカルライターとして作業してください。

このリポジトリに存在するアプリケーションを解析し、
今後、人間の開発者およびAIコーディングエージェントが
継続的に開発・保守・改善できる状態へ整備してください。

このプロジェクトはAIエージェントを利用して開発されています。
今後もAIエージェントを開発プロセスで利用する可能性があります。

ただし、AIが生成したコード・仕様・ドキュメントを
無条件に正しいものとして扱わないでください。

既存コード、テスト、Git履歴、Issue、ドキュメント等を確認し、
事実に基づいてドキュメントを作成してください。

不明な情報を推測して事実として記載してはいけません。
判断できない内容は「TBD」「要確認」としてください。


==================================================
1. 作業開始前：リポジトリ全体の調査
==================================================

最初にリポジトリ全体を調査してください。

以下を可能な限り特定してください。

- アプリケーション名
- アプリケーションの目的
- 対象ユーザー
- 主なユースケース
- 現在のバージョン
- 使用言語
- フレームワーク
- 主要ライブラリ
- 外部サービス/API
- 対応OS
- 実行環境
- 開発環境
- エントリーポイント
- ディレクトリ構成
- 設定ファイル
- 環境変数
- 起動方法
- ビルド方法
- テスト方法
- lint / formatter
- 現在実装されている機能
- 未完成の機能
- TODO
- 既知の問題
- 技術的制約
- セキュリティ上注意すべき設定

READMEだけを信用するのではなく、
実際のソースコードと設定を確認してください。

存在する場合は、例えば以下も確認してください。

package.json
package-lock.json
pnpm-lock.yaml
yarn.lock
pyproject.toml
requirements.txt
Cargo.toml
go.mod
Dockerfile
docker-compose.yml
.env.example
GitHub Actions
テストコード
Git履歴
Git tag


==================================================
2. Documentation Gap Analysis
==================================================

現在存在するドキュメントを確認し、

- 存在する
- 存在するが古い
- 不完全
- 存在しない
- コードと矛盾している

の観点から分析してください。

既存ドキュメントを無条件に削除・上書きせず、
利用できる情報は統合してください。


==================================================
3. 推奨リポジトリ構成
==================================================

プロジェクト規模と技術構成を考慮し、
必要に応じて以下を整備してください。

/
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── AGENTS.md
├── AI_USAGE.md
├── SECURITY.md
├── LICENSE
├── .gitignore
│
├── docs/
│   ├── specification.md
│   ├── architecture.md
│   ├── installation.md
│   ├── usage.md
│   ├── development.md
│   ├── versioning.md
│   ├── release-process.md
│   └── roadmap.md
│
└── .github/
    ├── ISSUE_TEMPLATE/
    │   ├── bug_report.md
    │   └── feature_request.md
    ├── PULL_REQUEST_TEMPLATE.md
    └── workflows/

すべてを機械的に作成する必要はありません。

小規模なプロジェクトでは、
過剰なドキュメント構成を避けてください。

必要性を判断して提案・作成してください。


==================================================
4. README.md
==================================================

READMEは「プロジェクトの入口」としてください。

初めてこのリポジトリを見た人が短時間で、

「何をするアプリなのか」
「どうインストールするのか」
「どう起動するのか」
「どこを読めば詳しく分かるのか」

を理解できるようにしてください。

最低限以下を検討してください。

# Project Name

## Overview

プロジェクト概要。

## Features

現在実装済みの主要機能。

## Requirements

必要なOS、ランタイム、ソフトウェア等。

## Installation

最小限のインストール手順。

## Quick Start

最短で起動する方法。

## Usage

基本的な利用方法。

## Documentation

docs/へのリンク。

## Development

開発者向け情報へのリンク。

## Contributing

CONTRIBUTING.mdへのリンク。

## Version

現在のバージョン。

## License

ライセンス。

必要であればAI-assisted developmentについて
短い記載とAI_USAGE.mdへのリンクを設けてください。

ただしREADMEの主目的はプロジェクト説明です。

「AIで作成された」という説明を
READMEの中心にしないでください。


==================================================
5. docs/specification.md
==================================================

現在の正式なソフトウェア仕様を記述してください。

これは変更履歴ではありません。

以下を可能な範囲で記載してください。

- システムの目的
- 対象ユーザー
- ユースケース
- 機能要件
- 非機能要件
- 入力
- 出力
- UI動作
- データ形式
- 設定項目
- 外部システムとの連携
- エラー処理
- 制約
- 対応環境
- 既知の制限

コードと仕様書が矛盾する場合は、
勝手にどちらかへ合わせず矛盾を報告してください。


==================================================
6. docs/architecture.md
==================================================

開発者とAIエージェントの双方が
システム内部を理解できるようにしてください。

以下を記載してください。

- システム全体構成
- 主要コンポーネント
- 各モジュールの責務
- ディレクトリ構成
- データフロー
- 処理フロー
- 外部API
- 永続化方式
- 主要クラス/モジュールの関係
- 技術選定
- 重要な設計判断
- 変更時に注意すべき依存関係

可能であればMermaidを利用してください。

例：

flowchart LR
    User --> UI
    UI --> Application
    Application --> Service
    Service --> Storage

ただし、実際のコード構造に基づいて作成してください。


==================================================
7. docs/installation.md
==================================================

新しい開発者が新しいPCから
環境を再構築できることを目標にしてください。

以下を記載してください。

- 必要ソフトウェア
- 必要バージョン
- Repository clone
- 依存関係のインストール
- 環境変数
- 設定ファイル
- ビルド
- 初回起動
- 動作確認
- よくあるセットアップエラー

必要であれば.env.exampleを作成してください。

実際のAPIキー、Token、Password等は
絶対に記載しないでください。


==================================================
8. docs/usage.md
==================================================

一般ユーザー向けの使用方法を記載してください。

- 起動方法
- 基本操作
- 主な機能
- 設定方法
- 終了方法
- エラー発生時の対処
- 使用例

内部実装の説明とユーザー向け操作説明を
混同しないでください。


==================================================
9. docs/development.md
==================================================

開発者向けに以下を記載してください。

- 開発環境
- 開発用起動方法
- デバッグ方法
- テスト方法
- lint
- formatter
- build
- ディレクトリ構成
- ログ確認方法
- 新機能追加方法
- 依存関係追加時の方針
- 設定変更時の注意点


==================================================
10. CHANGELOG.md
==================================================

バージョンごとの変更履歴を管理してください。

Keep a Changelogの考え方を参考にしてください。

例：

# Changelog

## [Unreleased]

### Added
- 新しい機能

### Changed
- 仕様変更

### Fixed
- バグ修正

### Removed
- 削除された機能

## [2.1.0] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Fixed
- ...

Git履歴から確認できる場合は過去の変更を調査してください。

確認できない過去の変更内容を
AIが推測して作成してはいけません。


==================================================
11. Versioning
==================================================

基本的にSemantic Versioning（SemVer）を採用してください。

MAJOR.MINOR.PATCH

例：

1.0.0
1.1.0
1.1.1
2.0.0

MAJOR:
後方互換性を壊す変更。

MINOR:
後方互換性を維持した機能追加。

PATCH:
後方互換性を維持したバグ修正。

開発途中の変更は、

[Unreleased]

へ記録してください。


==================================================
12. docs/versioning.md
==================================================

以下を明文化してください。

- Semantic Versioning
- バージョン更新条件
- Git tagルール
- CHANGELOGとの関係
- prerelease版の扱い

Git tag例：

v1.0.0
v1.1.0
v2.0.0

必要なら：

v2.0.0-alpha.1
v2.0.0-beta.1
v2.0.0-rc.1


==================================================
13. CONTRIBUTING.md
==================================================

人間とAIの双方によるContributionを想定してください。

以下を記載してください。

- Issue作成方法
- Branch作成方法
- コーディングルール
- コミットルール
- テスト要件
- Pull Request作成方法
- レビュー方法
- マージ条件
- ドキュメント更新ルール
- AI生成コードの扱い

推奨branch例：

feature/xxx
fix/xxx
docs/xxx
refactor/xxx

適切であればConventional Commitsを使用してください。

例：

feat: add new feature
fix: resolve startup error
docs: update usage guide
refactor: simplify configuration
test: add configuration tests
chore: update dependencies


==================================================
14. AI_USAGE.md
==================================================

このプロジェクトではAIコーディングエージェントを
開発支援に利用していることを記録してください。

目的は「AI製であることを宣伝すること」ではありません。

開発プロセスの透明性と、
AI生成物の取り扱いルールを明確化することが目的です。

以下を記載してください。

# AI-Assisted Development

## Purpose

このプロジェクトでは、
AI coding agentsを開発支援に利用する場合があります。

## Possible Uses

AIは例えば以下に利用できます。

- Code generation
- Refactoring
- Documentation
- Test generation
- Debugging assistance
- Code review assistance
- Repository analysis

## Validation

AIが生成したコードや文書を
自動的に正しいものとして扱わないでください。

変更内容は可能な限り、

- code review
- build
- automated tests
- manual tests
- specification verification

によって検証してください。

## Source of Truth

AIとの会話そのものを
正式な仕様の保存場所にしないでください。

正式な情報は、

- repository
- source code
- tests
- docs/specification.md
- CHANGELOG.md
- Issues
- Pull Requests

等で管理してください。

## Disclosure

特定のAI製品名やモデル名については、
プロジェクト上必要な場合のみ記載してください。

AIサービスが変わっても
開発ルールが成立する構成を優先してください。


==================================================
15. AGENTS.md
==================================================

AIコーディングエージェントが
このリポジトリを変更する際の指示書を作成してください。

これは重要なファイルです。

最低限以下を含めてください。

# Agent Instructions

Before modifying this repository:

1. Read README.md.
2. Read docs/specification.md.
3. Read docs/architecture.md.
4. Read CONTRIBUTING.md.
5. Check CHANGELOG.md.
6. Inspect relevant source code.
7. Inspect relevant tests.

Do not assume undocumented behavior.

Do not invent requirements.

If a requirement is unclear:
- preserve existing behavior, or
- report the ambiguity.

Before changing code:
- identify affected modules;
- identify affected tests;
- identify affected documentation.

After changing code:
- run relevant tests;
- run lint/formatter when applicable;
- verify existing behavior;
- update documentation when behavior changes;
- update CHANGELOG.md for user-visible changes.

Never:
- commit API keys;
- commit passwords;
- commit tokens;
- expose credentials;
- silently change public behavior;
- remove compatibility without documenting it;
- fabricate test results.

AI agents must clearly distinguish:

FACT:
verified from repository/code/tests.

INFERENCE:
reasonable interpretation but not directly verified.

PROPOSAL:
suggested future change.

UNKNOWN:
insufficient information.

The repository must remain the source of truth,
not previous AI conversations.


==================================================
16. AIエージェントによる変更のルール
==================================================

AIがコードを変更した場合も、
通常のソフトウェア開発プロセスを省略しないでください。

AI-generated change
        ↓
Code Review
        ↓
Tests
        ↓
Documentation Check
        ↓
Pull Request
        ↓
Merge
        ↓
Release

という流れを基本としてください。

AIが生成したという理由だけで
品質基準を下げてはいけません。

逆に、AI生成であるという理由だけで
コードを区別する必要もありません。

最終的にはリポジトリに保存された
コード・テスト・仕様・履歴を基準としてください。


==================================================
17. docs/release-process.md
==================================================

正式リリース手順をまとめてください。

例：

1. 実装完了
2. automated tests
3. manual tests
4. lint / formatter
5. specification確認
6. architecture確認
7. README確認
8. CHANGELOG更新
9. version更新
10. Pull Request
11. review
12. mainへmerge
13. Git tag
14. GitHub Release

AIが作業した場合でも
同じリリース手順を適用してください。


==================================================
18. docs/roadmap.md
==================================================

以下を明確に分離してください。

## Implemented

現在実装済み。

## In Progress

現在開発中。

## Planned

正式に予定されているもの。

## Ideas

まだ検討段階のもの。

AIが独自にロードマップを作ってはいけません。

GitHub Issues、既存文書、コード等から
確認できない予定はTBDとしてください。


==================================================
19. SECURITY.md
==================================================

以下を確認してください。

- API keys
- Passwords
- Tokens
- Secrets
- Credentials
- Private keys
- Personal information
- .env files

秘密情報がGitへ含まれていないか確認してください。

問題を発見した場合でも、
秘密情報そのものを回答や文書へコピーしないでください。

問題の種類と対象ファイルだけを報告してください。


==================================================
20. LICENSE
==================================================

既存LICENSEが存在する場合は
勝手に変更しないでください。

存在しない場合は、

LICENSE: TBD

として報告してください。

MIT、Apache、GPL等を
AIが独断で選択してはいけません。


==================================================
21. GitHub Collaboration
==================================================

必要に応じて以下を整備してください。

.github/
├── ISSUE_TEMPLATE/
│   ├── bug_report.md
│   └── feature_request.md
├── PULL_REQUEST_TEMPLATE.md
└── workflows/

Pull Request Templateには、

- Summary
- Reason
- Changes
- Related Issue
- Test Results
- Breaking Change
- Documentation Update
- AI Assistance（必要な場合）

等を検討してください。

AI利用の記載を必須にするかどうかは、
プロジェクト方針としてCONTRIBUTING.mdに明記してください。


==================================================
22. CI
==================================================

プロジェクトに適していれば、
GitHub Actions等によるCIを提案してください。

例：

Pull Request
      ↓
Install Dependencies
      ↓
Build
      ↓
Lint
      ↓
Tests
      ↓
Result

ただし、既存のCIがある場合は
まず既存構成を確認してください。

勝手に既存CIを置き換えないでください。


==================================================
23. Single Source of Truth
==================================================

情報を複数ファイルへ重複して記載しすぎないでください。

基本的な責務を以下のように分離してください。

README.md
→ プロジェクトへの入口

docs/specification.md
→ 現在の仕様

docs/architecture.md
→ 内部構造

docs/usage.md
→ 使用方法

docs/development.md
→ 開発方法

CHANGELOG.md
→ 過去の変更

docs/roadmap.md
→ 将来予定

CONTRIBUTING.md
→ Contributionルール

AGENTS.md
→ AIエージェント向け作業ルール

AI_USAGE.md
→ AI利用方針

docs/versioning.md
→ バージョン管理

docs/release-process.md
→ リリース方法


==================================================
24. AIとの会話に依存しないこと
==================================================

非常に重要です。

このプロジェクトの仕様や設計判断を
AIとのチャット履歴だけに残してはいけません。

重要な決定は必ずRepository側へ反映してください。

例えば仕様変更が決定した場合、

AI conversation
      ↓
Implementation
      ↓
Tests
      ↓
docs/specification.md
      ↓
CHANGELOG.md
      ↓
Pull Request

という形でRepositoryへ記録してください。

数か月後に別の開発者や別のAIが
過去のチャットを知らなくても開発を継続できる状態を
目標としてください。


==================================================
25. 作業時の重要ルール
==================================================

必ず以下を守ってください。

1. コードを調査してから文書を書く。
2. 推測を事実として書かない。
3. 不明点はTBDまたは要確認とする。
4. READMEへ情報を詰め込みすぎない。
5. 現在の仕様と変更履歴を分離する。
6. 現在の機能と将来予定を分離する。
7. Version / CHANGELOG / Git tagを整合させる。
8. 秘密情報を書かない。
9. ドキュメント作成だけを目的に正常なコードを変更しない。
10. 既存ドキュメントを確認してから変更する。
11. 不必要に複雑な運用ルールを導入しない。
12. AI生成情報を無条件に信用しない。
13. テスト結果を捏造しない。
14. 実行していないテストを「成功」と報告しない。
15. 破壊的変更を黙って行わない。
16. 重要な仕様変更には理由を残す。
17. RepositoryをSource of Truthとする。


==================================================
26. 作業フェーズ
==================================================

いきなり大量のファイルを作成しないでください。

以下の順番で作業してください。

Phase 1
Repository Analysis

Phase 2
Documentation Gap Analysis

Phase 3
Documentation Structure Proposal

Phase 4
Documentation Creation / Update

Phase 5
AI Development Rules Setup

Phase 6
Versioning / Release Setup

Phase 7
Consistency Check

Phase 8
Final Report


==================================================
27. 最終Consistency Check
==================================================

作業後、以下を確認してください。

- READMEから必要情報へ辿れるか
- READMEのコマンドで起動できるか
- Installationが実装と一致するか
- Usageが実装と一致するか
- Specificationが実装と一致するか
- Architectureがコード構造と一致するか
- Version番号が一致するか
- CHANGELOGがVersionと一致するか
- Git tagとの矛盾がないか
- Roadmapと現在機能が混同されていないか
- AGENTS.mdが現在の開発フローと一致するか
- AI_USAGE.mdとCONTRIBUTING.mdが矛盾していないか
- 秘密情報が含まれていないか
- 未実装機能を実装済みとして記載していないか
- 古い情報が残っていないか


==================================================
28. 最終報告
==================================================

最後に以下を報告してください。

1. Repository Analysis Summary
2. アプリケーション概要
3. 現在のVersion
4. 使用技術
5. 現在の主要機能
6. 作成したファイル
7. 更新したファイル
8. 採用したドキュメント構成
9. 採用したVersioning方式
10. AI-assisted developmentの運用方法
11. 発見した問題
12. セキュリティ上の注意点
13. TBD / 要確認事項
14. 実行したテスト
15. 実行できなかったテスト
16. 今後推奨する改善
17. 次のReleaseに必要な作業

「テスト成功」と報告する場合は、
実際に実行したコマンドと結果を確認してください。


==================================================
29. 最終目標
==================================================

最終的な目標は、

「このRepositoryを初めて見る人間またはAIエージェントが、
過去のAIチャットを一切参照しなくても、
READMEから入り、

- アプリケーションの目的
- 現在の仕様
- アーキテクチャ
- インストール
- 使用方法
- 開発方法
- テスト方法
- Contribution方法
- Version管理
- 変更履歴
- Release方法
- AI利用ルール

を理解し、安全に開発を継続できる状態」

にすることです。

ドキュメントを作ること自体を目的にせず、
「将来このRepositoryを引き継いだ人が困らないこと」
を最優先してください。
