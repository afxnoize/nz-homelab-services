# Observability M2 — 初期ダッシュボード整備 + サービスメトリクス scrape 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M1 で構築した Alloy / VictoriaMetrics / VictoriaLogs / Grafana 基盤の上に、gatus と adguard-home の `/metrics` を Alloy 経由で VM に scrape し、ホストリソース・サービスメトリクス・サービスログ用のダッシュボード 3 枚を Grafana に provisioning する。

**Architecture:** TS サイドカー namespace 内の `/metrics` は `containerConfig.publishPorts = ["127.0.0.1:<host>:<container>"]` でホスト localhost に公開し、`network_mode=host` で動作する Alloy が localhost 経由で scrape する。AdGuard Home は API ベースの `ebrianne/adguard-exporter` サイドカーを `container:adguard-home-ts` namespace に追加する。ダッシュボードは Grafana の file-based provisioner が JSON を自動ロードする (M1 で provisioner 設定済み)。

**Tech Stack:** NixOS, quadlet-nix, Podman, gatus v5, AdGuard Home, ebrianne/adguard-exporter, Grafana Alloy (River DSL), VictoriaMetrics, VictoriaLogs, Grafana provisioning (file-based)

**Spec:** `docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md`

**Branch:** `feat/obs/m2-dashboards` → `feat/obs/main`

---

## ファイルマップ

### 変更

| ファイル                                                                    | 変更内容                                                                                                          |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `services/gatus/nixos.nix`                                                  | `gatus-config.yaml` に `metrics = true`、`gatus-ts.containerConfig.publishPorts` に `127.0.0.1:8180:8080` 追加    |
| `services/adguard-home/nixos.nix`                                           | `adguard-home-ts.containerConfig.publishPorts` に `127.0.0.1:9617:9617` 追加、`adguard-exporter` コンテナ定義追加 |
| `services/observability/alloy/config.alloy`                                 | `prometheus.scrape "gatus"` / `prometheus.scrape "adguard"` を末尾 writes ブロック前に追加                        |
| `services/gatus/README.md`                                                  | metrics 有効化と publishPorts の記載追加                                                                          |
| `services/adguard-home/README.md`                                           | adguard-exporter サイドカーの記載追加                                                                             |
| `docs/cheatsheet.md`                                                        | M2 ダッシュボード URL と主要 PromQL / LogsQL を追記                                                               |
| `docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md` | M2 scope と done 定義から vaultwarden を除外する amend                                                            |

### 新規作成

| ファイル                                                                      | 内容                                                              |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `services/observability/grafana/provisioning/dashboards/host-resources.json`  | CPU/RAM/Disk/Network/Uptime/Load の 7 panel ダッシュボード        |
| `services/observability/grafana/provisioning/dashboards/service-metrics.json` | gatus + adguard の up + 主要メトリクス 7 panel ダッシュボード     |
| `services/observability/grafana/provisioning/dashboards/service-logs.json`    | service テンプレート変数で絞り込むログ検索 3 panel ダッシュボード |

### 手動操作

なし。`adguard-exporter` の image pull は `just oci-deploy` で自動取得される。

---

## 実装順序の根拠

spec L367 の commit 分割案に従う。Phase A → B → C で進めることで、各 Phase の境界で動作確認が可能になり、ダッシュボード作成時には実機メトリクスのサンプル名・ラベルを確認した上で query を確定できる。

- **Phase A (Task 1-3)**: メトリクス収集経路を確立。各 Task で `just oci-deploy` → curl / PromQL で疎通確認 → commit。Phase A 完了時点で VM の `up{}` が 4 行 (node / alloy / gatus / adguard) になる。
- **Phase B (Task 4-6)**: ダッシュボード 3 枚を順次 provisioning。Phase A で取得したメトリクスサンプルを元に query を確定する。各 Task で deploy → Grafana UI で描画確認 → commit。
- **Phase C (Task 7-8)**: cheatsheet とロードマップ amend。コードに影響なし。

順序を逆 (ダッシュボード先) にすると query 名が unknown のまま JSON を書くことになり、commit を後で手戻りで修正する必要が出るため避ける。

---

## Task 1: gatus メトリクス有効化 + gatus-ts publishPorts

**Files:**

- Modify: `services/gatus/nixos.nix:55-93` (gatus-config.yaml templates と gatus-ts containerConfig)
- Modify: `services/gatus/README.md` (metrics エンドポイントの記載)

- [ ] **Step 1: `gatus-config.yaml` に `metrics: true` を追加**

`services/gatus/nixos.nix` の `sops.templates."gatus-config.yaml".content = builtins.toJSON { ... }` ブロック (L55-93) を編集する。`storage` の前に `metrics = true;` を追加する。

```nix
sops.templates."gatus-config.yaml".content = builtins.toJSON {
  metrics = true;
  storage = {
    type = "sqlite";
    path = "/data/gatus.db";
  };
  ui = {
    title = "nz-homelab";
    header = "nz-homelab Status";
  };
  # ... 既存の alerting / endpoints は変更しない
};
```

- [ ] **Step 2: `gatus-ts` に publishPorts を追加**

同じファイルの `gatus-ts.containerConfig` ブロック (L99-120 付近) に `publishPorts` を追加する。`logDriver` の直後に挿入する。

