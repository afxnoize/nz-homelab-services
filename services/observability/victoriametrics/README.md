# VictoriaMetrics

メトリクスバックエンド (Prometheus 互換)。`network_mode=host` で `:8428` に bind。

## 主要設定

| 設定            | 値    | 根拠            |
| --------------- | ----- | --------------- |
| retentionPeriod | 90d   | M1 spec 決定 #2 |
| httpListenAddr  | :8428 | ホスト全 IF     |

ディスク上限の強制オプションは VM に存在しないため、retention 90d と書き込みレートで 10 GB 以内を維持する運用方針。

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:8428/health'

# scrape target 数
just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode "query=up" | jq ".data.result | length"'

# ディスク使用量
just oci-ssh 'du -sh /var/lib/containers/storage/volumes/victoriametrics-data'
```
