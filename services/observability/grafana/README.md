# Grafana

可視化 UI。Tailscale Serve 経由で HTTPS 公開。

## Datasource

| 名前            | タイプ                          | URL                                  |
| --------------- | ------------------------------- | ------------------------------------ |
| VictoriaLogs    | victoriametrics-logs-datasource | http://host.containers.internal:9428 |
| VictoriaMetrics | prometheus                      | http://host.containers.internal:8428 |

## ダッシュボード

provisioning で `/etc/grafana/provisioning/dashboards/` 配下の JSON を自動読み込み。変更は Grafana UI で行った後 JSON エクスポートしてリポジトリにコミットする。

## トラブルシュート

```bash
# ヘルスチェック
# 注: Grafana は container:grafana-ts の namespace 内にいるため、
# ホストからは直接届かない。Tailscale 経由でアクセスする。

# VL plugin インストール確認
just observability logs grafana 20  # "Plugin victoriametrics-logs-datasource installed" を確認
```
