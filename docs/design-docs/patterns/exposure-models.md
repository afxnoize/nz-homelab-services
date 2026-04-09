# 公開モデル

## Model A — Tailscale Serve（Tailnet 内公開）

| 項目 | 内容 |
|---|---|
| アクセス範囲 | Tailnet 内のみ |
| TLS | Tailscale が自動管理 |
| 必要なもの | Tailscale sidecar コンテナ、`TS_SERVE_CONFIG`、`ts_authkey` シークレット |
| 典型例 | Vaultwarden |

## Model B — localhost バインド（ホスト内部のみ）

| 項目 | 内容 |
|---|---|
| アクセス範囲 | ホスト内部のみ（`127.0.0.1`） |
| TLS | なし |
| 必要なもの | `PublishPort=127.0.0.1:<host>:<container>` |
| 典型例 | Gatus（Web UI をローカルに閉じる） |

## 選択基準

- ネットワーク越しにアクセスしたい → Model A
- ホスト内の別プロセス（リバースプロキシなど）からのみ使う → Model B
