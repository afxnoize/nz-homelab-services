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
```

## 機能概要

ホストサービスの管理モノレポ。各サービスは `services/` 以下に独立したディレクトリを持ち、Justfile で操作を定義する。

- [services/backup-kopia-b2/README.md](services/backup-kopia-b2/README.md) — Kopia + B2 定期バックアップ
- [services/vaultwarden/README.md](services/vaultwarden/README.md) — Vaultwarden + Tailscale Serve

## 技術スタック

| レイヤー       | 技術                                     |
| -------------- | ---------------------------------------- |
| バックアップ   | Kopia (S3 互換プロトコルで B2 に接続)    |
| ストレージ     | Backblaze B2 (`nz-vault-backup` bucket)  |
| パスワード管理 | Vaultwarden + Tailscale Serve            |
| シークレット   | SOPS (age 暗号化) → Git 管理            |
| スケジュール   | systemd user timer (daily)               |
| コンテナ       | Podman Quadlet (systemd 統合)            |
| 環境管理       | Nix Flakes (`flake.nix` + `flake.lock`) |

---

## リポジトリ構成

```
Justfile                              # ルート: mod でサービスを束ねる
flake.nix                             # 全サービス共通の devShell
services/
├── backup-kopia-b2/                  # → README.md 参照
│   ├── Justfile
│   ├── secrets.yaml / policy.yaml / sources.yaml
│   └── systemd/
└── vaultwarden/                      # → README.md 参照
    ├── Justfile
    ├── secrets.yaml
    └── quadlet/
```

## 設計判断

### モノレポ構成

各サービスは `services/<name>/` に独立し、それぞれが Justfile + secrets.yaml + README.md を持つ。ルートの Justfile は `mod` 機能でサービスを束ね、`just <service> <recipe>` で操作する。サービス固有の設計判断は各 README.md に記載。

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
