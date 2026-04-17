# Observability M4 — AdGuard Home fluent-bit サイドカー撤去 spec

## 概要

Phase 2 観測スタック実装ロードマップの **M4 マイルストン** 個別 spec。M1 で Alloy コンテナに ro マウント済みの `adguard-home-data` volume を活用し、`config.alloy` のコメントアウトされた `loki.source.file` ブロックを有効化する。同時に fluent-bit サイドカー (`adguard-home-querylog`) の Quadlet 定義・設定を撤去する。

ADR-006 (fluent-bit サイドカー) は既に ADR-008 (Alloy 一元化) により `superseded` としてマークされている。M4 はこの ADR の実装側を完了させるマイルストン。

### 上流ドキュメント

- [ロードマップ spec](./2026-04-15-observability-implementation-roadmap.md) — M4 の scope / done 定義
- [M1 spec](./2026-04-16-obs-m1-foundation-design.md) — Alloy の adguard-home-data ro マウント設計
- [ADR-006 fluent-bit サイドカー](../../design-docs/adr/006-adguard-querylog-fluent-bit-sidecar.md) (status: superseded)
- [ADR-008 Alloy 統一コレクタ](../../design-docs/adr/008-alloy-unified-collector.md) — 移行手順の概略

### スコープ

**in scope**:

- `config.alloy` の `loki.source.file "adguard_querylog"` ブロックのコメント解除・有効化
- `services/adguard-home/nixos.nix` から `adguard-home-querylog` コンテナ定義 (fluent-bit) の削除
- `services/adguard-home/nixos.nix` から fluent-bit 関連の `let` バインディング (`fluentBitConf`, `parsersConf`) の削除
- K-007 (tail 位置永続化 + querylog 保持期間短縮) が Alloy 経路で等価以上に維持されることの検証
- `services/adguard-home/README.md` から fluent-bit サイドカー記述の削除
- ADR-008 の移行手順チェック済み化

**out of scope**:

- ADR-006 の status 変更 (既に `superseded` に更新済み)
- 他サービスのファイルログ移行 (現状 AdGuard のみがファイルログを持つ)
- Alloy の config.alloy 以外の変更 (M2 の scrape 追加は M2 scope)

---

## アーキテクチャ

### Before (M1 完了時点)

```
adguard-home → querylog.json ─┐
                               │ adguard-home-data volume
adguard-home-querylog (fluent-bit) ──┘→ tail → stdout → journald

Alloy → adguard-home-data:/var/log/adguard:ro (マウント済み、loki.source.file はコメントアウト)
```

### After (M4 完了時点)

```
adguard-home → querylog.json ─┐
                               │ adguard-home-data volume (ro)
Alloy (loki.source.file) ─────┘→ VictoriaLogs

fluent-bit サイドカー: 削除済み
```

### データフロー変更

| 種別             | Before (M1)                                                                  | After (M4)                                    |
| ---------------- | ---------------------------------------------------------------------------- | --------------------------------------------- |
| AdGuard querylog | querylog.json → fluent-bit → stdout → journald → Alloy (journal source) → VL | querylog.json → Alloy (loki.source.file) → VL |
| AdGuard stdout   | container stdout → journald → Alloy (journal source) → VL                    | 変更なし                                      |

ログ経路が 2 ホップから 1 ホップに短縮される (ADR-008 の想定通り)。

---

## 実装詳細

### 1. config.alloy — loki.source.file 有効化

`services/observability/alloy/config.alloy` のコメントアウトされたブロックを有効化:

```alloy
// --- AdGuard querylog (M4 activation) ---
loki.source.file "adguard_querylog" {
  targets    = [{ __path__ = "/var/log/adguard/querylog.json", service = "adguard-home", host = "oci-nix" }]
  forward_to = [loki.write.vl.receiver]
}
```

ラベル:

- `service = "adguard-home"`: journald 経由の AdGuard ログと同じ service label を使い、Grafana 上で統一的にフィルタ可能にする
- `host = "oci-nix"`: journald source と同じ host label

### Alloy の tail 位置永続化

M1 で Alloy コンテナに `alloy-data:/var/lib/alloy` をマウント済み。`loki.source.file` はデフォルトで `/var/lib/alloy/` 配下に positions ファイルを作成するため、tail 位置は自動的に永続化される。これは K-007 で fluent-bit 側に `DB /state/tail-pos.db` を設定していたのと等価。

### 2. adguard-home-querylog コンテナ削除

`services/adguard-home/nixos.nix` から以下を削除:

- `let` ブロックの `fluentBitConf` バインディング
- `let` ブロックの `parsersConf` バインディング
- `virtualisation.quadlet.containers.adguard-home-querylog` 定義全体

削除後の `adguard-home/nixos.nix` は `adguard-home-ts` + `adguard-home` の 2 コンテナのみになる (M2 で `adguard-exporter` が追加される場合は 3 コンテナ)。

### 3. adguard-home-querylog-state volume の扱い

fluent-bit の tail 位置を保持していた `adguard-home-querylog-state` volume は、Quadlet 定義削除後も OCI ホスト上に残る。不要なため M4 デプロイ後に手動で削除する:

```bash
just oci-ssh 'podman volume rm adguard-home-querylog-state'
```

---

## K-007 等価性の検証

K-007 は fluent-bit の tail 位置永続化と querylog 保持期間短縮を扱う。M4 での等価性:

| K-007 の要件                | fluent-bit 時代                           | Alloy 経路 (M4)                                           |
| --------------------------- | ----------------------------------------- | --------------------------------------------------------- |
| tail 位置永続化             | `DB /state/tail-pos.db` (named volume)    | `alloy-data:/var/lib/alloy` に positions ファイル自動保存 |
| 再起動時のログ欠損回避      | DB ファイルで位置追従                     | positions ファイルで位置追従 (等価)                       |
| querylog 保持期間短縮 (24h) | `AdGuardHome.yaml` の `querylog.interval` | 変更なし。AdGuard 側の設定はそのまま維持                  |

Alloy の `loki.source.file` は inotify/polling で新規行を追跡し、positions ファイルに読み取りオフセットを永続化する。fluent-bit の `tail` input と同等の機能を提供する。

---

## デプロイ / 検証手順

### ブランチ / PR

- spec PR: `docs/obs-m4-spec` → `feat/obs/main` (本 spec)
- 実装 PR: `feat/obs/m4-adguard-alloy-direct` → `feat/obs/main`

### 実装順序 (単一 PR 内のコミット分割案)

1. `feat(observability): Alloy config.alloy で adguard querylog file source を有効化`
2. `feat(adguard-home): fluent-bit サイドカー (adguard-home-querylog) を削除`
3. `docs: adguard-home README から fluent-bit 記述を削除`

### 検証 (OCI 上、`just oci-deploy` 完了後)

```bash
# 1. fluent-bit ユニットが消えている
just oci-ssh 'systemctl list-units --type=service | grep querylog'
# 期待: 出力なし

# 2. Alloy が querylog を読んでいる
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode "query=service:adguard-home AND _stream:{} _time:10m" | head -5'
# 期待: querylog 由来のログが VL に到達

# 3. Alloy の positions ファイルに adguard が記録されている
just oci-ssh 'podman exec alloy cat /var/lib/alloy/loki.source.file.adguard_querylog/positions.yml 2>/dev/null || echo "positions file not found"'

# 4. 既存ユニット (3 台 + 観測 5 台) が正常
just oci-status

# 5. Grafana の Log volume by service に adguard-home が表示
# ブラウザで homelab-overview → Log volume panel 確認
```

### ロールバック

`just oci-rollback` で前世代に戻る。fluent-bit サイドカーが復活し、Alloy の `loki.source.file` がコメントアウトに戻る。

---

## Documentation-Code Coupling

| ファイル                                              | 更新内容                                                           |
| ----------------------------------------------------- | ------------------------------------------------------------------ |
| `services/adguard-home/README.md`                     | fluent-bit サイドカー記述を削除、Alloy 直読みの記述に更新          |
| `docs/design-docs/adr/008-alloy-unified-collector.md` | 移行手順の「3. fluent-bit サイドカー撤去」にチェック済みの旨を追記 |

ADR-006 は M1 時点で既に `superseded` に更新済みのため、M4 での追加変更は不要。

---

## Done 定義

- [ ] `querylog.json` の内容が VictoriaLogs に到達 (service label = `adguard-home`)
- [ ] fluent-bit ユニット (`adguard-home-querylog.service`) が停止・削除されている
- [ ] K-007 (tail 位置永続化) が Alloy の positions ファイルで等価以上に維持
- [ ] `adguard-home-querylog-state` volume が削除済み (手動)
- [ ] `services/adguard-home/README.md` から fluent-bit 記述が削除済み
- [ ] ADR-008 の移行手順にチェック済みの旨を追記済み

---

## リスク / 未決事項 (M4 実装中に確認すべき点)

| 項目                                                 | 対応                                                                                                                                                                                                                                                   |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Alloy の `loki.source.file` が JSON パーサーを持つか | `loki.source.file` はデフォルトで行単位の生テキスト送信。JSON パースが必要な場合は `loki.process` stage を挟む。fluent-bit 時代は JSON パーサーを使っていたが、VL 側で LogsQL で JSON フィールド抽出が可能なため、Alloy 側のパースは不要の可能性が高い |
| querylog.json のローテーション時の挙動               | AdGuard Home は `querylog.json` をローテートする際にファイルを rename する。Alloy の `loki.source.file` は inotify でファイル追跡するが、rename 後の新ファイル作成を検知できるか実装時確認                                                             |
| M2 との並行実装時のコンフリクト                      | M2 が `adguard-home/nixos.nix` に `adguard-exporter` を追加し、M4 が同ファイルから fluent-bit を削除する。実施順序 (M4 → M2) に従えばコンフリクトは発生しない。並行実装する場合は rebase で解決                                                        |

---

## 前提 (spec 外で満たされていること)

- M1 実装 PR が `feat/obs/main` に merge 済み
- Alloy コンテナに `adguard-home-data:/var/log/adguard:ro` がマウント済み (M1 で設定)
- Alloy コンテナに `alloy-data:/var/lib/alloy` がマウント済み (M1 で設定、positions 永続化)
- `config.alloy` に `loki.source.file "adguard_querylog"` ブロックがコメントアウトで存在 (M1 で仕込み済み)
- ADR-006 の status が `superseded` に更新済み (M1 で実施済み)

---

## Phase 2 内での位置付け

M4 はロードマップの実施順序で M1 直後に位置する。fluent-bit サイドカーという「技術的負債」の解消であり、M2 (ダッシュボード整備) の前に片付けることで、M2 の adguard-home ログ可視化が Alloy 直読み経路で統一される。

M4 完了後:

- OCI 上のコンテナ数が 1 減少 (fluent-bit 撤去)
- AdGuard querylog は Alloy → VL の 1 ホップ経路に集約
- M2 でのダッシュボード整備時に、querylog のログも VL の service label で一貫してフィルタ可能
