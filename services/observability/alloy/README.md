# Alloy

統一コレクタ。`network_mode=host` で journald / ホスト node メトリクス / Alloy self メトリクスを収集し、VL (loki push) / VM (remote_write) に送信。

## 収集対象 (M1)

| ソース                         | 宛先 | config.alloy ブロック             |
| ------------------------------ | ---- | --------------------------------- |
| journald                       | VL   | loki.source.journal "system"      |
| ホスト node (unix exporter)    | VM   | prometheus.scrape "node"          |
| Alloy self (/metrics)          | VM   | prometheus.scrape "alloy"         |
| AdGuard querylog (M4 で有効化) | VL   | loki.source.file (コメントアウト) |

## 設定メモ

`--disable-reporting` で Grafana への usage report を無効化している。送信先 `stats.grafana.org` は AdGuard の `||stats.grafana.org^` ルールでブロックされ `0.0.0.0` / `::` に解決されるため、有効のままだと数時間おきに `failed to report usage` が warn で出続ける。

## トラブルシュート

```bash
# ヘルスチェック
just oci ssh 'curl -s http://127.0.0.1:12345/-/healthy'

# scrape targets 確認
just oci ssh 'curl -s http://127.0.0.1:12345/api/v1/targets'

# config reload
just oci ssh 'curl -X POST http://127.0.0.1:12345/-/reload'
```
