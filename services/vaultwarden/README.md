# vaultwarden

Vaultwarden (Bitwarden 互換) を Podman Quadlet で運用。Tailscale サイドカーコンテナ経由で HTTPS アクセスを提供する。

## 構成

| ファイル | 役割 |
|---------|------|
| `Justfile` | 操作コマンド定義 |
| `secrets.yaml` | Tailscale authkey（sops + age で暗号化） |
| `quadlet/vaultwarden.container` | Vaultwarden コンテナ定義 |
| `quadlet/vaultwarden-ts.container.tmpl` | Tailscale サイドカーテンプレート |
| `quadlet/vaultwarden-ts-serve.json` | Tailscale Serve 設定 |
| `quadlet/vaultwarden-data.volume` | データボリューム |
| `quadlet/vaultwarden-ts-state.volume` | Tailscale state ボリューム |

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

| コマンド | 説明 |
|---------|------|
| `just vaultwarden deploy` | Quadlet ファイルインストール + daemon-reload |
| `just vaultwarden start` | サービス起動 |
| `just vaultwarden stop` | サービス停止 |
| `just vaultwarden status` | サービス状態確認 |
| `just vaultwarden logs` | ログ表示 |
| `just vaultwarden update` | コンテナイメージ更新 |

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
- ドメイン: `vaultwarden.REDACTED.ts.net`
- ネットワーク: `container:systemd-vaultwarden-ts` で sidecar に接続

## 設計判断

### テンプレート管理

`vaultwarden-ts.container.tmpl` にプレースホルダ `__TS_AUTHKEY__` を置き、`just vaultwarden deploy` 時に `sops -d` + `sed` で展開して `~/.config/containers/systemd/` に直接書き出す。chezmoi への依存を排除。
