# VictoriaLogs

ログバックエンド。`network_mode=host` で `:9428` に bind。

## 主要設定

| 設定                        | 値    | 根拠             |
| --------------------------- | ----- | ---------------- |
| retentionPeriod             | 30d   | M1 spec 決定 #1  |
| retention.maxDiskSpaceUsage | 15GB  | OCI 100GB 内配分 |
| httpListenAddr              | :9428 | ホスト全 IF      |

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:9428/health'

# 直近 5 分のログ件数
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query --data-urlencode "query=_time:5m" | wc -l'

# ディスク使用量
just oci-ssh 'du -sh /var/lib/containers/storage/volumes/victorialogs-data'
```