```nix
gatus-ts = {
  autoStart = true;
  containerConfig = {
    image = "docker.io/tailscale/tailscale:latest";
    # ... 既存設定を維持 ...
    logDriver = "journald";
    publishPorts = [
      "127.0.0.1:8180:8080"  # gatus metrics → host localhost (M2)
    ];
  };
  serviceConfig.Restart = "always";
};
```

- [ ] **Step 3: NixOS build で構文エラーがないこと確認**

Run: `just oci-build`
Expected: エラーなく `Done. The new configuration is /nix/store/...` で終了。

- [ ] **Step 4: OCI へデプロイ**

Run: `just oci-deploy`
Expected: gatus-ts と gatus がローリング再起動。`switching to system configuration` で完了。

- [ ] **Step 5: gatus メトリクスエンドポイント疎通確認**

Run: `just oci-ssh 'curl -s http://127.0.0.1:8180/metrics | head -20'`
Expected: `# HELP gatus_results_total ...` 等の Prometheus 形式の出力。`gatus_results_total` / `gatus_results_duration_seconds` 等のメトリクス名が含まれる。

実際のメトリクス名が想定 (`gatus_results_*`) と異なる場合、Step 5 の出力を `docs/superpowers/plans/2026-04-27-obs-m2-dashboards.md` の `## メトリクスサンプル` 節 (Task 5 で参照) にメモする。

- [ ] **Step 6: `services/gatus/README.md` に metrics 有効化を追記**

README の「概要」または「設定」節に以下のサブセクションを追加する。

```markdown
### メトリクス

gatus は `/metrics` エンドポイントで Prometheus 形式のメトリクスを公開する (`metrics: true`)。
TS サイドカー (`gatus-ts`) の `publishPorts` でホスト `127.0.0.1:8180` に bind し、Alloy が
そこから scrape する (job: `gatus`)。
```

- [ ] **Step 7: 二度目の deploy で冪等性確認**

Run: `just oci-deploy`
Expected: 差分なしで完了 (`activating the configuration` のみで再起動なし)。

- [ ] **Step 8: Commit**

```bash
git add services/gatus/nixos.nix services/gatus/README.md
git commit -m "$(cat <<'EOF'
feat(gatus): metrics 有効化 + gatus-ts publishPorts

gatus に metrics: true を設定し /metrics エンドポイントを有効化。
Tailscale サイドカーの publishPorts で 127.0.0.1:8180:8080 を公開し、
Alloy (host network) からの scrape 経路を確立する。

- gatus-config.yaml: metrics: true 追加
- gatus-ts: publishPorts 127.0.0.1:8180:8080 追加
- README: metrics エンドポイントの記載追加

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 2: adguard-exporter サイドカー追加 + adguard-home-ts publishPorts

**Files:**

- Modify: `services/adguard-home/nixos.nix:43-69` (adguard-home-ts) と `41-103` (containers 全体)
- Modify: `services/adguard-home/README.md`

- [ ] **Step 1: `adguard-home-ts` に publishPorts を追加**

`services/adguard-home/nixos.nix` の `adguard-home-ts.containerConfig` ブロックに `publishPorts` を追加する。`logDriver = "journald";` の直後に挿入する。

```nix
adguard-home-ts = {
  autoStart = true;
  containerConfig = {
    image = "docker.io/tailscale/tailscale:latest";
    # ... 既存設定を維持 ...
    logDriver = "journald";
    publishPorts = [
      "127.0.0.1:9617:9617"  # adguard-exporter metrics → host localhost (M2)
    ];
  };
  serviceConfig.Restart = "always";
};
```

- [ ] **Step 2: `adguard-exporter` コンテナを定義**

同じファイルの `virtualisation.quadlet.containers = { ... };` ブロック内、`adguard-home` 定義の後に `adguard-exporter` を追加する。`adguard-home` 定義の閉じ括弧 `};` の後、`virtualisation.quadlet.containers` の閉じ括弧 `};` の前。

```nix
    # AdGuard exporter (Prometheus metrics via API)
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

`container:adguard-home-ts` で TS サイドカーの namespace を共有し、`127.0.0.1:3000` で AdGuard API に到達する。AdGuard は `users: []` で運用しているため認証情報は空。

- [ ] **Step 3: NixOS build で構文エラーがないこと確認**

Run: `just oci-build`
Expected: エラーなく完了。

- [ ] **Step 4: OCI へデプロイ**

Run: `just oci-deploy`
Expected: adguard-home-ts / adguard-home / adguard-exporter が順次起動。新規コンテナ image (`ebrianne/adguard-exporter:latest`) が pull される。

- [ ] **Step 5: adguard-exporter ユニット確認**

Run: `just oci-ssh 'systemctl status adguard-exporter --no-pager'`
Expected: `active (running)` 状態。`Started libpod-adguard-exporter.service` のログがある。

- [ ] **Step 6: adguard-exporter メトリクス疎通確認**

Run: `just oci-ssh 'curl -s http://127.0.0.1:9617/metrics | head -30'`
Expected: `# HELP adguard_*` 形式の Prometheus メトリクス。`adguard_dns_queries`, `adguard_blocked_filtering`, `adguard_avg_processing_time`, `adguard_query_types` 等が含まれる。

