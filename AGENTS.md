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
| シークレット暗号化 | SOPS + age     | `sops --encrypt / --decrypt` |
| YAML/JSON 操作     | yq             | `yq`                     |

### 操作

```bash
# 初回セットアップ・設定更新（connect + timer-on）
just deploy

# 手動バックアップ
just backup

# 状態確認
just status
```

## 機能概要

Kopia + Backblaze B2 による wisdom vault の定期バックアップ。daily スナップショットを systemd timer で自動実行し、保持ポリシーに従って世代管理する。

## 技術スタック

| レイヤー     | 技術                                     |
| ------------ | ---------------------------------------- |
| バックアップ | Kopia (S3 互換プロトコルで B2 に接続)    |
| ストレージ   | Backblaze B2 (`nz-vault-backup` bucket)  |
| シークレット | SOPS (age 暗号化) → Git 管理            |
| スケジュール | systemd user timer (daily)               |
| 環境管理     | Nix Flakes (`flake.nix` + `flake.lock`) |

---

## リポジトリ構成

| ファイル / ディレクトリ | 内容                                     |
| ----------------------- | ---------------------------------------- |
| `flake.nix`             | パッケージ提供（kopia, sops, age, yq, just） |
| `Justfile`              | 全操作の定義                             |
| `secrets.yaml`          | B2 接続情報（sops + age で暗号化）       |
| `policy.yaml`           | 保持ポリシー（keep-daily, keep-weekly 等） |
| `sources.yaml`          | バックアップ対象パス（gitignore）        |
| `systemd/`              | systemd user unit テンプレート           |

## 設計判断

### kopia config の分離

kopia はデフォルトで `~/.config/kopia/repository.config` を使うが、他の kopia 用途と競合するため `vault-b2.config` に分離している。Justfile 内の全コマンドは `--config-file=` で明示指定する。

### systemd service の kopia パス解決

`just timer-on` 実行時に `which kopia` で nix store 内のフルパスを解決し、`sed` で service ファイルに埋め込む。`/usr/bin/env kopia` では nix のパスが通らないため。

### ポリシーの外部ファイル化

保持ポリシーは `policy.yaml` で管理し、`just connect` 時に yq で読み取って kopia に設定する。バックアップ対象パスは `sources.yaml`（gitignore）で環境ごとに管理する。Justfile にハードコードしない。

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
