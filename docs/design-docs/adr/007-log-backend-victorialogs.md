# ADR-007: ログ集約バックエンドに VictoriaLogs を採用（Loki を却下）

- **Status**: accepted
- **Date**: 2026-04-15

## Context

[log-strategy.md](../patterns/log-strategy.md) の Phase 2 として、journald 依存から外部ログ基盤への移行を計画している。当初素案では Grafana + Loki を想定していたが、ホスト環境が OCI Always Free の Ampere A1 (aarch64, 4 OCPU / 24GB RAM を既存サービスと共有) に確定したため、バックエンド選定を再評価する必要が生じた。

制約と前提:

- 単一ホスト運用（OCI 側）。WSL2 のログはホスト越し（Tailnet）で push する構成
- aarch64 対応必須
- ログ保持量は homelab スケール（数十 GB / 月オーダー）
- 既存 B2 バケットはバックアップ専用で流用しない（[memory: OCI にバックアップは移行しない] の方針とは別に、ログの object storage 退避までは不要と判断）
- メトリクス基盤の導入も同時並行で検討中のため、ログ基盤選択はメトリクス側との運用一貫性も評価軸に含める

## Decision

**ログ集約バックエンドに VictoriaLogs を採用する。Loki は却下する。**

メトリクス基盤は別 ADR で扱うが、本判断は VictoriaMetrics 採用を前提とした運用統一感を評価軸の一つとしている。

### 評価

| 観点                           | Loki                                              | VictoriaLogs                       |
| ------------------------------ | ------------------------------------------------- | ---------------------------------- |
| RAM 使用量                     | 数 GB オーダー（monolithic でも）                 | 数百 MB                            |
| 構成要素                       | ingester / querier / compactor / index-gateway 等 | 単一バイナリ                       |
| ストレージ                     | 最小は fs、本番想定は S3 互換                     | ローカル fs                        |
| クエリ言語                     | LogQL（成熟、ドキュメント豊富）                   | LogsQL（シンプル、エコシステム小） |
| Grafana 連携                   | ネイティブ                                        | datasource plugin（機能充足）      |
| aarch64 対応                   | ◎                                                 | ◎                                  |
| VictoriaMetrics との運用統一感 | 別思想                                            | 同一哲学・同一運用感               |

### 却下理由（Loki）

- OCI Ampere A1 のリソース予算に対してメモリフットプリントが重い
- monolithic モードで単一ノード運用は可能だが、複数内部コンポーネントの認知負荷は単一バイナリに劣る
- 強みである object storage バックエンドは、homelab 規模では過剰装備

### 採用理由（VictoriaLogs）

- 単一バイナリで Quadlet パターンに素直に乗る
- メモリフットプリントが Loki 比で 1 桁以上小さく、既存サービスとの共存が現実的
- VictoriaMetrics を別途採用する場合、設定言語・運用観・ドキュメント体系が共通化できる

## Consequences

### 良い面

- OCI Ampere A1 のリソース制約内に収まる
- 単一バイナリ運用で Quadlet・systemd との親和性が高い
- VictoriaMetrics と合わせて運用認知負荷を一元化できる

### 悪い面

- Loki 比でエコシステムが小さい。サードパーティ連携（例: 既存の Loki 向けダッシュボード資産）は直接使えない場合がある
- LogsQL は LogQL とは別文法。既存の LogQL 知識は流用できない
- object storage への階層化は現状想定しない。保持期間とローカルディスク容量のトレードオフは運用で管理する必要がある
- 比較的新しいプロジェクトのため、障害時の情報量は Loki に劣る

### 波及する未決事項

- コレクタ選定（Alloy / fluent-bit / 併用）は別 ADR で扱う
- メトリクス基盤（VictoriaMetrics 採用可否）は別 ADR で扱う
- アラート経路（vmalert / Grafana Alerting / 既存 Gatus + Telegram との役割分担）は別途整理
- [log-strategy.md](../patterns/log-strategy.md) の Phase 2 記述を本 ADR 採用時に書き換え
