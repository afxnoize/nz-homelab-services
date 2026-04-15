# ADR-011: メトリクスバックエンドに VictoriaMetrics を採用 (Prometheus 単体 / Mimir を却下)

- **Status**: accepted
- **Date**: 2026-04-15

## Context

[ADR-007](007-log-backend-victorialogs.md) でログバックエンドを VictoriaLogs に確定した。並行してメトリクスバックエンドも導入する必要があり、候補を評価する。

制約は [ADR-007](007-log-backend-victorialogs.md) と同一:

- OCI Always Free Ampere A1 (aarch64, 4 OCPU / 24 GB RAM、既存サービスと共有)
- 単一ホスト運用 (OCI)、WSL2 からは Tailnet 越しに push
- aarch64 対応必須
- homelab スケール (メトリクス点数 / 書き込みレートは小規模)

評価対象:

- **Prometheus 単体** (scrape + TSDB + alerting の伝統的なスタック)
- **Grafana Mimir** (Prometheus 互換、水平スケール対応の長期ストレージ)
- **VictoriaMetrics** (Prometheus 互換、単一バイナリの高性能 TSDB)

## Decision

**VictoriaMetrics を採用する。Prometheus 単体と Mimir は却下する。**

### 評価

| 観点                        | Prometheus 単体                | Mimir                                             | VictoriaMetrics               |
| --------------------------- | ------------------------------ | ------------------------------------------------- | ----------------------------- |
| RAM 使用量                  | 中 (設定依存)                  | 大 (複数コンポーネント)                           | 小                            |
| 構成要素                    | 単一バイナリ                   | ingester / querier / store-gateway / compactor 等 | 単一バイナリ (vmsingle)       |
| ストレージ                  | ローカル fs                    | object storage 前提                               | ローカル fs                   |
| PromQL 互換                 | ネイティブ                     | 完全互換                                          | ほぼ完全互換 (拡張 MetricsQL) |
| 長期保持                    | 自前運用 (圧縮 / バックアップ) | 強み                                              | 標準機能                      |
| aarch64 対応                | ◎                              | ◎                                                 | ◎                             |
| VictoriaLogs との運用統一感 | 別思想                         | 別思想                                            | 同一哲学・同一運用感          |

### 採用理由 (VictoriaMetrics)

- 単一バイナリ (vmsingle) で Quadlet / systemd 統合が素直
- メモリフットプリントが Prometheus 比でも小さい (圧縮効率が高い)
- 長期保持 / リテンションが標準機能で、別途 object storage 階層化設計が不要 (homelab スケールでは)
- VictoriaLogs と設定思想・運用観が揃う → 認知負荷が一元化
- PromQL クエリ・エコシステム (Grafana datasource, exporter 群) はそのまま使える

### 却下理由 (Prometheus 単体)

- 長期保持を真面目にやろうとするとバックアップ設計・ディスク予算管理を自前で持つ必要がある
- 圧縮効率・リソース効率で VictoriaMetrics に劣る
- 単一ノード構成で HA なし (これは VictoriaMetrics も同じだが、差別化要因としては弱い)
- 本 homelab の規模では「デファクト」以上の採用理由が薄い

### 却下理由 (Mimir)

- クラスタ前提 (ingester / querier / store-gateway / compactor 等複数コンポーネント) で、単一 VM 1 ホームには過剰
- object storage 依存が前提。OCI Object Storage を運用に組み込む追加コスト
- リソース予算 (Ampere A1 + 既存サービス共存) に対して重い
- 規模に対して設計が大仰すぎる

## Consequences

### 良い面

- VictoriaLogs と合わせて、観測スタック全体が VictoriaSuite 由来で運用観が統一
- 単一バイナリで Quadlet / NixOS モジュールが単純
- PromQL 資産 (ダッシュボード, exporter) はそのまま流用できる
- [ADR-010](010-alert-routing.md) で採用する vmalert とネイティブ統合

### 悪い面

- 単一ノードのためバックアップ戦略を別途検討する必要がある ([memory: OCI にバックアップは移行しない] の方針との整合も含めて判断)
- MetricsQL 拡張構文を使うと純粋な PromQL 以外のロックインが発生する (使わなければ問題ない)
- Mimir / Cortex 系のクラスタ運用知見を得る機会は失う (homelab 用途では不要)
- 比較的新しい (Prometheus に比べて) プロジェクトのため、障害時の情報量はデファクトに劣る

### 波及する未決事項

- retention / ディスク予算 (OCI 200 GB ブートボリューム内の配分) は実装時に決定
- backup 戦略 (vmbackup を使うか、ディスクレベルスナップショットで済ますか)
- WSL2 からの remote_write 認証 (Tailscale ACL のみで閉じる / 追加 token)
- AGENTS.md 技術スタック表への追記は spec コミットで実施
