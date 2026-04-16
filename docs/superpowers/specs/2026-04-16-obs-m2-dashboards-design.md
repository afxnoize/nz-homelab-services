# Observability M2 — 初期ダッシュボード整備 + サービスメトリクス scrape spec

## 概要

Phase 2 観測スタック実装ロードマップの **M2 マイルストン** 個別 spec。M1 で構築した Alloy / VictoriaMetrics / VictoriaLogs / Grafana 基盤の上に、既存サービス (gatus / adguard-home) の `/metrics` scrape を追加し、ホスト・サービス別のダッシュボードを整備する。

ロードマップ spec は M2 scope に `vaultwarden admin metrics` を含めていたが、調査の結果 vaultwarden の Prometheus メトリクス対応は [PR #6202](https://github.com/dani-garcia/vaultwarden/pull/6202) が未マージであり、stable リリースでは `/metrics` エンドポイントが存在しない。M2 では **vaultwarden のメトリクス scrape を scope 外とし**、gatus と adguard-home の 2 サービスに絞る。vaultwarden メトリクスは upstream PR マージ後に個別 PR で対応する。本 spec PR 内でロードマップ spec の M2 scope を amend する。

### 上流ドキュメント

- [ロードマップ spec](./2026-04-15-observability-implementation-roadmap.md) — M2 の scope / done 定義 / 決定ロック #8 を規定
- [M1 spec](./2026-04-16-obs-m1-foundation-design.md) — 基盤アーキテクチャ・Alloy 設定・provisioning 基盤
- [ADR-008 Alloy 統一コレクタ](../../design-docs/adr/008-alloy-unified-collector.md)
- [パターン: Quadlet 構成規約](../../design-docs/patterns/quadlet-conventions.md)
- [パターン: Tailscale サイドカー](../../design-docs/patterns/tailscale-sidecar.md)

### スコープ

**in scope**:

- gatus の Prometheus メトリクス有効化 (`metrics: true`) + Alloy scrape 設定追加
- adguard-exporter サイドカー追加 (AdGuard Home API 経由の Prometheus exporter) + Alloy scrape 設定追加
- TS サイドカー共有 namespace から Alloy (host network) へのメトリクスポート公開 (`publishPorts`)
- ホストリソースダッシュボード 1 枚 (M1 の homelab-overview Host resources panel を独立ダッシュボードに拡張)
- サービス別ログ検索ビュー 1 枚 (VictoriaLogs LogsQL、service label フィルタ)
- サービスメトリクスダッシュボード 1 枚 (gatus + adguard-home の up / 主要メトリクス)
- ダッシュボード JSON の provisioning 管理 (git 管理、file-based provider)
- homelab-overview の Scrape targets up panel が新 job を自動反映することの確認
- ロードマップ spec M2 scope の amend (vaultwarden メトリクス除外)
- `docs/cheatsheet.md` にダッシュボード URL / 主要 query 追記

**out of scope**:

- **vaultwarden メトリクス scrape** — upstream PR #6202 未マージ。stable リリースで `/metrics` が利用可能になった時点で個別 PR で対応
- cadvisor / 追加 exporter の導入判断
- アラート定義 (M5 scope)
- ダッシュボードの Grafana.com テンプレート流用判断 (自作で十分な規模)
- M4 scope (fluent-bit 撤去)

---

## 決定ロック (M2)

ロードマップ spec の決定ロック表 #8 を本 spec で確定する。

| #   | 項目                     | 決定値                                                                                                                                  |
| --- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| 8   | ダッシュボード資産の方針 | **自作 JSON**。Grafana.com テンプレートは homelab の独自構成 (VL + VM + Alloy unix exporter) に合わないため採用しない。JSON を git 管理 |

### 追加決定

| 項目                                | 決定値                                                                                                                    |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| TS namespace 内メトリクスの公開方法 | **TS sidecar の `publishPorts` で `127.0.0.1:<host-port>:<container-port>` をホストに公開**。Alloy は localhost で scrape |
| AdGuard Home exporter               | **`ebrianne/adguard-exporter`** (Docker Hub 公開、軽量、主要メトリクス網羅)                                               |
| vaultwarden メトリクス              | **M2 scope 外**。upstream PR #6202 マージ待ち                                                                             |
| ダッシュボード枚数                  | **3 枚** (host-resources / service-metrics / service-logs) + 既存 homelab-overview 維持                                   |
| ダッシュボード UID 命名規則         | `<slug>` 形式 (例: `host-resources`, `service-metrics`, `service-logs`)                                                   |

---

## アーキテクチャ

### M2 で追加される経路

```
┌────────────────── OCI NixOS host (oci-nix) ──────────────────┐
│                                                              │
│  ┌─── gatus-ts namespace ─────────────────────────────┐      │
│  │  gatus (:8080/metrics)                             │      │
│  │  gatus-ts (TS sidecar, publishPorts 127.0.0.1:8180:8080) │
│  └────────────────────────────────────────────────────┘      │
│       │ 127.0.0.1:8180                                       │
│       ▼                                                      │
│  ┌─── adguard-home-ts namespace ──────────────────────┐      │
│  │  adguard-home (:3000 UI)                           │      │
│  │  adguard-exporter (:9617/metrics, API→:3000)       │      │
│  │  adguard-home-ts (TS, publishPorts 127.0.0.1:9617:9617)  │
│  └────────────────────────────────────────────────────┘      │
│       │ 127.0.0.1:9617                                       │
│       ▼                                                      │
│   ┌────────────────────────────────────────────────────┐     │
│   │ Alloy (network_mode=host)                          │     │
│   │  ├ (M1) loki.source.journal                        │     │
│   │  ├ (M1) prometheus.exporter.unix                   │     │
│   │  ├ (M1) prometheus.scrape "node"                   │     │
│   │  ├ (M1) prometheus.scrape "alloy"                  │     │
│   │  ├ (M2) prometheus.scrape "gatus"   → :8180       │     │
│   │  ├ (M2) prometheus.scrape "adguard" → :9617       │     │
│   │  ├ loki.write            → VL                      │     │
│   │  └ prometheus.remote_write → VM                    │     │
│   └────────────────────────────────────────────────────┘     │
│                                                              │
│   VictoriaLogs (:9428)   VictoriaMetrics (:8428)             │
│                                                              │
│   Grafana (container:grafana-ts)                             │
│     provisioning/dashboards/                                 │
│       ├ homelab-overview.json   (M1, 維持)                   │
│       ├ host-resources.json     (M2, 新規)                   │
│       ├ service-metrics.json    (M2, 新規)                   │
│       └ service-logs.json       (M2, 新規)                   │
└──────────────────────────────────────────────────────────────┘
```

### データフロー (M2 追加分)

| 種別                    | 経路                                                                                                                                                     |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| gatus メトリクス        | gatus (:8080/metrics) → gatus-ts publishPorts → host 127.0.0.1:8180 → Alloy (prometheus.scrape "gatus") → VM (remote_write)                              |
| adguard-home メトリクス | adguard-exporter (API→adguard-home:3000 → :9617/metrics) → adguard-home-ts publishPorts → host 127.0.0.1:9617 → Alloy (prometheus.scrape "adguard") → VM |

### ポートマッピング一覧 (M2 完了時点)

| サービス     | コンテナポート | ホスト公開      | Alloy job 名 | 備考                        |
| ------------ | -------------- | --------------- | ------------ | --------------------------- |
| node         | (Alloy 内蔵)   | -               | `node`       | M1 で設定済み               |
| alloy        | 12345          | 127.0.0.1:12345 | `alloy`      | M1 で設定済み               |
| gatus        | 8080           | 127.0.0.1:8180  | `gatus`      | TS sidecar publishPorts     |
| adguard-home | 9617           | 127.0.0.1:9617  | `adguard`    | exporter sidecar 経由       |
| vaultwarden  | -              | -               | -            | M2 scope 外 (upstream 待ち) |

---

## 実装詳細

### 1. gatus メトリクス有効化

`services/gatus/nixos.nix` を変更:

**gatus 設定に `metrics: true` 追加**:

```nix
sops.templates."gatus-config.yaml".content = builtins.toJSON {
  # ... 既存設定 ...
  metrics = true;  # ← 追加
};
```

これにより gatus は `:8080/metrics` で Prometheus メトリクスを公開する (Web UI と同一ポート)。

**gatus-ts に publishPorts 追加**:

```nix
gatus-ts = {
  containerConfig = {
    # ... 既存設定 ...
    publishPorts = [
      "127.0.0.1:8180:8080"  # gatus metrics → host localhost
    ];
  };
};
```

ポート `8180` は gatus の `8080` と区別するためオフセット。Alloy からは `127.0.0.1:8180/metrics` で到達する。

### 2. adguard-exporter サイドカー追加

`services/adguard-home/nixos.nix` に `adguard-exporter` コンテナを追加:

```nix
adguard-exporter = {
  autoStart = true;
  containerConfig = {
    image = "docker.io/ebrianne/adguard-exporter:latest";
    networks = [ "container:adguard-home-ts" ];
    environments = {
      ADGUARD_PROTOCOL = "http";
      ADGUARD_HOSTNAME = "127.0.0.1";
      ADGUARD_PORT = "3000";
      ADGUARD_USERNAME = "";
      ADGUARD_PASSWORD = "";
      SERVER_PORT = "9617";
      INTERVAL = "30s";
    };
    logDriver = "journald";
  };
  unitConfig = {
    Requires = [ "adguard-home.service" ];
    After = [ "adguard-home.service" ];
  };
  serviceConfig.Restart = "always";
};
```

`container:adguard-home-ts` で namespace を共有するため、`127.0.0.1:3000` で AdGuard Home の API に到達できる。exporter は `:9617/metrics` で Prometheus メトリクスを公開する。

K-012 のとおり AdGuard Home は `users: []` (認証なし) で運用しているため、exporter の `ADGUARD_USERNAME` / `ADGUARD_PASSWORD` は空で動作する。

**adguard-home-ts に publishPorts 追加**:

```nix
adguard-home-ts = {
  containerConfig = {
    # ... 既存設定 ...
    publishPorts = [
      "127.0.0.1:9617:9617"  # adguard-exporter metrics → host localhost
    ];
  };
};
```

### 3. Alloy scrape 設定追加

`services/observability/alloy/config.alloy` に M2 の scrape job を追加:

```alloy
// --- metrics: gatus (M2) ---
prometheus.scrape "gatus" {
  targets    = [{ __address__ = "127.0.0.1:8180" }]
  forward_to = [prometheus.remote_write.vm.receiver]
  job_name   = "gatus"
  metrics_path = "/metrics"
}

// --- metrics: adguard-home (M2) ---
prometheus.scrape "adguard" {
  targets    = [{ __address__ = "127.0.0.1:9617" }]
  forward_to = [prometheus.remote_write.vm.receiver]
  job_name   = "adguard"
  metrics_path = "/metrics"
}
```

### 4. ダッシュボード

#### 4a. host-resources.json (新規)

M1 の homelab-overview にあった Host resources panel を独立ダッシュボードとして拡張。

| Panel          | 種別               | Query                                                                                                                      |
| -------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| CPU Usage      | time series        | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`                                          |
| Memory Usage   | time series        | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100`                                                  |
| Disk Usage     | gauge              | `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100`                     |
| Disk Available | stat               | `node_filesystem_avail_bytes{mountpoint="/"}`                                                                              |
| Network I/O    | time series (2 行) | `rate(node_network_receive_bytes_total{device="eth0"}[5m])` / `rate(node_network_transmit_bytes_total{device="eth0"}[5m])` |
| System Uptime  | stat               | `time() - node_boot_time_seconds`                                                                                          |
| Load Average   | time series        | `node_load1` / `node_load5` / `node_load15`                                                                                |

device フィルタに `{device="eth0"}` を指定し、M1 で未解決だった「Net RX が全 IF 表示」問題を修正する。

#### 4b. service-metrics.json (新規)

gatus + adguard-home のメトリクスを集約。

| Panel                         | 種別               | Query                                           |
| ----------------------------- | ------------------ | ----------------------------------------------- |
| Service Up/Down               | stat (color-coded) | `up{job=~"gatus\|adguard"}`                     |
| Gatus — Endpoint Success Rate | time series        | `rate(gatus_results_total{success="true"}[5m])` |
| Gatus — Endpoint Duration     | time series        | `gatus_results_duration_seconds`                |
| AdGuard — DNS Queries Total   | stat               | `adguard_dns_queries`                           |
| AdGuard — DNS Blocked         | time series        | `rate(adguard_blocked_filtering[5m])`           |
| AdGuard — Avg Processing Time | time series        | `adguard_avg_processing_time`                   |
| AdGuard — Query Types         | pie chart          | `adguard_query_types`                           |

具体的なメトリクス名は adguard-exporter / gatus の実際の出力を確認して実装時に調整する。上表は設計ターゲット。

#### 4c. service-logs.json (新規)

VictoriaLogs の LogsQL を使ったサービス別ログ検索ビュー。

| Panel                 | 種別               | Query                                                             |
| --------------------- | ------------------ | ----------------------------------------------------------------- |
| Log Stream            | logs               | `service:$service` (変数 `service` でフィルタ)                    |
| Log Volume by Service | time series (area) | `* \| stats by (service) count() as logs` (statsRange)            |
| Error / Warning count | stat               | `service:$service AND (_msg:error OR _msg:warn) \| stats count()` |

テンプレート変数 `service` を定義し、ドロップダウンでサービスを切り替えられるようにする。値は VictoriaLogs の `service` label から動的取得。

#### 4d. homelab-overview.json (既存維持)

M1 の 3 panel をそのまま維持。M2 で追加される gatus / adguard の job は `Scrape targets up` panel の `up` クエリに自動的に行が追加される。変更不要。

### ダッシュボード provisioning 構成 (M2 完了時)

```
grafana/provisioning/dashboards/
├── dashboards.yaml           # provider config (M1 から変更なし)
├── homelab-overview.json     # M1
├── host-resources.json       # M2
├── service-metrics.json      # M2
└── service-logs.json         # M2
```

---

## リポジトリ構成変更

M2 で変更・追加されるファイル:

```
services/
├── gatus/
│   └── nixos.nix              # metrics: true 追加、gatus-ts publishPorts 追加
├── adguard-home/
│   └── nixos.nix              # adguard-exporter コンテナ追加、adguard-home-ts publishPorts 追加
└── observability/
    ├── alloy/
    │   └── config.alloy       # gatus / adguard scrape job 追加
    └── grafana/
        └── provisioning/
            └── dashboards/
                ├── host-resources.json    # 新規
                ├── service-metrics.json   # 新規
                └── service-logs.json      # 新規
docs/
├── cheatsheet.md              # ダッシュボード URL / 主要 query 追記
└── superpowers/specs/
    └── 2026-04-15-observability-implementation-roadmap.md  # M2 scope amend
```

---

## TS サイドカー publishPorts の設計判断

### 背景

M1 の既存サービス (vaultwarden / gatus / adguard-home) は Tailscale サイドカーと `container:<service>-ts` で network namespace を共有している。Alloy は `network_mode=host` で動作するため、サイドカー namespace 内のポートに直接到達できない。

### 選択肢

| 方法                                          | 複雑さ | 変更範囲                    | 備考                                                                  |
| --------------------------------------------- | ------ | --------------------------- | --------------------------------------------------------------------- |
| **A. TS sidecar に publishPorts 追加** (採用) | 低     | TS sidecar の quadlet のみ  | `127.0.0.1` bind でホストからのみ到達。既存ネットワーク構成を変えない |
| B. 別途 bridge network を追加                 | 中     | サービスとAlloyの両方に変更 | dual-homed 構成が複雑化                                               |
| C. Alloy を各 namespace に参加                | 中     | Alloy の network 設定       | Alloy が複数 namespace に入る必要があり `network_mode=host` と非互換  |

方式 A を採用。`127.0.0.1` bind により公衆 IF からは到達不能。TS sidecar の `publishPorts` で namespace 内のポートをホスト localhost に公開し、Alloy が localhost 経由で scrape する。

### publishPorts と TS_USERSPACE の互換性

TS sidecar は `TS_USERSPACE=true` で動作しているため、コンテナのデフォルトネットワーク (pasta) が生きている。`publishPorts` は pasta 経由で機能し、TS のユーザースペース TUN と干渉しない。

---

## ロードマップ amend

本 spec PR 内でロードマップ spec に以下の変更を加える:

### M2 scope の amend

```diff
 ### M2: 初期ダッシュボード整備

 | 項目         | 内容 |
 | ------------ | ---- |
-| scope        | **既存サービスの `/metrics` 有効化** (vaultwarden admin metrics、gatus の publishPort 経由公開、adguard-exporter サイドカー追加) + Alloy 設定への scrape 追加。
+| scope        | **既存サービスの `/metrics` 有効化** (gatus の publishPort 経由公開、adguard-exporter サイドカー追加) + Alloy 設定への scrape 追加。vaultwarden は upstream PR #6202 未マージのため M2 scope 外。
```

### M2 done 定義の amend

```diff
-| done 定義    | ② **サービス up (`up{job=~"vaultwarden\|gatus\|adguard-home"}`) が PromQL で引け、サービス別ダッシュボードに描画**
+| done 定義    | ② **サービス up (`up{job=~"gatus\|adguard"}`) が PromQL で引け、サービス別ダッシュボードに描画** (vaultwarden は upstream PR マージ後に個別対応)
```

---

## デプロイ / 検証手順

### ブランチ / PR

- spec PR: `docs/obs-m2-spec` → `feat/obs/main` (本 spec)
- 実装 PR: `feat/obs/m2-dashboards` → `feat/obs/main`

### 実装順序 (単一 PR 内のコミット分割案)

1. `feat(gatus): metrics: true 追加 + gatus-ts publishPorts`
2. `feat(adguard-home): adguard-exporter サイドカー追加 + adguard-home-ts publishPorts`
3. `feat(observability): Alloy config に gatus / adguard scrape job 追加`
4. `feat(observability): host-resources ダッシュボード追加`
5. `feat(observability): service-metrics ダッシュボード追加`
6. `feat(observability): service-logs ダッシュボード追加`
7. `docs: cheatsheet.md にダッシュボード URL / 主要 query 追記`
8. `docs(spec): roadmap M2 scope amend (vaultwarden メトリクス除外)`

### 検証 (OCI 上、`just oci-deploy` 完了後)

```bash
# 1. 新規ユニット確認
just oci-status | grep -E 'adguard-exporter'

# 2. gatus メトリクス到達
just oci-ssh 'curl -s http://127.0.0.1:8180/metrics | head -10'

# 3. adguard-exporter メトリクス到達
just oci-ssh 'curl -s http://127.0.0.1:9617/metrics | head -10'

# 4. VM に新 job が登録
just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode "query=up" | jq ".data.result | length"'
# 期待値: 4 (node + alloy + gatus + adguard)

# 5. Grafana UI
# ブラウザで各ダッシュボードを確認:
#   - host-resources: CPU/RAM/Disk/Network/Uptime/Load が描画
#   - service-metrics: gatus + adguard の up + 主要メトリクス
#   - service-logs: service ドロップダウンでフィルタ可能
#   - homelab-overview: Scrape targets up に 4 行表示

# 6. publishPorts が localhost のみ
just oci-ssh 'ss -tlnp | grep -E "8180|9617"'
# 127.0.0.1 bind であること確認
```

### ロールバック

`just oci-rollback` で前世代に戻る。gatus / adguard-home-ts の publishPorts、adguard-exporter、Alloy config、ダッシュボード JSON が全て巻き戻る。

---

## Documentation-Code Coupling

| ファイル                                                                    | 更新内容                                                    |
| --------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `docs/cheatsheet.md`                                                        | ダッシュボード URL 4 枚分 + 主要 PromQL / LogsQL query 追記 |
| `docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md` | M2 scope / done 定義 amend (vaultwarden メトリクス除外)     |
| `services/gatus/README.md`                                                  | metrics 有効化の記載追加                                    |
| `services/adguard-home/README.md`                                           | adguard-exporter サイドカーの記載追加                       |

---

## Done 定義

- [ ] gatus のメトリクスが VictoriaMetrics に到達 (`up{job="gatus"} == 1` が Grafana で確認可能)
- [ ] adguard-exporter のメトリクスが VictoriaMetrics に到達 (`up{job="adguard"} == 1` が Grafana で確認可能)
- [ ] `host-resources` ダッシュボードに CPU / RAM / Disk / Network / Uptime / Load が描画
- [ ] `service-metrics` ダッシュボードに gatus / adguard-home の主要メトリクスが描画
- [ ] `service-logs` ダッシュボードで service 変数によるフィルタが機能
- [ ] ダッシュボード JSON 4 枚が provisioning で復元可能 (Grafana コンテナ再作成後に自動ロード)
- [ ] homelab-overview の Scrape targets up に 4 行 (node / alloy / gatus / adguard) 表示
- [ ] publishPorts が `127.0.0.1` bind のみ (公衆 IF から到達不能)
- [ ] ロードマップ spec の M2 scope / done 定義が amend 済み
- [ ] `docs/cheatsheet.md` にダッシュボード URL / 主要 query 追記済み

---

## リスク / 未決事項 (M2 実装中に確認すべき点)

| 項目                                                    | 対応                                                                                                                                                    |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| gatus のメトリクス名が想定と異なる可能性                | 実装時に `curl http://127.0.0.1:8180/metrics` の出力を確認し、ダッシュボード query を調整。gatus v5 のメトリクス名は `gatus_results_*` の想定だが要確認 |
| adguard-exporter のメトリクス名が想定と異なる可能性     | 同上。`ebrianne/adguard-exporter` の出力を確認。`adguard_*` プレフィックスの想定                                                                        |
| TS sidecar publishPorts 追加時の再起動影響              | gatus-ts / adguard-home-ts の再起動が必要。短時間のダウンタイム発生。deploy 時に依存コンテナも順次再起動される                                          |
| adguard-exporter の認証なし動作                         | K-012 のとおり AdGuard Home は `users: []` で運用。exporter の `ADGUARD_USERNAME` / `ADGUARD_PASSWORD` が空で API アクセスできることを確認              |
| service-logs ダッシュボードのテンプレート変数の VL 対応 | VictoriaLogs datasource plugin でテンプレート変数の動的取得がサポートされているか実装時確認。未対応なら static list で service 一覧を定義               |
| Net RX/TX の device フィルタ値                          | M1 で未解決だった全 IF 表示問題を修正。OCI の主要 IF 名を確認 (`eth0` / `ens3` 等)。`just oci-ssh 'ip link show'` で実機確認                            |

---

## 前提 (spec 外で満たされていること)

- M1 実装 PR が `feat/obs/main` に merge 済み
- VictoriaLogs / VictoriaMetrics / Alloy / Grafana が OCI 上で稼働中
- gatus / adguard-home が OCI 上で稼働中
- Alloy の `config.alloy` が provisioning 経由でマウントされている (M1 で設定済み)
- Grafana の provisioning/dashboards が file-based provider で設定済み (M1 で設定済み)

---

## Phase 2 内での位置付け

M2 完了後の依存:

- **M3** (リモート Alloy): M2 で確立した scrape パターン (publishPorts + Alloy localhost scrape) を LiRu / WSL2 に応用。ただし M3 のリモート Alloy はホストの journald + node メトリクスが主スコープであり、M2 の scrape 設定とは直接の依存なし
- **M5** (vmalert): M2 のダッシュボード query を vmalert ルールの PromQL に流用可能 (例: `up == 0` でアラート)
- **vaultwarden メトリクス**: M2 scope 外だが、M2 で確立した publishPorts パターンをそのまま適用可能。upstream PR マージ後に `vaultwarden-ts` に publishPorts + Alloy scrape job を追加する個別 PR で対応
