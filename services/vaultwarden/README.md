# vaultwarden

Vaultwarden (Bitwarden 互換) を Podman Quadlet で運用。Tailscale サイドカーコンテナ経由で HTTPS アクセスを提供する。

## 構成

| ファイル                                 | 役割                                     |
| ---------------------------------------- | ---------------------------------------- |
| `justfile`                               | 操作コマンド定義                         |
| `secrets.yaml`                           | Tailscale authkey（sops + age で暗号化） |
| `quadlet/vaultwarden.container.tmpl`     | Vaultwarden コンテナテンプレート         |
| `quadlet/vaultwarden-ts.container.tmpl`  | Tailscale サイドカーテンプレート         |
| `quadlet/vaultwarden-ts-serve.json.tmpl` | Tailscale Serve 設定テンプレート         |
| `quadlet/vaultwarden-data.volume`        | データボリューム                         |
| `quadlet/vaultwarden-ts-state.volume`    | Tailscale state ボリューム               |

## セットアップ

### 1. Tailscale authkey 取得

Tailscale admin console で authkey を発行する。

### 2. secrets 編集

```bash
sops services/vaultwarden/secrets.yaml
```

`ts_authkey` を記入する。

### 3. デプロイ

```bash
nix develop
just vaultwarden deploy
just vaultwarden start
```

Quadlet ファイルを `~/.config/containers/systemd/` にインストールし、サービスを起動する。

## コマンド

| コマンド                  | 説明                                         |
| ------------------------- | -------------------------------------------- |
| `just vaultwarden deploy` | Quadlet ファイルインストール + daemon-reload |
| `just vaultwarden start`  | サービス起動                                 |
| `just vaultwarden stop`   | サービス停止                                 |
| `just vaultwarden status` | サービス状態確認                             |
| `just vaultwarden logs`   | ログ表示                                     |
| `just vaultwarden update` | コンテナイメージ更新                         |

## アーキテクチャ

```
[Tailscale network]
        │
        ▼
vaultwarden-ts (tailscale sidecar)
        │  TS_SERVE: :443 → http://127.0.0.1:80
        │
        ▼
vaultwarden (server)
        │
        ▼
vaultwarden-data (volume)
```

- Tailscale Serve で HTTPS 終端し、vaultwarden にリバースプロキシ
- ドメイン: `vaultwarden.<MagicDNS suffix>` (deploy 時に自動取得)
- ネットワーク: `container:systemd-vaultwarden-ts` で sidecar に接続

## 設計判断

→ [ADR-002: gomplate + sops exec-env によるテンプレート管理](../../docs/design-docs/adr.md#adr-002-gomplate--sops-exec-env-によるテンプレート管理)
