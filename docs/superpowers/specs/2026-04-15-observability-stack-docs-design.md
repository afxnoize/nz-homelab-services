# Observability スタック docs 設計 spec

## 概要

ホームラボ観測基盤 (log / metric / alert) を Phase 2 構成 **Alloy + VictoriaLogs + VictoriaMetrics + Grafana** に移行するにあたって、**先行して docs (ADR + pattern + AGENTS.md) を整備する**ための設計 spec。

本 spec 自身はメタ文書であり、実装は扱わない。実装 (Alloy / VictoriaLogs / VictoriaMetrics / Grafana の quadlet-nix 化) は `feat/` ブランチで別作業として後続する。

### スコープ

- **in scope**: ADR-006 supersede / ADR-007 / ADR-008 / ADR-010 / ADR-011 執筆、log-strategy.md 更新、index.md 更新、AGENTS.md 技術スタック行更新
- **out of scope**:
  - Alloy / VictoriaLogs / VictoriaMetrics / Grafana の quadlet-nix 実装
  - Alertmanager 導入可否の最終判断 (ADR-010 で「経路役割分担」までは決めるが、vmalert の通知 sink 選択は後続実装時に詰める)
  - cadvisor / node_exporter 等の個別 exporter 追加判断
  - WSL2 側 Alloy の push 経路詳細 (Tailnet ACL 設定 / mTLS 要否など)
  - ダッシュボード・保持期間・ログ量見積りの具体数字

### 成果物

1 ブランチ (`docs/observability-adrs`) に 7 commit を積み、PR 1 本で main に merge する。

| #   | Commit                                                               | ファイル                                                                                         |
| --- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 1   | `docs(adr): ADR-006 を ADR-008 により supersede`                     | `docs/design-docs/adr/006-*.md`                                                                  |
| 2   | `docs(adr): ADR-007 ログバックエンドに VictoriaLogs を採用`          | `docs/design-docs/adr/007-log-backend-victorialogs.md` (新規)                                    |
| 3   | `docs(adr): ADR-008 Alloy 統一コレクタを採用`                        | `docs/design-docs/adr/008-alloy-unified-collector.md` (新規)                                     |
| 4   | `docs(patterns): log-strategy.md を Alloy + VL 前提に更新`           | `docs/design-docs/patterns/log-strategy.md`, `docs/design-docs/index.md`                         |
| 5   | `docs(adr): ADR-010 アラート経路役割分担`                            | `docs/design-docs/adr/010-alert-routing.md` (新規)                                               |
| 6   | `docs(adr): ADR-011 メトリクスバックエンドに VictoriaMetrics を採用` | `docs/design-docs/adr/011-metrics-backend-victoriametrics.md` (新規)                             |
| 7   | `docs(spec): observability stack docs design spec 追加`              | `docs/superpowers/specs/2026-04-15-observability-stack-docs-design.md` (本ファイル), `AGENTS.md` |

Commit 1-4 は stash 復元分 (既にドラフト済み)、5-7 は本セッションで新規執筆。

---

## 背景

### 現状 (Phase 1)

- 全コンテナ `LogDriver=journald` で journald に集約 ([log-strategy.md](../../design-docs/patterns/log-strategy.md))
- 例外: AdGuard Home の querylog は fluent-bit サイドカーで tail → stdout → journald ([ADR-006](../../design-docs/adr/006-adguard-querylog-fluent-bit-sidecar.md))
- 外形監視: Gatus + Telegram 通知
- メトリクス基盤: なし

### 環境確定による再評価

OCI Always Free の **Ampere A1 (aarch64, 4 OCPU / 24 GB RAM)** にホストが確定したことで、Phase 2 の素案 (Grafana + Loki) を見直す必要が出た。

- RAM 予算が既存サービスとの共有で厳しい → 重量級スタックを回避したい
- aarch64 対応必須
- 単一ホスト運用 → クラスタ前提のスタックは過剰

この再評価の結果を 2 軸 (log / metric) で ADR 化し、さらに **Gatus を残すか** というアラート経路の役割分担も明文化する。これが本 spec の動機。

---

## 決定事項サマリ

### ADR-007: ログバックエンド

**VictoriaLogs を採用。Loki は却下。**

- 単一バイナリ / メモリフットプリント数百 MB / aarch64 対応
- Loki は Ampere A1 のリソース予算に対し monolithic モードでも重い
- VictoriaMetrics との運用統一感 (同一哲学・設定言語ファミリ) を評価軸に含めた

### ADR-008: コレクタ

**Alloy をホスト単一エージェントに集約。fluent-bit サイドカーは廃止し ADR-006 を supersede。**

- journald source + file source + prometheus scrape / remote_write を 1 プロセスで担当
- ログ経路が 1 ホップに短縮 (fluent-bit + Alloy の 2 エージェント併存を回避)
- WSL2 ホストも同構成、Tailnet 越しに OCI の VL/VM へ push

