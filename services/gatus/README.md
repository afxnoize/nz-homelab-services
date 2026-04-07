# gatus

Gatus ヘルスチェックダッシュボードを Podman Quadlet で運用。サービス障害時に Telegram で通知する。

## 構成

| ファイル | 役割 |
|---------|------|
| `Justfile` | 操作コマンド定義 |
| `secrets.yaml` | Telegram Bot Token / Chat ID（sops + age で暗号化） |
| `config.yaml.tmpl` | Gatus 設定テンプレート（gomplate で展開） |
| `quadlet/gatus.container` | Gatus コンテナ定義 |
| `quadlet/gatus-data.volume` | データボリューム（SQLite） |

## セットアップ

### 1. Telegram Bot 作成

1. Telegram で `@BotFather` に `/newbot` を送信
2. Bot Token を取得
3. Bot とのチャットで `/start` を送信
4. `https://api.telegram.org/bot<TOKEN>/getUpdates` で Chat ID を取得

### 2. secrets 編集

```bash
sops services/gatus/secrets.yaml
```

`TELEGRAM_BOT_TOKEN` と `TELEGRAM_CHAT_ID` を記入する。

### 3. デプロイ

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
| `just gatus status` | サービス状態確認 |
| `just gatus logs` | ログ表示 |
| `just gatus logs-follow` | ログをリアルタイム追従 |
| `just gatus update` | コンテナイメージ更新 |

## アーキテクチャ

```
[Gatus container]
        │
        ├── HTTPS → vaultwarden.<TS_DOMAIN>/alive
        ├── HTTPS → vaultwarden.<TS_DOMAIN> (Tailscale 疎通確認)
        │
        ▼
[Telegram Bot API] → 通知
        │
        ▼
gatus-data (volume / SQLite)
```

- ダッシュボード: `http://127.0.0.1:8080`（ローカルのみ公開）
- 監視対象: Vaultwarden（HTTPS ヘルス + Tailscale 疎通）
- 通知: Telegram（障害検知 + 復旧通知）
