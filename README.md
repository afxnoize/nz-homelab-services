# nz-homelab-services

ホストサービスの管理モノレポ。

## サービス

| サービス | 概要 |
|---------|------|
| [backup-kopia-b2](services/backup-kopia-b2/) | Kopia + B2 による vault の定期バックアップ |
| [vaultwarden](services/vaultwarden/) | Vaultwarden + Tailscale Serve |

## セットアップ

```bash
nix develop
just deploy-all
```

## コマンド

```bash
just                     # レシピ一覧
just deploy-all          # 全サービス deploy
just status-all          # 全サービス状態確認
just backup <recipe>     # kopia 操作
just vaultwarden <recipe> # vaultwarden 操作
```

各サービスの詳細は `services/*/README.md` を参照。