メトリクス名が想定と異なる場合、出力を Task 5 の参照用にメモする。

- [ ] **Step 7: AdGuard 認証なし動作の確認 (K-012 検証)**

Run: `just oci-ssh 'journalctl -u adguard-exporter --no-pager -n 30 | grep -iE "auth|error|401|403"'`
Expected: 認証エラーなし。`401 Unauthorized` / `403 Forbidden` ログがないこと。

もし認証エラーが出た場合、AdGuardHome.yaml の `users` を確認し、必要なら exporter の `ADGUARD_USERNAME` / `ADGUARD_PASSWORD` を sops 経由で渡す経路を追加する (本 Task の scope を拡張)。

- [ ] **Step 8: `services/adguard-home/README.md` に adguard-exporter を追記**

README の現状を `Read` で確認し、コンポーネント表 (or 構成表) に以下の行を追加する。表の列構成は既存に合わせる。ファイルツリーは nixos.nix のみの変更なので更新不要。

```markdown
| adguard-exporter | API 経由で AdGuard Home の Prometheus メトリクスを公開 (`:9617`) |
```

メトリクス節を新設する場合は以下を追加。

```markdown
### メトリクス

`ebrianne/adguard-exporter` サイドカーが AdGuard API (`http://127.0.0.1:3000`) に対して
30 秒間隔でクエリし、Prometheus 形式のメトリクスを `:9617/metrics` で公開する。
TS サイドカーの publishPorts で host `127.0.0.1:9617` に bind され、Alloy が scrape する
(job: `adguard`)。
```

- [ ] **Step 9: 二度目の deploy で冪等性確認**

Run: `just oci-deploy`
Expected: 差分なしで完了。

- [ ] **Step 10: Commit**

```bash
git add services/adguard-home/nixos.nix services/adguard-home/README.md
git commit -m "$(cat <<'EOF'
feat(adguard-home): adguard-exporter サイドカー追加 + ts publishPorts

ebrianne/adguard-exporter コンテナを container:adguard-home-ts namespace
で起動し、AdGuard API (:3000) を 30 秒間隔でクエリして Prometheus メトリクス
を :9617 で公開。TS サイドカーの publishPorts で 127.0.0.1:9617:9617 を
ホストに公開し、Alloy からの scrape 経路を確立する。

- adguard-home-ts: publishPorts 127.0.0.1:9617:9617 追加
- adguard-exporter: 新規コンテナ定義 (Requires/After: adguard-home.service)
- README: 構成表に exporter 行を追加、メトリクス節を新設

K-012 (users: [] 運用) のとおり認証情報は空で動作。

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 3: Alloy config に gatus / adguard scrape job を追加

**Files:**

- Modify: `services/observability/alloy/config.alloy:40` (writes ブロック前に挿入)

- [ ] **Step 1: `prometheus.scrape "gatus"` と `prometheus.scrape "adguard"` を追加**

`services/observability/alloy/config.alloy` の `// --- writes ---` 行 (現状 L42) の直前に以下のブロックを追加する。既存の `prometheus.scrape "alloy"` (L37-40) の直後に挿入する形になる。

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

- [ ] **Step 2: NixOS build で構文エラーがないこと確認**

Run: `just oci-build`
Expected: エラーなく完了。`config.alloy` は NixOS 側では文字列としてコピーされるだけなので、River 構文の検証は Alloy 起動時に行われる。

- [ ] **Step 3: OCI へデプロイ**

Run: `just oci-deploy`
Expected: Alloy コンテナが config 変更を検出して再起動。

- [ ] **Step 4: Alloy ログでエラー確認**

Run: `just oci-ssh 'journalctl -u alloy --no-pager -n 50 | grep -iE "error|invalid"'`
Expected: scrape 設定に関するエラーなし。`level=info msg="server listening"` 等の起動ログが出ている。

- [ ] **Step 5: Alloy 内部メトリクスで scrape job 登録確認**

Run: `just oci-ssh 'curl -s http://127.0.0.1:12345/metrics | grep "prometheus_scrape_targets_gauge"'`
Expected: `prometheus_scrape_targets_gauge{component_id="prometheus.scrape.gatus",...} 1` および `prometheus.scrape.adguard` の行がある。

- [ ] **Step 6: VictoriaMetrics で `up` が 4 行になることを確認**

Run: `just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode "query=up" | jq ".data.result | length"'`
Expected: `4` (node + alloy + gatus + adguard)。

ジョブ別に値を確認:

```bash
just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode "query=up" | jq ".data.result[] | {job: .metric.job, value: .value[1]}"'
```

Expected: 各 job の value が `"1"`。

- [ ] **Step 7: gatus メトリクスサンプル取得 (Task 5 参照用)**

Run: `just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/label/__name__/values | jq ".data | map(select(startswith(\"gatus_\"))) "'`
Expected: gatus 関連メトリクス名のリスト。`gatus_results_total`, `gatus_results_duration_seconds` 等。

- [ ] **Step 8: adguard メトリクスサンプル取得 (Task 5 参照用)**

Run: `just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/label/__name__/values | jq ".data | map(select(startswith(\"adguard_\"))) "'`
Expected: adguard 関連メトリクス名のリスト。`adguard_dns_queries`, `adguard_blocked_filtering`, `adguard_avg_processing_time`, `adguard_query_types` 等。

