# Cheatsheet

日常運用のクイックリファレンス。

## 基本操作

```bash
just                          # レシピ一覧
just deploy-all               # 全サービス deploy
just <service> deploy         # サービスを deploy
just <service> status         # サービスの状態確認
just <service> logs           # 直近 50 行のログ
just <service> logs-follow    # ログをリアルタイムで追う
just <service> restart        # サービス再起動
just <service> update         # イメージを最新に更新（podman auto-update）
```

## シークレット操作

```bash
# 暗号化ファイルを編集（エディタが開く）
sops services/<name>/secrets.yaml

# 新しい secrets.yaml を作成して暗号化
sops --encrypt secrets.plain.yaml > secrets.yaml

# 平文で中身を確認
sops --decrypt services/<name>/secrets.yaml

# 環境変数に展開して確認（デバッグ用）
sops exec-env services/<name>/secrets.yaml 'env | grep -E "ts_|TELEGRAM"'
```

## コンテナデバッグ

```bash
# サービスの状態確認
systemctl --user status <name>
systemctl --user status <name>-ts   # Tailscale sidecar の場合

# ログ確認
journalctl --user -u <name> -n 100 --no-pager
journalctl --user -u <name> -f      # リアルタイム

# コンテナに入る
podman exec -it systemd-<name> bash

# コンテナ一覧
podman ps

# ヘルスチェック状態
podman inspect systemd-<name> | jq '.[0].State.Health'
```

## Quadlet 反映手順

Quadlet ファイルを手動で変更した場合:

```bash
# 1. 変更を反映
systemctl --user daemon-reload

# 2. サービスを再起動
systemctl --user restart <name>

# ※ just deploy を使えばこの手順は自動で行われる
```

## Tailscale トラブルシューティング

```bash
# Tailscale sidecar の状態確認
podman exec systemd-<name>-ts tailscale status

# TS_DOMAIN の確認
tailscale status --json | jq -r '.MagicDNSSuffix'

# Serve 設定の確認
podman exec systemd-<name>-ts tailscale serve status

# Sidecar ログで認証エラーを探す
journalctl --user -u <name>-ts -n 50 --no-pager | grep -i "auth\|error\|failed"
```

## Nix 環境

```bash
# 開発シェルに入る（ツール一式が使えるようになる）
nix develop

# flake.lock を更新（ツールのバージョンを上げるとき）
nix flake update

# 現在のシェルで使えるツールを確認
which sops gomplate just jq
```

## バックアップ操作

```bash
just backup                   # レシピ一覧
just backup snapshot          # 手動スナップショット
just backup list-snapshots    # スナップショット一覧
just backup status            # リポジトリ状態
```
