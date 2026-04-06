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
| YAML/JSON 操作     | yq             | `yq`                     |

### 操作

```bash
# 全サービス deploy
just deploy-all

# 個別サービス操作
just backup deploy        # kopia: connect + timer-on
just backup status        # kopia: 接続状態・スナップショット一覧
just vaultwarden deploy   # vaultwarden: quadlet インストール
just vaultwarden start    # vaultwarden: 起動
just vaultwarden status   # vaultwarden: 状態確認
```

## 機能概要

ホストサービスの管理モノレポ。各サービスは `services/` 以下に独立したディレクトリを持ち、Justfile で操作を定義する。

### services/backup-kopia-b2

Kopia + Backblaze B2 による vault の定期バックアップ。daily スナップショットを systemd timer で自動実行し、保持ポリシーに従って世代管理する。

### services/vaultwarden

Vaultwarden (Bitwarden 互換) をPodman Quadlet で運用。Tailscale サイドカーコンテナ経由で HTTPS アクセスを提供する。

## 技術スタック

| レイヤー     | 技術                                     |
| ------------ | ---------------------------------------- |
| バックアップ | Kopia (S3 互換プロトコルで B2 に接続)    |
| ストレージ   | Backblaze B2 (`nz-vault-backup` bucket)  |
| パスワード管理 | Vaultwarden + Tailscale Serve          |
| シークレット | SOPS (age 暗号化) → Git 管理            |
| スケジュール | systemd user timer (daily)               |
| コンテナ     | Podman Quadlet (systemd 統合)            |
| 環境管理     | Nix Flakes (`flake.nix` + `flake.lock`) |

---

## リポジトリ構成

| ファイル / ディレクトリ                   | 内容                                         |
| ----------------------------------------- | -------------------------------------------- |
| `flake.nix`                               | パッケージ提供（kopia, sops, age, yq, just） |
| `Justfile`                                | ルート: mod でサービスを束ねる               |
| `services/backup-kopia-b2/Justfile`       | kopia 操作の定義                             |
| `services/backup-kopia-b2/secrets.yaml`   | B2 接続情報（sops + age で暗号化）           |
| `services/backup-kopia-b2/policy.yaml`    | 保持ポリシー（keep-daily, keep-weekly 等）   |
| `services/backup-kopia-b2/sources.yaml`   | バックアップ対象パス（gitignore）            |
| `services/backup-kopia-b2/systemd/`       | systemd user unit テンプレート               |
| `services/vaultwarden/Justfile`           | vaultwarden 操作の定義                       |
| `services/vaultwarden/secrets.yaml`       | Tailscale authkey（sops + age で暗号化）     |
| `services/vaultwarden/quadlet/`           | Podman Quadlet 定義ファイル                  |

## 設計判断

### モノレポ構成

各サービスは `services/<name>/` に独立し、それぞれが Justfile + secrets.yaml を持つ。ルートの Justfile は `mod` 機能でサービスを束ね、`just <service> <recipe>` で操作する。

### kopia config の分離

kopia はデフォルトで `~/.config/kopia/repository.config` を使うが、他の kopia 用途と競合するため `vault-b2.config` に分離している。Justfile 内の全コマンドは `--config-file=` で明示指定する。

### systemd service の kopia パス解決

`just backup timer-on` 実行時に `which kopia` で nix store 内のフルパスを解決し、`sed` で service ファイルに埋め込む。`/usr/bin/env kopia` では nix のパスが通らないため。

### ポリシーの外部ファイル化

保持ポリシーは `policy.yaml` で管理し、`just backup connect` 時に yq で読み取って kopia に設定する。バックアップ対象パスは `sources.yaml`（gitignore）で環境ごとに管理する。Justfile にハードコードしない。

### vaultwarden のテンプレート管理

`vaultwarden-ts.container.tmpl` にプレースホルダ `__TS_AUTHKEY__` を置き、`just vaultwarden deploy` 時に `sops -d` + `sed` で展開して `~/.config/containers/systemd/` に直接書き出す。chezmoi への依存を排除。

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
