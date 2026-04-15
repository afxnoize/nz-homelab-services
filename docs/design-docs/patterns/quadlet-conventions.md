# Quadlet 構成規約

## ファイル種別と用途

| 拡張子            | 用途                             | デプロイ方法                        |
| ----------------- | -------------------------------- | ----------------------------------- |
| `.container`      | 静的なコンテナ定義               | `cp` でそのままコピー               |
| `.container.tmpl` | 秘匿値や動的値を含むコンテナ定義 | `sops exec-env` + `gomplate` で展開 |
| `.volume`         | 名前付きボリューム               | `cp` でそのままコピー               |

## 標準的なコンテナ設定

```ini
[Container]
AutoUpdate=registry     # podman auto-update でイメージ自動更新
LogDriver=journald      # journalctl でログを統一管理
HealthCmd=...           # ヘルスチェック（不要なら HealthCmd=none）

[Service]
Restart=always

[Install]
WantedBy=default.target
```

## デプロイ先

`~/.config/containers/systemd/`（`$XDG_CONFIG_HOME/containers/systemd/`）
