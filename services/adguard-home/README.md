# AdGuard Home

Tailnet 内の DNS サーバー。AdGuard Home + Tailscale Sidecar パターン。

## 構成

| コンポーネント      | 役割                                                  |
| ------------------- | ----------------------------------------------------- |
| `adguard-home`      | AdGuard Home 本体（DNS + Web UI）                     |
| `adguard-home-ts`   | Tailscale サイドカー（Web UI を Tailscale Serve 公開）|

### ネットワーク設計

DNS（UDP/TCP 53）は Tailscale Serve（HTTP プロキシ）を通せないため、Tailscale コンテナとネットワーク名前空間を共有することで Tailscale IP に直接バインドする。

```
Tailnet クライアント
  ├── :53  (UDP/TCP) → adguard-home-ts コンテナ IP → AdGuard Home DNS
  └── :443 (HTTPS)  → Tailscale Serve → AdGuard Home Web UI (:3000)
```

`TS_EXTRA_ARGS=--accept-dns=false` で自己参照ループを防いでいる。

## セットアップ

### 1. シークレット作成

```bash
cp secrets.example.yaml secrets.yaml
sops --encrypt --in-place secrets.yaml
```

`ts_authkey` には Tailscale Admin Console で発行した authkey を設定する。

### 2. デプロイ

```bash
just adguard-home deploy
just adguard-home start
```

`AdGuardHome.yaml` が設定済みの状態でマウントされるのでセットアップウィザードはスキップされる。

### 3. Tailscale DNS 設定

Tailscale Admin Console → DNS → Nameservers に AdGuard Home の Tailscale IP を登録する。

```
# Tailscale IP 確認
tailscale status | grep adguard-home
```

## 運用

```bash
just adguard-home status       # サービス状態確認
just adguard-home logs         # ログ確認（直近 50 件）
just adguard-home logs-follow  # ログ追跡
just adguard-home restart      # 再起動
just adguard-home update       # イメージ更新
```

## ファイル構成

```
services/adguard-home/
├── Justfile
├── AdGuardHome.yaml                      # AdGuard Home 設定（リポジトリ管理）
├── secrets.yaml                          # SOPS 暗号化済み（ts_authkey）
├── secrets.example.yaml
├── README.md
└── quadlet/
    ├── adguard-home.container.tmpl       # AdGuard Home 本体
    ├── adguard-home-ts.container.tmpl    # Tailscale サイドカー
    ├── adguard-home-ts-serve.json.tmpl   # Tailscale Serve 設定（Web UI）
    ├── adguard-home-data.volume          # AdGuard Home データ永続化（querylog, stats）
    └── adguard-home-ts-state.volume      # Tailscale 状態永続化
```
