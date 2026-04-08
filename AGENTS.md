## 言語

英語で思考し、日本語で回答してください。
出力は常にMarkdown形式にしてください

## Commit Rules

- Conventional Commits を使うこと
- type/scope は英語（feat, fix, docs など）
- subject / body は日本語で書く
- subject は短く（句点なし）
- comprehensive commit message based on git diff

## 開発ツール

`flake.nix` (リポジトリルート) で全ツールをバージョン固定。`nix develop` で開発シェルに入る。

### ツールチェイン

| 用途               | ツール         | コマンド                 |
| ------------------ | -------------- | ------------------------ |
| 環境管理           | Nix Flakes     | `nix develop`            |
| タスクランナー     | just           | `just <recipe>`          |
| バックアップ       | Kopia          | `kopia` (via Justfile)   |
| コンテナ           | Podman Quadlet | `systemctl --user`       |
| シークレット暗号化 | SOPS + age     | `sops --encrypt / --decrypt` |
| テンプレート展開   | gomplate       | `gomplate -f in.tmpl -o out` |
| YAML/JSON 操作     | yq             | `yq`                     |

### 操作

```bash
just                          # レシピ一覧
just deploy-all               # 全サービス deploy
just backup <recipe>          # kopia 操作
just vaultwarden <recipe>     # vaultwarden 操作
just gatus <recipe>           # gatus 操作
```

## アーキテクチャ

→ [ARCHITECTURE.md](ARCHITECTURE.md) — 設計思想・パターンカタログ・サービス追加手順

## 機能概要

ホストサービスの管理モノレポ。各サービスは `services/` 以下に独立したディレクトリを持ち、Justfile で操作を定義する。

- [services/backup-kopia-b2/README.md](services/backup-kopia-b2/README.md) — Kopia + B2 定期バックアップ
- [services/vaultwarden/README.md](services/vaultwarden/README.md) — Vaultwarden + Tailscale Serve
- [services/gatus/README.md](services/gatus/README.md) — Gatus ヘルスチェック + Telegram 通知

## 技術スタック

| レイヤー       | 技術                                     |
| -------------- | ---------------------------------------- |
| バックアップ   | Kopia (S3 互換プロトコルで B2 に接続)    |
| ストレージ     | Backblaze B2 (`***REDACTED***` bucket)  |
| パスワード管理 | Vaultwarden + Tailscale Serve            |
| ヘルスチェック | Gatus + Telegram 通知                    |
| シークレット   | SOPS (age 暗号化) → Git 管理            |
| スケジュール   | systemd user timer (daily)               |
| コンテナ       | Podman Quadlet (systemd 統合)            |
| 環境管理       | Nix Flakes (`flake.nix` + `flake.lock`) |

---

## リポジトリ構成

```
Justfile                              # ルート: mod でサービスを束ねる
flake.nix                             # 全サービス共通の devShell
ARCHITECTURE.md                       # 設計思想・パターンカタログ
docs/
├── cheatsheet.md                     # 運用クイックリファレンス
├── knowledge.md                      # 既知の落とし穴
└── design-docs/
    ├── index.md                      # 設計文書カタログ
    └── adr/
        ├── README.md                 # ADR ガイド・テンプレート
        └── {3桁連番}-{slug}.md       # 個別 ADR
services/
├── backup-kopia-b2/                  # → README.md 参照
│   ├── Justfile
│   ├── secrets.yaml / policy.yaml / sources.yaml
│   └── systemd/
├── vaultwarden/                      # → README.md 参照
│   ├── Justfile
│   ├── secrets.yaml
│   └── quadlet/
└── gatus/                            # → README.md 参照
    ├── Justfile
    ├── secrets.yaml
    ├── config.yaml.tmpl
    └── quadlet/
```

## 設計判断

設計判断は ADR (Architecture Decision Records) で管理する。

- [ARCHITECTURE.md](ARCHITECTURE.md) — 設計パターンと設計思想
- [docs/design-docs/adr/](docs/design-docs/adr/README.md) — ADR 一覧
- [docs/design-docs/index.md](docs/design-docs/index.md) — 設計文書カタログ
- [docs/cheatsheet.md](docs/cheatsheet.md) — 運用クイックリファレンス
- [docs/knowledge.md](docs/knowledge.md) — 既知の落とし穴

### Documentation-Code Coupling

コード変更時、対応するドキュメントを同一コミットで更新する。

| Code Change | Update Required |
|---|---|
| サービス追加/変更/削除 | AGENTS.md, docs/design-docs/ |
| 設計判断 | docs/design-docs/adr/ に ADR ファイル追加 |
| 依存関係の追加/変更 | AGENTS.md (ツールチェイン表) |
| バグ修正（非自明なもの） | 該当サービスの README.md |
| 新しいパターンの適用 | ARCHITECTURE.md |
| 運用上の落とし穴の発見 | docs/knowledge.md |

---

## Repository Work Rules

### ブランチ命名規則

`<prefix>/<slug>`

| prefix      | 用途             |
| ----------- | ---------------- |
| `feat/`     | 新機能           |
| `chore/`    | 雑務             |
| `fix/`      | バグ修正         |
| `refactor/` | リファクタリング |
| `docs/`     | ドキュメントのみ |
