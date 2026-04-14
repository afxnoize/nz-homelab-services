# nz-homelab-services

ホストサービスの管理モノレポ。

## サービス

| サービス | 概要 |
|---------|------|
| [backup-kopia-b2](services/backup-kopia-b2/) | Kopia + B2 による vault の定期バックアップ |
| [vaultwarden](services/vaultwarden/) | Vaultwarden + Tailscale Serve |
| [gatus](services/gatus/) | Gatus ヘルスチェック + Telegram 通知 |
| [adguard-home](services/adguard-home/) | AdGuard Home DNS + Tailscale Serve |
| [ollama](services/ollama/) | Ollama + Open WebUI + Tailscale Serve (WSL2 / GPU) * |

> \* ollama は WSL2 マシンで動作するため `deploy-all` / `status-all` の対象外。個別に `just ollama <recipe>` で操作する。

## 前提条件

- [Nix](https://nixos.org/) (Flakes 有効) — 開発ツールのバージョン管理
- [Podman](https://podman.io/) — コンテナランタイム（rootless, Quadlet 対応）
- [Tailscale](https://tailscale.com/) — ホスト OS にインストール・認証済みであること。デプロイ時に `tailscale status` で MagicDNS suffix を取得する

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
just gatus <recipe>      # gatus 操作
just adguard-home <recipe> # adguard-home 操作
just ollama <recipe>      # ollama 操作 (WSL2 マシン)
```

各サービスの詳細は `services/*/README.md` を参照。