Step 7 / 8 の出力を Task 5 の query 確定時に参照するため、ターミナルログに残しておく。

- [ ] **Step 9: 二度目の deploy で冪等性確認**

Run: `just oci-deploy`
Expected: 差分なしで完了。

- [ ] **Step 10: Commit**

```bash
git add services/observability/alloy/config.alloy
git commit -m "$(cat <<'EOF'
feat(observability): Alloy config に gatus / adguard scrape job 追加

prometheus.scrape "gatus" (127.0.0.1:8180) と
prometheus.scrape "adguard" (127.0.0.1:9617) を追加し、
publishPorts で公開された各サービスのメトリクスを VM にリモートライト。

これで up{} が node / alloy / gatus / adguard の 4 行となる。

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 4: host-resources ダッシュボード追加

**Files:**

- Create: `services/observability/grafana/provisioning/dashboards/host-resources.json`

- [ ] **Step 1: OCI のネットワーク IF 名を確認**

Run: `just oci-ssh 'ip -br link show'`
Expected: `eth0` または `ens3` などのプライマリ IF が表示される。Step 3 の Network I/O panel の `device` フィルタに使う名前を確定する。

仮に `eth0` を採用する。実機が `ens3` だった場合は Step 3 の JSON で置換する。

- [ ] **Step 2: `host-resources.json` を新規作成**

`services/observability/grafana/provisioning/dashboards/host-resources.json` を以下の内容で作成する。Network I/O の `device` 値は Step 1 の結果に応じて差し替える。

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "CPU Usage",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "CPU %",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Memory Usage",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100",
          "legendFormat": "RAM %",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Disk Usage (/)",
      "type": "gauge",
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 70 },
              { "color": "red", "value": 90 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "(1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100",
          "legendFormat": "Disk %",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Disk Available (/)",
      "type": "stat",
      "gridPos": { "h": 6, "w": 6, "x": 6, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": { "unit": "bytes" },
        "overrides": []
      },
      "targets": [
        {
          "expr": "node_filesystem_avail_bytes{mountpoint=\"/\"}",
          "legendFormat": "Available",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Network I/O",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "Bps",
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "rate(node_network_receive_bytes_total{device=\"eth0\"}[5m])",
          "legendFormat": "RX",
          "refId": "A"
        },
        {
          "expr": "rate(node_network_transmit_bytes_total{device=\"eth0\"}[5m])",
          "legendFormat": "TX",
          "refId": "B"
        }
      ]
    },
    {
      "title": "System Uptime",
      "type": "stat",
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 14 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": { "unit": "s" },
        "overrides": []
      },
      "targets": [
        {
          "expr": "time() - node_boot_time_seconds",
          "legendFormat": "Uptime",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Load Average",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 18, "x": 6, "y": 14 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 0 }
        },
        "overrides": []
      },
      "targets": [
        { "expr": "node_load1", "legendFormat": "1m", "refId": "A" },
        { "expr": "node_load5", "legendFormat": "5m", "refId": "B" },
        { "expr": "node_load15", "legendFormat": "15m", "refId": "C" }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["homelab", "host"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "host-resources",
  "uid": "host-resources",
  "version": 1
}
```

- [ ] **Step 3: NixOS build で問題ないこと確認**

Run: `just oci-build`
Expected: エラーなく完了。Grafana の provisioning ディレクトリは bind mount で渡されるため、JSON 内容自体の検証は Grafana 起動時に行われる。

- [ ] **Step 4: OCI へデプロイ**

Run: `just oci-deploy`
Expected: Grafana コンテナの provisioning マウント差分が反映される。コンテナ再起動は通常不要 (file-based provider が定期的に再ロード)。

- [ ] **Step 5: Grafana ログで provisioning エラー確認**

Run: `just oci-ssh 'journalctl -u grafana --no-pager -n 30 | grep -iE "provisioning|dashboard|error"'`
Expected: `host-resources` の provisioning に関するエラーなし。`Provisioning dashboard` の info ログが出ていればロード成功。

- [ ] **Step 6: ブラウザで Grafana にアクセスしてダッシュボード描画確認**

URL: `https://grafana.<TS_DOMAIN>/d/host-resources`

各 panel が描画されることを確認:

- CPU Usage: 数 % で推移
- Memory Usage: 数十 % で推移
- Disk Usage / Disk Available: gauge と stat で表示
- Network I/O: RX/TX が Bps 単位で描画 (Step 1 で確認した IF の値)
- System Uptime: 秒単位で表示
- Load Average: 1m/5m/15m の 3 線

Network I/O が描画されない場合は Step 1 の IF 名が `eth0` ではなかった可能性があるため、JSON の `device="eth0"` を実機の値に修正して deploy し直す。

- [ ] **Step 7: Commit**

