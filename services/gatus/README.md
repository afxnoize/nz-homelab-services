# gatus

Gatus ヘルスチェックダッシュボードを Podman Quadlet で運用。Tailscale サイドカーコンテナ経由で HTTPS アクセスを提供し、サービス障害時に Telegram で通知する。

## 構成

| ファイル | 役割 |
|---------|------|
| `Justfile` | 操作コマンド定義 |
| `secrets.yaml` | Telegram Bot Token / Chat ID / Tailscale authkey（sops + age で暗号化） |
| `config.yaml.tmpl` | Gatus 設定テンプレート（gomplate で展開） |
| `quadlet/gatus.container` | Gatus コンテナ定義 |
| `quadlet/gatus-ts.container.tmpl` | Tailscale サイドカーテンプレート |
| `quadlet/gatus-ts-serve.json.tmpl` | Tailscale Serve 設定テンプレート |
| `quadlet/gatus-data.volume` | データボリューム（SQLite） |
| `quadlet/gatus-ts-state.volume` | Tailscale state ボリューム |

## セットアップ

### 1. Telegram Bot 作成

1. Telegram で `@BotFather` に `/newbot` を送信
2. Bot Token を取得
3. Bot とのチャットで `/start` を送信
4. `https://api.telegram.org/bot<TOKEN>/getUpdates` で Chat ID を取得

### 2. Tailscale authkey 取得

Tailscale admin console で authkey を発行する。

### 3. secrets 編集

```bash
sops services/gatus/secrets.yaml
```

`TELEGRAM_BOT_TOKEN`・`TELEGRAM_CHAT_ID`・`ts_authkey` を記入する。

### 4. デプロイ

```bash
nix develop
just gatus deploy
just gatus start
```

## コマンド

| コマンド | 説明 |
|---------|------|
| `just gatus deploy` | 設定生成 + Quadlet インストール + daemon-reload |
| `just gatus start` | サービス起動 |
| `just gatus stop` | サービス停止 |
| `just gatus restart` | サービス再起動 |
| `just gatus status` | サービス状態確認 |
| `just gatus logs` | ログ表示 |
| `just gatus logs-follow` | ログをリアルタイム追従 |
| `just gatus update` | コンテナイメージ更新 |

## アーキテクチャ

```
[Tailscale network]
        │
        ▼
gatus-ts (tailscale sidecar)
        │  TS_SERVE: :443 → http://127.0.0.1:8080
        │
        ▼
gatus (dashboard)
        │
        ├── HTTPS → vaultwarden.<TS_DOMAIN>/alive
        ├── HTTPS → adguard-home.<TS_DOMAIN>/login.html
        │
        ▼
[Telegram Bot API] → 通知
        │
        ▼
gatus-data (volume / SQLite)
```

- Tailscale Serve で HTTPS 終端し、gatus にリバースプロキシ
- ドメイン: `gatus.<MagicDNS suffix>` (deploy 時に自動取得)
- ネットワーク: `container:systemd-gatus-ts` で sidecar に接続
- 監視対象: Vaultwarden / AdGuard Home（HTTPS ヘルス + Tailscale 疎通）
- 通知: Telegram（障害検知 + 復旧通知）
