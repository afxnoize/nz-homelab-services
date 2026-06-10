# nz-homelab-services

ホストサービスの管理モノレポ。

## サービス

| サービス                                     | 概要                                                               |
| -------------------------------------------- | ------------------------------------------------------------------ |
| [backup-kopia-b2](services/backup-kopia-b2/) | Kopia + B2 による vault の定期バックアップ                         |
| [vaultwarden](services/vaultwarden/)         | Vaultwarden + Tailscale Serve                                      |
| [gatus](services/gatus/)                     | Gatus ヘルスチェック + Telegram 通知                               |
| [adguard-home](services/adguard-home/)       | AdGuard Home DNS + Tailscale Serve                                 |
| [ollama](services/ollama/)                   | Ollama + Open WebUI + Tailscale Serve (WSL2 / GPU) \*              |
| [observability](services/observability/)     | Alloy + VictoriaLogs + VictoriaMetrics + Grafana 観測スタック \*\* |
| [sing-box](services/sing-box/)               | sing-box 選択的 forward proxy (SOCKS5/HTTP, Tailscale 経由) \*\*   |

> \* ollama は WSL2 マシン稼働。`deploy-all` 対象外、`just ollama <recipe>` で個別操作。
>
> \*\* observability / sing-box は OCI NixOS 稼働。`deploy-all` 対象外、デプロイは `just oci-deploy`。

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
just                  # レシピ一覧（サービス別レシピもここから辿れる）
just deploy-all       # ホスト常駐サービスを一括 deploy
just <service> <recipe>  # 個別サービス操作（例: just gatus restart）
just oci-deploy       # OCI NixOS ホストへデプロイ (observability / sing-box)
```

各サービスの詳細は `services/*/README.md` を参照。