```bash
git add services/observability/grafana/provisioning/dashboards/host-resources.json
git commit -m "$(cat <<'EOF'
feat(observability): host-resources ダッシュボード追加

ホストリソース監視用ダッシュボードを provisioning 配下に追加。
CPU/RAM/Disk/Network/Uptime/Load の 7 panel 構成。
M1 で homelab-overview に同居していた Host resources panel を
独立化し、Network I/O は device="eth0" でフィルタして全 IF 表示問題を修正。

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 5: service-metrics ダッシュボード追加

**Files:**

- Create: `services/observability/grafana/provisioning/dashboards/service-metrics.json`

このダッシュボードの query は Task 3 Step 7-8 で取得した実機メトリクス名を元に確定する。spec のメトリクス名 (`gatus_results_total`, `adguard_dns_queries` 等) と差異があれば、本 Task の Step 1 で JSON を書く際に置換する。

- [ ] **Step 1: `service-metrics.json` を新規作成**

`services/observability/grafana/provisioning/dashboards/service-metrics.json` を以下の内容で作成する。query は spec L246-256 の想定値。Task 3 Step 7-8 の実機メトリクス名と異なる場合はここで置換する。

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Service Up/Down",
      "type": "stat",
      "gridPos": { "h": 6, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "1": { "text": "UP", "color": "green" },
                "0": { "text": "DOWN", "color": "red" }
              }
            }
          ],
          "color": { "mode": "thresholds" }
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "colorMode": "background",
        "graphMode": "none"
      },
      "targets": [
        {
          "expr": "up{job=~\"gatus|adguard\"}",
          "legendFormat": "{{job}}",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Gatus — Endpoint Success Rate",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "ops",
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "rate(gatus_results_total{success=\"true\"}[5m])",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Gatus — Endpoint Duration",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "gatus_results_duration_seconds",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "title": "AdGuard — DNS Queries Total",
      "type": "stat",
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 14 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": { "unit": "short" },
        "overrides": []
      },
      "targets": [
        {
          "expr": "adguard_dns_queries",
          "legendFormat": "Queries",
          "refId": "A"
        }
      ]
    },
    {
      "title": "AdGuard — DNS Blocked",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 6, "y": 14 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "ops",
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "rate(adguard_blocked_filtering[5m])",
          "legendFormat": "Blocked /s",
          "refId": "A"
        }
      ]
    },
    {
      "title": "AdGuard — Avg Processing Time",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 6, "x": 18, "y": 14 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": { "drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10 }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "adguard_avg_processing_time",
          "legendFormat": "Processing time",
          "refId": "A"
        }
      ]
    },
    {
      "title": "AdGuard — Query Types",
      "type": "piechart",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": { "unit": "short" },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "right" },
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false }
      },
      "targets": [
        {
          "expr": "adguard_query_types",
          "legendFormat": "{{type}}",
          "refId": "A"
        }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["homelab", "services"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "service-metrics",
  "uid": "service-metrics",
  "version": 1
}
```

- [ ] **Step 2: Task 3 Step 7-8 で取得した実機メトリクス名と照合**

Step 1 で書いた query (`gatus_results_total`, `gatus_results_duration_seconds`, `adguard_dns_queries`, `adguard_blocked_filtering`, `adguard_avg_processing_time`, `adguard_query_types`) を Task 3 Step 7-8 のメトリクス一覧と照合する。

差分がある場合 (例: `adguard_blocked_filtering` ではなく `adguard_blocked_filtering_count`)、JSON の該当 `expr` を実機の名前で置換する。`legendFormat` のラベル名も実機の label と整合させる (例: gatus の endpoint 名が `name` ではなく `endpoint` の場合など)。

- [ ] **Step 3: NixOS build で問題ないこと確認**

Run: `just oci-build`
Expected: エラーなく完了。

- [ ] **Step 4: OCI へデプロイ**

Run: `just oci-deploy`
Expected: 完了。

- [ ] **Step 5: Grafana ログで provisioning エラー確認**

Run: `just oci-ssh 'journalctl -u grafana --no-pager -n 30 | grep -iE "service-metrics|error"'`
Expected: `service-metrics` の provisioning エラーなし。

- [ ] **Step 6: ブラウザで Grafana にアクセスしてダッシュボード描画確認**

URL: `https://grafana.<TS_DOMAIN>/d/service-metrics`

各 panel が描画されることを確認:

- Service Up/Down: gatus / adguard が共に UP (緑) で表示
- Gatus 系 panel: 各エンドポイント (Vaultwarden / AdGuard Home) の系列が描画
- AdGuard 系 panel: DNS クエリ数 / ブロック数 / 処理時間 / クエリタイプ円グラフが描画

panel が "No data" になった場合は Step 2 の照合をやり直し、query 名を修正する。

- [ ] **Step 7: Commit**

