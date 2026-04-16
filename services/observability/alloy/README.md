# Alloy

統一コレクタ。`network_mode=host` で journald / ホスト node メトリクス / Alloy self メトリクスを収集し、VL (loki push) / VM (remote_write) に送信。

## 収集対象 (M1)

| ソース                         | 宛先 | config.alloy ブロック             |
| ------------------------------ | ---- | --------------------------------- |
| journald                       | VL   | loki.source.journal "system"      |
| ホスト node (unix exporter)    | VM   | prometheus.scrape "node"          |
| Alloy self (/metrics)          | VM   | prometheus.scrape "alloy"         |
| AdGuard querylog (M4 で有効化) | VL   | loki.source.file (コメントアウト) |

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:12345/-/healthy'

# scrape targets 確認
just oci-ssh 'curl -s http://127.0.0.1:12345/api/v1/targets'

# config reload
just oci-ssh 'curl -X POST http://127.0.0.1:12345/-/reload'
```
