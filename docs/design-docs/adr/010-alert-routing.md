# ADR-010: アラート経路の役割分担 (Gatus / vmalert / Grafana Alerting 不採用)

- **Status**: accepted
- **Date**: 2026-04-15

## Context

Phase 2 観測基盤 ([ADR-007](007-log-backend-victorialogs.md) / [ADR-008](008-alloy-unified-collector.md) / [ADR-011](011-metrics-backend-victoriametrics.md)) の導入により、アラート発火経路の候補が複数並立する状態になる。

現状の経路:

- **Gatus** + Telegram: 外形監視 (endpoint up/down, TLS 期限)

追加可能性のある経路:

- **vmalert**: VictoriaMetrics のクエリ結果に対するルール評価 → 通知
- **Grafana Alerting**: Grafana UI 上で定義されたアラートルール → 通知

このまま何も決めないと、同じ事象 (例: サービス down) が複数経路から通知され得る。また「どのツールで何を見るか」が属人化する。事象の性質に応じた責務分離を明文化する必要がある。

## Decision

**事象の性質で発火源を分離する。採用は Gatus + vmalert の 2 系統、Grafana Alerting は採用しない。**

| 種別                                                             | 発火源               | 通知 sink                                       | 対象                               |
| ---------------------------------------------------------------- | -------------------- | ----------------------------------------------- | ---------------------------------- |
| 外形監視 (endpoint up/down, TLS 期限, HTTP status, 応答時間閾値) | **Gatus**            | Telegram                                        | ユーザから見える可用性             |
| メトリクスベースアラート (リソース枯渇, SLO 違反, exporter 由来) | **vmalert**          | 実装時に決定 (Alertmanager / webhook 直送 / 他) | ホスト・コンテナ・アプリの内部状態 |
| ダッシュボード上のアラート定義                                   | **Grafana Alerting** | — (採用しない)                                  | —                                  |

### 採用方針

- **Gatus は残す**: 合成検査 (実際にエンドポイントを叩いて応答を見る) は vmalert の「メトリクスが欠損した」判定とは性質が違う。ユーザ体験に最も近い層の監視として独立させる
- **vmalert を導入する**: VictoriaMetrics に乗るメトリクス (ホスト、コンテナ、アプリ exporter) はすべて vmalert のルール評価対象とする
- **Grafana はダッシュボード + 探索 UI に限定する**: アラート評価ロジックを Grafana に閉じ込めない

### 却下理由 (Grafana Alerting)

- vmalert と責務が重複する。同じメトリクスに 2 つの評価エンジンを並べる意義がない
- Grafana の UI に依存すると、データソース差し替え (VM → 他) やスタック縮退時にアラートごと失う
- Grafana 単体の可用性にアラート経路が結びつくと、「Grafana 落ちたらアラート止まる」という単一障害点が増える
- アラートルールのバージョン管理が UI 定義に引っ張られやすく、コードベースとの整合が崩れやすい

### 却下理由 (Gatus を廃止して vmalert 一本化)

- 合成検査を「メトリクス化してから評価」する迂回路は経路が長くなる割に旨味が薄い
- 既存の Gatus + Telegram フローが安定して動作しており、捨てる理由がない
- 外部から見た可用性と内部メトリクスは別軸で持ちたい (内部が全部緑なのに外形が赤い、はよくある)

## Consequences

### 良い面

- 通知の発火源が事象の性質と 1:1 に対応し、「どのツールで何を見るか」が明確になる
- Grafana のスタック依存を切り離すことで、観測スタックの可用性問題がアラート経路を巻き込まない
- アラートルールは vmalert YAML としてコード管理できる (Grafana の UI 定義に比べて git 親和性が高い)

### 悪い面

- 通知 sink が 2 系統になる (Gatus → Telegram 直、vmalert → 別経路)。通知の一元化 (例: Alertmanager で dedup / silence / routing) を望む場合は追加設計が必要
- vmalert の通知先選定 (Alertmanager を挟むか否か) が未決のまま残る
- Grafana Alerting を使わないため、ダッシュボード UI 上でアラート状態を直接確認する UX は失う (別途 vmalert UI or Alertmanager UI を見に行く)

### 波及する未決事項

- vmalert の通知 sink: Alertmanager 経由か、webhook 直接 Telegram かを実装時に決定
- Gatus 側の通知と vmalert 側の通知の整合 (同一サービスの障害が二重通知されるケースの扱い)
- 本 ADR は [ADR-011](011-metrics-backend-victoriametrics.md) (VictoriaMetrics 採用) を前提とする