```bash
git add services/observability/grafana/provisioning/dashboards/service-metrics.json
git commit -m "$(cat <<'EOF'
feat(observability): service-metrics ダッシュボード追加

gatus + adguard-home のサービスメトリクスを集約するダッシュボードを
provisioning 配下に追加。

panel:
- Service Up/Down (up{job=~"gatus|adguard"})
- Gatus: success rate / duration
- AdGuard: queries total / blocked / avg processing time / query types

query は実機 (Task 3 Step 7-8 で取得) のメトリクス名を反映。

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 6: service-logs ダッシュボード追加

**Files:**

- Create: `services/observability/grafana/provisioning/dashboards/service-logs.json`

- [ ] **Step 1: VictoriaLogs datasource のテンプレート変数対応を確認**

Run: `just oci-ssh 'curl -sG "http://127.0.0.1:9428/select/logsql/values" --data-urlencode "query=*" --data-urlencode "field=service" | head -5'`
Expected: `service` ラベルの値リストが返る (例: `adguard-home`, `alloy.service`, `gatus.service` 等)。

このエンドポイントが動けば、Grafana の templating で datasource 経由の動的取得が使える。エンドポイントが存在しない or 空配列の場合は Step 2 で static list として定義する。

- [ ] **Step 2: `service-logs.json` を新規作成 (動的取得版)**

`services/observability/grafana/provisioning/dashboards/service-logs.json` を以下の内容で作成する。Step 1 で動的取得が動かない場合は `templating.list[0]` を `type: "custom"` に変更し、`query` に `,` 区切りの値リストを直接書く。

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Log Stream",
      "type": "logs",
      "gridPos": { "h": 14, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "victoriametrics-logs-datasource", "uid": "victorialogs" },
      "options": {
        "showTime": true,
        "showLabels": false,
        "showCommonLabels": false,
        "wrapLogMessage": true,
        "prettifyLogMessage": false,
        "enableLogDetails": true,
        "dedupStrategy": "none",
        "sortOrder": "Descending"
      },
      "targets": [
        {
          "expr": "service:$service",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Log Volume by Service",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 0, "y": 14 },
      "datasource": { "type": "victoriametrics-logs-datasource", "uid": "victorialogs" },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "bars",
            "fillOpacity": 80,
            "stacking": { "mode": "normal" }
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "* | stats by (service) count() as logs",
          "queryType": "statsRange",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Error / Warning Count",
      "type": "stat",
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 14 },
      "datasource": { "type": "victoriametrics-logs-datasource", "uid": "victorialogs" },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 1 },
              { "color": "red", "value": 10 }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false }
      },
      "targets": [
        {
          "expr": "service:$service AND (_msg:error OR _msg:warn) | stats count() as cnt",
          "queryType": "stats",
          "refId": "A"
        }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["homelab", "logs"],
  "templating": {
    "list": [
      {
        "name": "service",
        "label": "Service",
        "type": "query",
        "datasource": { "type": "victoriametrics-logs-datasource", "uid": "victorialogs" },
        "query": { "query": "*", "field": "service" },
        "refresh": 2,
        "includeAll": false,
        "multi": false,
        "current": { "text": "adguard-home", "value": "adguard-home" }
      }
    ]
  },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "service-logs",
  "uid": "service-logs",
  "version": 1
}
```

Step 1 で動的取得が動かない場合の `templating.list[0]` の代替:

```json
{
  "name": "service",
  "label": "Service",
  "type": "custom",
  "query": "adguard-home,alloy.service,gatus.service,vaultwarden.service,grafana.service",
  "refresh": 0,
  "includeAll": false,
  "multi": false,
  "current": { "text": "adguard-home", "value": "adguard-home" }
}
```

- [ ] **Step 3: NixOS build で問題ないこと確認**

Run: `just oci-build`
Expected: エラーなく完了。

- [ ] **Step 4: OCI へデプロイ**

Run: `just oci-deploy`
Expected: 完了。

- [ ] **Step 5: Grafana ログで provisioning エラー確認**

Run: `just oci-ssh 'journalctl -u grafana --no-pager -n 30 | grep -iE "service-logs|error"'`
Expected: `service-logs` の provisioning エラーなし。

- [ ] **Step 6: ブラウザで Grafana にアクセスして templating 動作確認**

URL: `https://grafana.<TS_DOMAIN>/d/service-logs`

確認項目:

- ページ上部に `Service` ドロップダウンが表示される
- ドロップダウンに `adguard-home`, `alloy.service`, `gatus.service` 等のサービス名がリストされる
- `adguard-home` を選択すると `Log Stream` panel に AdGuard のクエリログが流れる
- 別のサービス (例: `gatus.service`) に切り替えると panel の内容が変わる
- `Log Volume by Service` panel に各サービスのログ量が積み上げ棒グラフで描画
- `Error / Warning Count` panel が動作 (実値はサービスによる)

ドロップダウンが空の場合は Step 1 の VictoriaLogs API が動かなかったため、Step 2 の代替 `templating.list[0]` (custom 型) に置換して deploy し直す。

- [ ] **Step 7: homelab-overview の Scrape targets up panel で 4 行を確認**

URL: `https://grafana.<TS_DOMAIN>/d/homelab-overview`

`Scrape targets up` テーブルに `node`, `alloy`, `gatus`, `adguard` の 4 行が UP で表示されることを確認。spec L272-273 の done 定義に該当。

- [ ] **Step 8: publishPorts が localhost のみであることを確認 (spec done 定義)**

Run: `just oci-ssh 'ss -tlnp | grep -E "(8180|9617)"'`
Expected: `127.0.0.1:8180` と `127.0.0.1:9617` のみ listen。`0.0.0.0:` や `::` (全 IF) で listen していないこと。

- [ ] **Step 9: Commit**

