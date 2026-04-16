# Observability 実装ロードマップ spec

## 概要

Phase 2 観測スタック (Alloy + VictoriaLogs + VictoriaMetrics + Grafana + vmalert) の実装を 5 個のマイルストン (M1〜M5) に分解し、**順序・依存・完了定義・決定ロック**を固定するロードマップ spec。

本 spec はロードマップであり、各マイルストン spec の親文書となる。実装の詳細 (quadlet-nix の具体コード、保持期間の具体値、ルール定義、ダッシュボード JSON 等) は各 M の個別 spec に委ねる。

### 上流ドキュメント

- [ADR-007 ログバックエンドに VictoriaLogs を採用](../../design-docs/adr/007-log-backend-victorialogs.md) (PR #10 merged)
- [ADR-008 Alloy 統一コレクタ](../../design-docs/adr/008-alloy-unified-collector.md) (PR #10 merged)
- [ADR-010 アラート経路役割分担](../../design-docs/adr/010-alert-routing.md) (PR #10 merged)
- [ADR-011 メトリクスバックエンドに VictoriaMetrics を採用](../../design-docs/adr/011-metrics-backend-victoriametrics.md) (PR #10 merged)
- [docs メタ spec: 2026-04-15-observability-stack-docs-design.md](./2026-04-15-observability-stack-docs-design.md) — 本 roadmap は同 spec の「実装への橋渡し」章を展開するもの

### 下流ドキュメント (本 spec が指定、後続で書く)

- `2026-XX-XX-obs-m1-foundation-design.md`
- `2026-XX-XX-obs-m2-dashboards-design.md`
- `2026-XX-XX-obs-m3-remote-alloy-design.md`
- `2026-XX-XX-obs-m4-adguard-alloy-direct-design.md`
- `2026-XX-XX-obs-m5-vmalert-design.md`

### スコープ

- **in scope**: マイルストン分解と順序、各 M の scope / done 定義 / PR 方針、既存 docs spec の未解決事項の M spec への割付、ブランチ戦略
- **out of scope**: quadlet-nix の具体コード、保持期間・ディスク予算の具体値、ルール定義・ダッシュボード JSON、通知 sink の具体実装、Tailnet ACL の具体設定

---

## マイルストン

実施順序: **M1 → M4 → M2 → M3 → M5**

### M1: 基盤バックエンド + OCI Alloy + Grafana (E2E 疎通)

| 項目         | 内容                                                                                                                                                                                                                                                                                                                                                                        |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| scope        | VictoriaLogs / VictoriaMetrics / Alloy (OCI) / Grafana の quadlet-nix 化。Alloy は journald source + **ホスト node メトリクス (内蔵 unix exporter) + Alloy self メトリクス**の scrape + remote_write / loki push を担当。Grafana に VL / VM を datasource 登録 (M1 spec で確定)                                                                                             |
| done 定義    | ① journald のログが Grafana 上で LogsQL で引ける<br>② **ホスト node + Alloy self の up メトリクスが Grafana 上で PromQL で引ける** (M1 spec 2026-04-16 で amend: 既存サービス /metrics は未実装のため M2 に移譲)<br>③ 最低 1 panel (例: 「ホスト稼働状況」) が描画される<br>④ `just oci-status` に新規 4 ユニットが反映<br>⑤ AGENTS.md / log-strategy.md / ADR-011 反映済み |
| PR           | 1 本 (`feat/obs/m1-foundation`)                                                                                                                                                                                                                                                                                                                                             |
| out of scope | WSL2 / LiRu Alloy、AdGuard querylog 直読み、vmalert、ダッシュボード整備、**既存サービス `/metrics` 有効化および scrape (M2)**                                                                                                                                                                                                                                               |

### M4: AdGuard Home fluent-bit サイドカー撤去

| 項目         | 内容                                                                                                                                                                                                                                   |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| scope        | AdGuard Home の `querylog.json` を Alloy の `loki.source.file` で直読みに切替。fluent-bit サイドカー Quadlet / 設定撤去。ADR-006 を superseded に更新                                                                                  |
| done 定義    | ① `querylog.json` の内容が VictoriaLogs に到達 (service label = adguard-home)<br>② fluent-bit ユニットが全て停止・削除<br>③ K-007 (tail 位置永続化 + querylog 保持期間短縮) が新経路で等価以上に維持<br>④ ADR-006 status が superseded |
| PR           | 1 本 (`feat/obs/m4-adguard-alloy-direct`)                                                                                                                                                                                              |
| out of scope | 他サービスのファイルログ移行 (現状 AdGuard のみ)                                                                                                                                                                                       |

### M2: 初期ダッシュボード整備

| 項目         | 内容                                                                                                                                                                                                                                                                                                                                                                 |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| scope        | **既存サービスの `/metrics` 有効化** (gatus の publishPort 経由公開、adguard-exporter サイドカー追加) + Alloy 設定への scrape 追加。ホスト / コンテナ / 既存サービスの最低限ダッシュボード整備。provisioning で git 管理。**vaultwarden は upstream PR [#6202](https://github.com/dani-garcia/vaultwarden/pull/6202) 未マージのため M2 scope 外** (M2 spec で amend) |
| done 定義    | ① ホストリソース (CPU / RAM / Disk / Network) ダッシュボード 1 枚<br>② **サービス up (`up{job=~"gatus\|adguard"}`) が PromQL で引け、サービス別ダッシュボードに描画** (vaultwarden は upstream PR マージ後に個別対応、M2 spec で amend)<br>③ サービス別ログ検索ビュー 1 枚<br>④ ダッシュボード JSON が provisioning で復元可能                                       |
| PR           | 1 本 (`feat/obs/m2-dashboards`)                                                                                                                                                                                                                                                                                                                                      |
| out of scope | アラート定義 / cadvisor 等の新規 exporter 追加判断                                                                                                                                                                                                                                                                                                                   |

### M3: リモートホスト Alloy (手書きモード) + LiRu / WSL2 適用

| 項目         | 内容                                                                                                                                                                                                                                                                                            |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| scope        | 非 NixOS ホストに [手書きモード](../../design-docs/patterns/quadlet-conventions.md) (`.container.tmpl` + gomplate + systemd user unit) で Alloy を配置し Tailnet 経由で OCI の VL/VM へ push。最初の適用対象は **LiRu (Manjaro)**。WSL2 (ollama ホスト) は同 M 内で 2 番目の適用                |
| done 定義    | ① LiRu のホストメトリクスが VictoriaMetrics に到達 (host label で識別)<br>② LiRu の journald ログが VictoriaLogs に到達<br>③ WSL2 Alloy も同パターンで稼働、スリープ復帰後に push 再開<br>④ OCI 側 Alloy (Nix モード) とリモート側 Alloy (手書きモード) で scrape / push 設定の構造が揃っている |
| PR           | 1 本 (`feat/obs/m3-remote-alloy`、LiRu + WSL2 を同 PR に含める)                                                                                                                                                                                                                                 |
| out of scope | WSL2 側固有の追加 exporter / NVIDIA GPU メトリクス (必要なら別 spec)                                                                                                                                                                                                                            |

### M5: vmalert + 通知経路

| 項目         | 内容                                                                                                                                                                                                                             |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| scope        | vmalert の quadlet-nix 化 + 初期アラートルール + 通知 sink 実装                                                                                                                                                                  |
| done 定義    | ① vmalert が VM に接続しルール評価が回っている<br>② 初期ルール (最低: サービス up / ディスク使用率 / OOM) が定義されている<br>③ 通知 sink が実装され、意図的にトリガして Telegram 到達を確認<br>④ Gatus との二重通知ポリシー明記 |
| PR           | 1 本 (`feat/obs/m5-vmalert`)                                                                                                                                                                                                     |
| out of scope | ルールの網羅的整備 (後続で個別 PR)                                                                                                                                                                                               |

### 依存関係

```
M1 (foundation)
 ├── M4 (fluent-bit 撤去)        ← ro mount 追加は M1 で Alloy に仕込んでおく
 ├── M2 (dashboards)             ← M4 後の方が adguard のログ可視化が楽
 ├── M3 (remote Alloy)           ← 独立だが M1 の push endpoint が前提
 └── M5 (vmalert)                ← M2 のダッシュボード定義と query を共有
```

`M4 と M2 は M1 完了後なら内容独立性が高く並行可`。直列順序はレビュー負荷を分散するためのデフォルト。

---

## 決定ロック

既存 docs spec + ADR-010 / 011 の未解決事項を、どの M spec で決着させるか固定する。

| #   | 未解決事項                                                                       | 決着 M spec | 備考                                                                                                   |
| --- | -------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------ |
| 1   | VL 保持期間 / ディスク予算 (OCI 100GB 内配分)                                    | **M1**      | VL 立ち上げ時に初期値確定。後日調整可だが Phase 2 開始時点の数字を固定                                 |
| 2   | VM retention / ディスク予算 (同上)                                               | **M1**      | 同上                                                                                                   |
| 3   | VM backup 戦略 (vmbackup / ディスクスナップショット / 未採用)                    | **M1**      | homelab スケール。**推奨: OCI ブートボリュームスナップショット依存**                                   |
| 4   | リモート push 受信口の auth (Tailscale iface bind のみ / 追加 token / mTLS)      | **M1**      | 受信口を立てる M。**推奨: Tailscale iface bind のみ**                                                  |
| 5   | 初期 scrape 対象 exporter (cadvisor / node_exporter / サービス /metrics のみ)    | **M1→M2**   | M1 spec (2026-04-16) で決着: M1 はホスト node + Alloy self のみ。既存サービス /metrics は M2 で enable |
| 6   | Grafana 認証方式 (Tailscale Serve 前段 + ローカル admin / OIDC / 他)             | **M1**      | **推奨: Tailscale Serve 前段 + ローカル admin** (vaultwarden / adguard と同パターン)                   |
| 7   | M1 の初期 panel 1 本の内容 (ホスト稼働 / サービス一覧 / ログタイムライン 等)     | **M1**      | E2E 疎通検証用の最小 panel                                                                             |
| 8   | ダッシュボード資産 (自作 / Grafana.com テンプレ / VictoriaMetrics 公式流用)      | **M2**      | M2 本体の判断                                                                                          |
| 9   | Alloy 設定の共通化 (OCI / LiRu / WSL2 で設定構造をどう揃えるか)                  | **M3**      | M1 で雛形、M3 で共通化の形を確定                                                                       |
| 10  | K-013 watchdog と Alloy の統合 (Alloy 独自リトライで十分 / 既存 watchdog に追加) | **M3**      | WSL2 適用時に判断                                                                                      |
| 11  | ADR-006 supersede のタイミング (fluent-bit 撤去コミットで status 更新)           | **M4**      | 撤去コミットと同一 PR で ADR status を superseded に                                                   |
| 12  | vmalert 通知 sink (Alertmanager 経由 / webhook 直 Telegram)                      | **M5**      |                                                                                                        |
| 13  | Gatus と vmalert の二重通知ポリシー (同一障害が両経路で鳴るケース)               | **M5**      | 通知 sink 決定とセット                                                                                 |

「推奨」は roadmap が示唆するデフォルトで、各 M spec で覆すことは妨げない。

### ADR-011 の訂正

ADR-011 の「波及する未決事項」に `OCI 200 GB ブートボリューム内の配分` とあるが、実際は **100GB**。この訂正は M1 spec で retention 具体値を確定する際に、同一 PR 内で実施する。

---

## ブランチ戦略 / PR 運用

### ブランチ構造

```
main
 ▲ merge (Phase 2 完了時に一括)
 │
feat/obs/main  (remote only、ローカル worktree は作らない)
 ▲ merge (1 M = 1 PR)
 │
 ├── feat/obs/m1-foundation
 ├── feat/obs/m4-adguard-alloy-direct
 ├── feat/obs/m2-dashboards
 ├── feat/obs/m3-remote-alloy
 └── feat/obs/m5-vmalert
```

### 運用

- 各 M worktree は `origin/feat/obs/main` から分岐
- M PR target は `feat/obs/main`
- rebase: `git fetch && git rebase origin/feat/obs/main`
- Phase 2 完了時に `feat/obs/main` → `main` を一括 merge
- **OCI deploy は `feat/obs/main` から実施**。Phase 2 進行中、main と OCI 実稼働状態が乖離することを受容する

### Spec PR

- 本 roadmap spec は `docs/obs-roadmap` ブランチで **main 宛**に先行 merge
- 各 M spec も `docs/obs-m{n}-spec` ブランチで main 宛に先行 merge (実装 PR は spec merge 後に起票)

### M spec 作成のトリガ (直列デフォルト、並行妨げず)

| M spec  | タイミング                                |
| ------- | ----------------------------------------- |
| M1 spec | roadmap spec merge 直後                   |
| M4 spec | M1 実装 PR が `feat/obs/main` に merge 後 |
| M2 spec | M4 merge 後                               |
| M3 spec | M2 merge 後                               |
| M5 spec | M3 merge 後                               |

---

## Documentation-Code Coupling

AGENTS.md の規則に従い、各 M 実装 PR 内で以下 docs を同時更新する。

| M   | 更新対象                                                                                                                                                                                                                                                                                                               |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M1  | `AGENTS.md` (観測スタック行・services/ セクションに alloy / vl / vm / grafana 追記)<br>`docs/design-docs/patterns/log-strategy.md` (Phase 2 図を「現状」化)<br>`docs/design-docs/adr/011-*.md` (200GB → 100GB 訂正 + retention 決定値の追記)<br>新規 `services/{alloy,victorialogs,victoriametrics,grafana}/README.md` |
| M4  | `docs/design-docs/adr/006-*.md` (status: superseded + 補足)<br>`docs/design-docs/adr/008-*.md` (移行手順チェック済み化)<br>`services/adguard-home/README.md` (fluent-bit サイドカー記述を削除)                                                                                                                         |
| M2  | `docs/cheatsheet.md` (ダッシュボード URL / 主要 query)                                                                                                                                                                                                                                                                 |
| M3  | LiRu 用の配置先・手順ドキュメント (具体パス / ディレクトリ構成は M3 spec で決定。hosts/ は現状 NixOS 前提のため LiRu の置き場所は要検討)<br>`docs/design-docs/patterns/quadlet-conventions.md` (ollama 以外の手書きモード実例追加)                                                                                     |
| M5  | `AGENTS.md` (アラート行の更新)<br>`docs/knowledge.md` (二重通知の既知落とし穴)<br>新規 `services/vmalert/README.md`                                                                                                                                                                                                    |

---

## Phase 2 全体の完了定義

`feat/obs/main` → `main` へ merge する条件:

- M1〜M5 全実装 PR が `feat/obs/main` に merge 済み
- OCI 上で以下が稼働:
  - VictoriaLogs / VictoriaMetrics / Alloy / Grafana / vmalert
  - journald + AdGuard querylog + LiRu / WSL2 ログが VL に蓄積
  - 既存サービスの `/metrics` + LiRu / WSL2 のメトリクスが VM に蓄積
  - 1 枚以上のダッシュボードが Grafana で描画
  - 1 本以上の vmalert ルールが発火 → Telegram 到達を意図的にテスト済み
- fluent-bit サイドカーが全て撤去
- ADR-006 status が superseded
- AGENTS.md の技術スタック表 / サービス一覧が Phase 2 構成を反映

---

## out of scope (Phase 2 では扱わず、Phase 3 以降の候補)

- **trace** (OpenTelemetry Tempo / Jaeger 等): ログとメトリクスが揃った後に検討
- **長期保持用 object storage 階層化** (VL / VM の S3 退避): homelab スケールでは過剰
- **Alertmanager の高度な routing** (silence / inhibition の本格運用): まず vmalert 直送で運用、複雑化の兆候が出たら導入
- **cadvisor / node_exporter の包括追加**: 必要性が判明してから個別判断
- **Grafana の外部公開** (Tailnet 外からのアクセス): Tailscale Serve 内で運用
- **マルチテナント** (複数 user / project 分離): homelab 単独用途

---

## 前提 (spec 外で満たされていること)

- ADR-007 / 008 / 010 / 011 が main に merged (PR #10 で完了)
- ADR-009 (quadlet-nix 統一) が完了済み (既存 3 サービス移行済み)
- OCI NixOS 環境が稼働中
- LiRu (Manjaro) と WSL2 (ollama host) が Tailnet に参加済み
