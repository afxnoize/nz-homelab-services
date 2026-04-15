# ollama

Ollama (LLM 推論サーバー) + Open WebUI を Podman Quadlet で運用。Tailscale サイドカーコンテナ経由で HTTPS アクセスを提供する。

> **注意**: このサービスは WSL2 マシン上で動作する。現在のホストの `deploy-all` には含まれない。

## 前提条件

- WSL2 + Podman + NVIDIA GPU セットアップ完了 → [手順書](docs/wsl-podman-gpu-setup.md)
- NVIDIA CDI スペック生成済み (`nvidia-ctk cdi list` で確認)
- `loginctl enable-linger` 設定済み

## 構成

| ファイル                             | 役割                                     |
| ------------------------------------ | ---------------------------------------- |
| `Justfile`                           | 操作コマンド定義                         |
| `secrets.yaml`                       | Tailscale authkey（sops + age で暗号化） |
| `quadlet/ollama.container`           | Ollama コンテナ (GPU)                    |
| `quadlet/open-webui.container`       | Open WebUI コンテナ                      |
| `quadlet/ollama-ts.container.tmpl`   | Tailscale サイドカーテンプレート         |
| `quadlet/ollama-ts-serve.json.tmpl`  | Tailscale Serve 設定テンプレート         |
| `quadlet/ollama-data.volume`         | モデルデータボリューム                   |
| `quadlet/open-webui-data.volume`     | Open WebUI データボリューム              |
| `quadlet/ollama-ts-state.volume`     | Tailscale state ボリューム               |
| `systemd/ollama-ts-watchdog.service` | Tailscale ヘルスチェック + 自動復旧      |
| `systemd/ollama-ts-watchdog.timer`   | Watchdog 実行タイマー (2分間隔)          |

## セットアップ

### 1. Tailscale authkey 取得

Tailscale admin console で authkey を発行する。

### 2. secrets 編集

```bash
sops services/ollama/secrets.yaml
```

`ts_authkey` を記入する。

### 3. デプロイ

```bash
nix develop
just ollama deploy
just ollama start
```

## コマンド

| コマンド                      | 説明                                         |
| ----------------------------- | -------------------------------------------- |
| `just ollama deploy`          | Quadlet ファイルインストール + daemon-reload |
| `just ollama start`           | サービス起動                                 |
| `just ollama stop`            | サービス停止                                 |
| `just ollama restart`         | サービス再起動                               |
| `just ollama status`          | サービス状態確認                             |
| `just ollama logs`            | ログ表示                                     |
| `just ollama logs-follow`     | ログフォロー                                 |
| `just ollama update`          | コンテナイメージ更新                         |
| `just ollama watchdog-on`     | Watchdog タイマー有効化                      |
| `just ollama watchdog-off`    | Watchdog タイマー無効化                      |
| `just ollama watchdog-status` | Watchdog 状態確認                            |

## アーキテクチャ

```
[Tailscale network]
        │
        ▼
ollama-ts (tailscale sidecar)
        │  TS_SERVE: :443  → http://127.0.0.1:8080 (Open WebUI)
        │  TCP:      :11434 → 127.0.0.1:11434      (Ollama API)
        │
        ├── ollama (GPU, :11434)
        │     │
        │     ▼
        │   ollama-data (volume)
        │
        └── open-webui (:8080)
              │
              ▼
            open-webui-data (volume)
```

- Tailscale Serve で HTTPS 終端 → Open WebUI にリバースプロキシ
- Ollama API は TCP proxy で Tailnet に直接露出 (Aider 等から利用)
- ネットワーク: 3コンテナが `container:systemd-ollama-ts` で名前空間を共有
- GPU: `AddDevice=nvidia.com/gpu=all` (NVIDIA CDI)

## アクセス

| 用途                  | URL                                     |
| --------------------- | --------------------------------------- |
| Open WebUI (ブラウザ) | `https://ollama.<MagicDNS suffix>/`     |
| Ollama API (Aider 等) | `http://ollama.<MagicDNS suffix>:11434` |

> **セキュリティ注意**: Ollama API (`:11434`) は認証なしで Tailnet 全体に公開される。モデルの追加・削除・推論が Tailnet 内の任意のデバイスから可能。必要に応じて Tailscale ACL でアクセスを制限すること。

## Watchdog (スリープ復帰対策)

WSL2 の Windows スリープ復帰後、Tailscale サイドカーが再接続に失敗する問題への対策。2分間隔で `ollama-ts` のヘルスチェックを監視し、unhealthy なら自動で restart する。

```bash
just ollama watchdog-on    # 有効化（初回のみ）
just ollama watchdog-off   # 無効化
just ollama watchdog-status
```