```bash
git add services/observability/grafana/provisioning/dashboards/service-logs.json
git commit -m "$(cat <<'EOF'
feat(observability): service-logs ダッシュボード追加

VictoriaLogs LogsQL を使ったサービス別ログ検索ビューを provisioning
配下に追加。templating 変数 service でフィルタを切り替え可能。

panel:
- Log Stream (service:$service)
- Log Volume by Service (* | stats by (service) count())
- Error / Warning Count (service:$service AND _msg:(error|warn))

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 7: cheatsheet にダッシュボード URL と主要 query を追記

**Files:**

- Modify: `docs/cheatsheet.md`

- [ ] **Step 1: 現状の `docs/cheatsheet.md` を確認**

Run: `head -100 docs/cheatsheet.md`
Expected: 既存セクションを把握。「Grafana」「観測スタック」等の節があれば追記する場所、なければ新設。

- [ ] **Step 2: ダッシュボード URL 節を追加**

以下のセクションを `docs/cheatsheet.md` の適切な箇所 (既存の Grafana 節 or 末尾) に追加する。`<TS_DOMAIN>` は実際の Tailscale MagicDNS suffix に読者が置き換える前提。

````markdown
### Grafana ダッシュボード

| ダッシュボード   | URL                                              | 用途                                           |
| ---------------- | ------------------------------------------------ | ---------------------------------------------- |
| homelab-overview | `https://grafana.<TS_DOMAIN>/d/homelab-overview` | 全体俯瞰 (Host + Scrape targets + Log volume)  |
| host-resources   | `https://grafana.<TS_DOMAIN>/d/host-resources`   | OCI ホスト CPU/RAM/Disk/Network/Uptime/Load    |
| service-metrics  | `https://grafana.<TS_DOMAIN>/d/service-metrics`  | gatus + adguard のサービスメトリクス           |
| service-logs     | `https://grafana.<TS_DOMAIN>/d/service-logs`     | サービス別ログ検索 (templating 変数 `service`) |

### 主要 PromQL (VictoriaMetrics)

```promql
# Scrape ターゲット稼働確認
up

# サービス別 up
up{job=~"gatus|adguard"}

# CPU 使用率 (%)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# メモリ使用率 (%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# ディスク使用率 (%)
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Gatus エンドポイント成功率
rate(gatus_results_total{success="true"}[5m])

# AdGuard ブロック率
rate(adguard_blocked_filtering[5m])
```

### 主要 LogsQL (VictoriaLogs)

```logsql
# サービス別ログ
service:adguard-home

# サービス別 + キーワード
service:gatus.service AND _msg:error

# サービス別ログ量集計
* | stats by (service) count() as logs
```
````

- [ ] **Step 3: 文法チェック (markdownlint があれば)**

Run: `nix fmt`
Expected: treefmt が走り、Markdown のフォーマット差分があれば自動整形される。

- [ ] **Step 4: Commit**

```bash
git add docs/cheatsheet.md
git commit -m "$(cat <<'EOF'
docs(cheatsheet): M2 ダッシュボード URL と主要 query を追記

Grafana ダッシュボード 4 枚 (homelab-overview / host-resources /
service-metrics / service-logs) の URL と、運用でよく使う
PromQL / LogsQL を cheatsheet に追記。

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## Task 8: ロードマップ spec の M2 scope amend (vaultwarden 除外)

**Files:**

- Modify: `docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md`

- [ ] **Step 1: ロードマップ spec の M2 セクションを確認**

Run: `grep -n -A 20 '^### M2' docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md`
Expected: M2 の scope / done 定義のテーブルが表示される。spec L347-355 の差分対象。

- [ ] **Step 2: M2 scope の amend**

ロードマップ spec の `### M2: 初期ダッシュボード整備` 配下のテーブルで、`scope` 行を以下に置換する。

変更前:

```markdown
| scope | **既存サービスの `/metrics` 有効化** (vaultwarden admin metrics、gatus の publishPort 経由公開、adguard-exporter サイドカー追加) + Alloy 設定への scrape 追加。
```

変更後:

```markdown
| scope | **既存サービスの `/metrics` 有効化** (gatus の publishPort 経由公開、adguard-exporter サイドカー追加) + Alloy 設定への scrape 追加。vaultwarden は upstream PR #6202 未マージのため M2 scope 外。
```

- [ ] **Step 3: M2 done 定義の amend**

同テーブルの `done 定義` 行の ② を以下に置換する。

変更前:

```markdown
| done 定義 | ② **サービス up (`up{job=~"vaultwarden\|gatus\|adguard-home"}`) が PromQL で引け、サービス別ダッシュボードに描画**
```

変更後:

```markdown
| done 定義 | ② **サービス up (`up{job=~"gatus\|adguard"}`) が PromQL で引け、サービス別ダッシュボードに描画** (vaultwarden は upstream PR マージ後に個別対応)
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md
git commit -m "$(cat <<'EOF'
docs(spec): roadmap M2 scope を amend (vaultwarden メトリクス除外)

vaultwarden の Prometheus メトリクス対応は upstream PR #6202 が未マージ
で stable リリースに /metrics エンドポイントが存在しないため、M2 scope
から除外する。upstream PR マージ後に個別 PR で対応。

- M2 scope: vaultwarden を除外、gatus + adguard-exporter のみに
- M2 done 定義: up{job=~"gatus|adguard"} に変更

M2 spec (2026-04-16-obs-m2-dashboards-design.md) で先行宣言済の
amend 内容を反映。

Spec: docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md
EOF
)"
```