### ADR-010: アラート経路役割分担 (新規)

**責務分離**:

| 種別                                                             | ツール                                     | 対象                                |
| ---------------------------------------------------------------- | ------------------------------------------ | ----------------------------------- |
| 外形監視 (endpoint up/down, TLS 期限)                            | **Gatus** → Telegram                       | 既存、変更なし                      |
| メトリクスベースアラート (リソース枯渇、SLO 違反、exporter 由来) | **vmalert** → (通知 sink は後続実装で決定) | 新規                                |
| Grafana Alerting                                                 | **採用しない**                             | vmalert と責務重複、UI 依存を避ける |

- 外形監視とメトリクスアラートは発火源の性質が違う (合成検査 vs ルール評価) ので別ツールで扱う
- Grafana はダッシュボードと探索 UI に限定し、アラート評価ロジックは Grafana に閉じ込めない (データソース差し替え耐性)
- vmalert の通知先 (Alertmanager 経由 / 直接 webhook / Telegram 統合) は実装時に決める。本 ADR では **責務分担の原則**のみ固定

### ADR-011: メトリクスバックエンド (新規)

**VictoriaMetrics を採用。Prometheus 単体 / Mimir は却下。**

- 単一バイナリ / PromQL 互換 / aarch64 対応 / low memory
- Prometheus 単体: 長期保持とバックアップで追加運用が必要。single-node HA なし
- Mimir: クラスタ前提、単一ホーム VM には過剰
- VictoriaLogs と同一エコシステム (運用観・設定思想) を揃えることで認知負荷を下げる

### AGENTS.md 更新

技術スタック表に以下を追記:

```
| 観測スタック   | Alloy + VictoriaLogs + VictoriaMetrics + Grafana (Phase 2) |
| アラート       | Gatus (外形) + vmalert (メトリクス) + Telegram             |
```

---

## ADR 依存関係

```
ADR-006 (fluent-bit サイドカー)
    │ superseded by
    ▼
ADR-008 (Alloy 統一コレクタ) ◄── depends on ── ADR-007 (VictoriaLogs)
    │
    │ collects metrics for
    ▼
ADR-011 (VictoriaMetrics) ◄── referenced by ── ADR-010 (アラート経路)
    │
    └── evaluated by ── vmalert
```

- ADR-007 → ADR-008 は論理依存 (バックエンド確定後にコレクタを決める)。ただし commit/PR 上は順に並べるだけで、どちらも本ブランチ内に揃うので merge 順依存はない
- ADR-010 は ADR-011 (vmalert のホスト) に依存するが、ADR 番号参照なので PR 内順序で足りる
- ADR-009 (quadlet-nix 統一) は前提として既に main にある。本 ADR 群は全て quadlet-nix 準拠で実装される想定

---

## 実装への橋渡し (out of scope だが方向性メモ)

本 spec のスコープ外だが、後続の実装計画で扱う項目を記録しておく:

1. Alloy の quadlet-nix ユニット (OCI / WSL2 両対応、sops-nix でトークン管理)
2. VictoriaLogs quadlet-nix ユニット (保持期間 / ディスク予算)
3. VictoriaMetrics quadlet-nix ユニット (retention / remote_write 受信口)
4. Grafana quadlet-nix ユニット (datasource provisioning、認証方式)
5. vmalert のルール定義 + 通知 sink 選定 (Alertmanager か webhook 直送か)
6. 既存サービスの Quadlet に Alloy 用 ro volume マウント追加 (AdGuard querylog)
7. ADR-006 の fluent-bit サイドカー Quadlet 撤去
8. Tailnet 越しの push 認証設計 (ACL で閉じる前提)

これらは実装フェーズで個別にブランチを切る。

---

## 未解決事項

本 spec 時点で未解決 (実装時に決める):

- vmalert の通知 sink: Alertmanager 導入するか、webhook 直送で Telegram に入れるか
- WSL2 → OCI の push 認証: Tailscale ACL のみで十分か、追加の token/mTLS が必要か
- ログ保持期間とディスク予算 (OCI 200GB ブートボリューム内での配分)
- cadvisor / node_exporter 等の追加 exporter 採用可否
- ダッシュボード資産: 既存 Loki 向けダッシュボードは直接流用不可 (LogQL / LogsQL 文法差)。自作か探索するか

---

## レビュー観点

PR レビュワーには以下を確認してほしい:

- ADR-007 / 011 の却下理由に homelab の制約 (単一ホスト、aarch64、RAM 予算) が明示されているか
- ADR-008 の移行手順に ADR-006 supersede の段取りが含まれているか
- ADR-010 で「なぜ Grafana Alerting を使わないか」の理由が妥当か
- log-strategy.md の Phase 2 図が ADR-008 の構成図と整合しているか
- AGENTS.md の技術スタック行が他のサービス行と粒度が揃っているか