---

## 最終確認

- [ ] **PR 作成前の git log 確認**

Run: `git log feat/obs/main..HEAD --oneline`
Expected: 8 コミットが順序通り (Task 1 → 8) に並んでいる。

- [ ] **全 deploy 後の冪等性確認**

Run: `just oci-deploy`
Expected: 全 commit 後の deploy で差分なし。

- [ ] **spec の Done 定義 (spec L424-435) 全項目確認**

| #   | 項目                                             | 確認方法                                                 |
| --- | ------------------------------------------------ | -------------------------------------------------------- |
| 1   | gatus メトリクスが VM に到達                     | `up{job="gatus"}` が `1` を返す                          |
| 2   | adguard メトリクスが VM に到達                   | `up{job="adguard"}` が `1` を返す                        |
| 3   | host-resources 描画                              | `https://grafana.<TS_DOMAIN>/d/host-resources` 全 panel  |
| 4   | service-metrics 描画                             | `https://grafana.<TS_DOMAIN>/d/service-metrics` 全 panel |
| 5   | service-logs templating 動作                     | service ドロップダウンで切替可能                         |
| 6   | ダッシュボード JSON 4 枚が provisioning でロード | `journalctl -u grafana \| grep dashboard`                |
| 7   | homelab-overview の Scrape targets up に 4 行    | `https://grafana.<TS_DOMAIN>/d/homelab-overview`         |
| 8   | publishPorts が localhost のみ                   | `ss -tlnp \| grep -E "8180\|9617"` で `127.0.0.1` のみ   |
| 9   | ロードマップ spec amend 済                       | Task 8 commit                                            |
| 10  | cheatsheet 追記済                                | Task 7 commit                                            |

- [ ] **PR 作成**

```bash
gh pr create --base feat/obs/main --head feat/obs/m2-dashboards \
  --title "feat(observability): M2 初期ダッシュボード + gatus / adguard scrape" \
  --body-file <(cat <<'EOF'
## Summary

Observability Phase 2 / M2 マイルストン実装。M1 で構築した Alloy / VM / VL / Grafana 基盤の上に、gatus と adguard-home のメトリクス scrape 経路を確立し、ホスト・サービス・ログの 3 ダッシュボードを provisioning で追加する。vaultwarden メトリクスは upstream PR #6202 未マージのため scope 外。

## 変更内容

| Task | 対象 | 内容 |
|------|------|------|
| 1 | `services/gatus/nixos.nix` | metrics: true 追加 + gatus-ts publishPorts 127.0.0.1:8180:8080 |
| 2 | `services/adguard-home/nixos.nix` | adguard-exporter 追加 + adguard-home-ts publishPorts 127.0.0.1:9617:9617 |
| 3 | `services/observability/alloy/config.alloy` | prometheus.scrape "gatus" / "adguard" 追加 |
| 4 | `services/observability/grafana/provisioning/dashboards/host-resources.json` | 新規 (CPU/RAM/Disk/Network/Uptime/Load) |
| 5 | `services/observability/grafana/provisioning/dashboards/service-metrics.json` | 新規 (gatus + adguard 主要メトリクス) |
| 6 | `services/observability/grafana/provisioning/dashboards/service-logs.json` | 新規 (service templating 変数) |
| 7 | `docs/cheatsheet.md` | ダッシュボード URL + 主要 PromQL/LogsQL |
| 8 | `docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md` | M2 scope amend (vaultwarden 除外) |

## Done Definition

実装完了時に各項目に [x] を付ける。

- [ ] gatus メトリクスが VM に到達 (`up{job="gatus"} == 1`)
- [ ] adguard-exporter メトリクスが VM に到達 (`up{job="adguard"} == 1`)
- [ ] `host-resources` ダッシュボード全 panel 描画 (CPU/RAM/Disk/Network/Uptime/Load)
- [ ] `service-metrics` ダッシュボード全 panel 描画 (gatus + adguard)
- [ ] `service-logs` で service templating 切替動作
- [ ] ダッシュボード JSON 4 枚が provisioning 経由でロード成功 (Grafana 再起動後も復元)
- [ ] homelab-overview の Scrape targets up に 4 行 (node / alloy / gatus / adguard) 表示
- [ ] publishPorts が `127.0.0.1` bind のみ (公衆 IF から到達不能)
- [ ] ロードマップ spec の M2 scope / done 定義 amend 済
- [ ] `docs/cheatsheet.md` にダッシュボード URL / 主要 query 追記済
- [ ] `just oci-deploy` 二度目で差分なし (冪等性)

## 関連

- Spec: `docs/superpowers/specs/2026-04-16-obs-m2-dashboards-design.md`
- Plan: `docs/superpowers/plans/2026-04-27-obs-m2-dashboards.md`
- ロードマップ: Observability Phase 2 / M2

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)
```

---

## メトリクスサンプル (Task 3 で記録、Task 5 で参照)

Task 3 Step 7-8 で取得した実機メトリクス名をここに転記する (実装時に上書き)。

```text
gatus メトリクス一覧:
(Task 3 Step 7 の出力をここに記載)

adguard メトリクス一覧:
(Task 3 Step 8 の出力をここに記載)
```
