# Observability M1 — 基盤バックエンド + OCI Alloy + Grafana 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OCI NixOS ホストに VictoriaLogs / VictoriaMetrics / Alloy / Grafana を quadlet-nix で配置し、journald ログ + ホスト node メトリクス + Alloy self メトリクス を集約、Grafana の「homelab-overview」ダッシュボード 1 枚で E2E 疎通を検証する

**Architecture:** 4 コンテナ (VL / VM / Alloy / Grafana) + 1 Tailscale sidecar (grafana-ts) を NixOS モジュールで宣言。VL / VM / Alloy は `network_mode=host` で loopback + Tailnet のみに露出。Grafana は TS sidecar namespace に同居し `host.containers.internal` 経由で VL / VM に到達。umbrella `default.nix` が 4 サブモジュール + sops secrets をまとめる

**Tech Stack:** NixOS, quadlet-nix (SEIAROTg/quadlet-nix), Podman, sops-nix, Tailscale, Grafana Alloy (River DSL), VictoriaLogs, VictoriaMetrics

**Spec:** `docs/superpowers/specs/2026-04-16-obs-m1-foundation-design.md`

---

## ファイルマップ

### 新規作成

| ファイル                                                                       | 責務                                                         |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `services/observability/default.nix`                                           | umbrella: 4 サブモジュール import + 共有 vars + sops secrets |
| `services/observability/secrets.yaml`                                          | Grafana admin pw + grafana-ts authkey (sops 暗号化)          |
| `services/observability/Justfile`                                              | observability レシピ (status / logs / restart)               |
| `services/observability/README.md`                                             | スタック概要・構成図・運用手順                               |
| `services/observability/victorialogs/nixos.nix`                                | VictoriaLogs quadlet-nix (network_mode=host)                 |
| `services/observability/victorialogs/README.md`                                | VL 設定・トラブルシュート                                    |
| `services/observability/victoriametrics/nixos.nix`                             | VictoriaMetrics quadlet-nix (network_mode=host)              |
| `services/observability/victoriametrics/README.md`                             | VM 設定・トラブルシュート                                    |
| `services/observability/alloy/nixos.nix`                                       | Alloy quadlet-nix (network_mode=host)                        |
| `services/observability/alloy/config.alloy`                                    | River DSL 設定 (journald + unix exporter + self scrape)      |
| `services/observability/alloy/README.md`                                       | Alloy 設定・トラブルシュート                                 |
| `services/observability/grafana/nixos.nix`                                     | Grafana + grafana-ts sidecar quadlet-nix                     |
| `services/observability/grafana/provisioning/datasources/victorialogs.yaml`    | VL datasource (host.containers.internal:9428)                |
| `services/observability/grafana/provisioning/datasources/victoriametrics.yaml` | VM datasource (host.containers.internal:8428)                |
| `services/observability/grafana/provisioning/dashboards/dashboards.yaml`       | provider config                                              |
| `services/observability/grafana/provisioning/dashboards/homelab-overview.json` | 3-panel ダッシュボード                                       |
| `services/observability/grafana/README.md`                                     | Grafana 設定・シークレットローテーション                     |

### 変更

| ファイル                                                      | 変更内容                                                    |
| ------------------------------------------------------------- | ----------------------------------------------------------- |
| `hosts/oci/configuration.nix`                                 | firewall trustedInterfaces 追加 + observability import 追加 |
| `Justfile`                                                    | `mod observability` 追加                                    |
| `docs/design-docs/adr/011-metrics-backend-victoriametrics.md` | 200GB → 100GB 訂正 + retention 決定値追記                   |
| `docs/design-docs/patterns/log-strategy.md`                   | Phase 2 セクションを現状に格上げ                            |
| `AGENTS.md`                                                   | 技術スタック表 + サービス一覧 + Justfile 操作表 更新        |

---

## Task 1: firewall trustedInterfaces + observability import

**Files:**

- Modify: `hosts/oci/configuration.nix`

- [ ] **Step 1: `hosts/oci/configuration.nix` に trustedInterfaces を追加し、observability を import する**

```nix
# hosts/oci/configuration.nix — 変更箇所のみ示す

# imports に observability を追加
imports = [
  ./disko.nix
  ./hardware-configuration.nix
  ../../services/adguard-home/nixos.nix
  ../../services/vaultwarden/nixos.nix
  ../../services/gatus/nixos.nix
  ../../services/observability          # default.nix を暗黙 import
];

# firewall ブロックを差し替え
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 ];
  trustedInterfaces = [ "tailscale0" ];
};
```

`networking.firewall.allowedTCPPorts = [ 22 ];` の行を `networking.firewall` ブロックに書き換える。

- [ ] **Step 2: コミット**

```bash
git add hosts/oci/configuration.nix
git commit -m "feat(oci): firewall trustedInterfaces に tailscale0 追加

VL/VM を network_mode=host で Tailnet + loopback のみに露出するための
前提設定。observability umbrella の import も同時に追加。"
```

> **注意**: この時点では `services/observability/` が存在しないため `nix build` は失敗する。後続タスクで作成する。コミット順はプラン通りだが、デプロイは Task 7 完了後にまとめて行う。

---

## Task 2: umbrella skeleton + secrets.yaml

**Files:**

- Create: `services/observability/default.nix`
- Create: `services/observability/secrets.yaml`

- [ ] **Step 1: `services/observability/default.nix` を作成**

```nix
{
  config,
  pkgs,
  lib,
  ...
}:
let
  vars = {
    retention = {
      logs = "30d";
      metrics = "90d";
    };
    diskBudget = {
      logs = "15GB";
      metrics = "10GB";
    };
    ports = {
      vl = 9428;
      vm = 8428;
      grafana = 3000;
      alloy = 12345;
    };
  };
in
{
  imports = [
    (import ./victorialogs/nixos.nix { inherit config pkgs lib vars; })
    (import ./victoriametrics/nixos.nix { inherit config pkgs lib vars; })
    (import ./alloy/nixos.nix { inherit config pkgs lib vars; })
    (import ./grafana/nixos.nix { inherit config pkgs lib vars; })
  ];

  # sops secrets (grafana admin, grafana-ts authkey)
  sops.secrets."grafana/admin_password" = {
    sopsFile = ./secrets.yaml;
    key = "grafana/admin_password";
    restartUnits = [ "grafana.service" ];
  };
  sops.secrets."grafana_ts/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "grafana_ts/ts_authkey";
    restartUnits = [ "grafana-ts.service" ];
  };

  sops.templates."grafana.env".content = ''
    GF_SECURITY_ADMIN_USER=admin
    GF_SECURITY_ADMIN_PASSWORD=${config.sops.placeholder."grafana/admin_password"}
    GF_USERS_ALLOW_SIGN_UP=false
  '';
  sops.templates."grafana-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."grafana_ts/ts_authkey"}
  '';
}
```

- [ ] **Step 2: `services/observability/secrets.yaml` を作成 (sops 暗号化)**

ユーザーが手動で実行する:

```bash
cd services/observability

# 平文 YAML を作成
cat > secrets.yaml.tmp <<'EOF'
grafana:
  admin_password: "<20文字以上の強パスワードをここに入れる>"
grafana_ts:
  ts_authkey: "<Tailscale admin console で grafana タグ付き reusable authkey を発行して入れる>"
EOF

# sops で暗号化 (age recipient は .sops.yaml のルールで自動適用)
sops --encrypt secrets.yaml.tmp > secrets.yaml
rm secrets.yaml.tmp
```

> **ユーザー作業**: Tailscale admin console で authkey 発行 + 強パスワード生成が必要。agent はこのステップをスキップし、placeholder ファイルをコミットしない。secrets.yaml は `.sops.yaml` ルール (`path_regex: secrets\.yaml$`) に自動マッチする。

- [ ] **Step 3: コミット**

```bash
git add services/observability/default.nix services/observability/secrets.yaml
git commit -m "feat(observability): umbrella skeleton + secrets.yaml

4 サブモジュールの import + 共有 vars (retention / diskBudget / ports) +
sops secrets (grafana admin pw / grafana-ts authkey) の骨格。"
```

---

## Task 3: VictoriaLogs quadlet-nix

**Files:**

- Create: `services/observability/victorialogs/nixos.nix`

- [ ] **Step 1: `services/observability/victorialogs/nixos.nix` を作成**

```nix
{
  config,
  pkgs,
  lib,
  vars,
}:
{
  virtualisation.quadlet.containers.victorialogs = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/victoriametrics/victoria-logs:latest";
      networks = [ "host" ];
      exec = [
        "-storageDataPath=/storage"
        "-retentionPeriod=${vars.retention.logs}"
        "--retention.maxDiskSpaceUsageBytes=${vars.diskBudget.logs}"
        "-httpListenAddr=:${toString vars.ports.vl}"
      ];
      volumes = [
        "victorialogs-data:/storage"
      ];
      healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.vl}/health || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthRetries = 3;
      healthStartPeriod = "30s";
      logDriver = "journald";
    };
    serviceConfig.Restart = "always";
  };
}
```

- [ ] **Step 2: コミット**

```bash
git add services/observability/victorialogs/nixos.nix
git commit -m "feat(observability): VictoriaLogs quadlet-nix (network_mode=host)

30 日保持 / 15 GB ディスク上限。:9428 で全 IF bind、firewall の
trustedInterfaces で Tailnet + loopback のみ露出。"
```

---

## Task 4: VictoriaMetrics quadlet-nix

**Files:**

- Create: `services/observability/victoriametrics/nixos.nix`

- [ ] **Step 1: `services/observability/victoriametrics/nixos.nix` を作成**

```nix
{
  config,
  pkgs,
  lib,
  vars,
}:
{
  virtualisation.quadlet.containers.victoriametrics = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/victoriametrics/victoria-metrics:latest";
      networks = [ "host" ];
      exec = [
        "-storageDataPath=/storage"
        "-retentionPeriod=${vars.retention.metrics}"
        "-httpListenAddr=:${toString vars.ports.vm}"
      ];
      volumes = [
        "victoriametrics-data:/storage"
      ];
      healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.vm}/health || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthRetries = 3;
      healthStartPeriod = "30s";
      logDriver = "journald";
    };
    serviceConfig.Restart = "always";
  };
}
```

- [ ] **Step 2: コミット**

```bash
git add services/observability/victoriametrics/nixos.nix
git commit -m "feat(observability): VictoriaMetrics quadlet-nix (network_mode=host)

90 日保持。:8428 で全 IF bind。ディスク上限は VM に内蔵オプションが
ないため retention + 書込みレートで 10 GB 以内を維持する運用方針。"
```

---

## Task 5: Alloy quadlet-nix + config.alloy

**Files:**

- Create: `services/observability/alloy/nixos.nix`
- Create: `services/observability/alloy/config.alloy`

- [ ] **Step 1: `services/observability/alloy/config.alloy` を作成**

```alloy
// --- journald ---
loki.source.journal "system" {
  path       = "/var/log/journal"
  forward_to = [loki.write.vl.receiver]
  labels     = { host = "oci-nix" }
  relabel_rules = loki.relabel.journal.rules
}

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "service"
  }
  rule {
    source_labels = ["__journal_container_name"]
    target_label  = "container"
  }
}

// --- AdGuard querylog (M4 activation) ---
// loki.source.file "adguard_querylog" {
//   targets    = [{ __path__ = "/var/log/adguard/querylog.json", service = "adguard-home" }]
//   forward_to = [loki.write.vl.receiver]
// }

// --- metrics: host node (built-in unix exporter) ---
prometheus.exporter.unix "host" { }

prometheus.scrape "node" {
  targets    = prometheus.exporter.unix.host.targets
  forward_to = [prometheus.remote_write.vm.receiver]
  job_name   = "node"
}

// --- metrics: Alloy self ---
prometheus.scrape "alloy" {
  targets    = [{ __address__ = "127.0.0.1:12345", job = "alloy" }]
  forward_to = [prometheus.remote_write.vm.receiver]
}

// --- writes ---
loki.write "vl" {
  endpoint { url = "http://127.0.0.1:9428/insert/loki/api/v1/push" }
}

prometheus.remote_write "vm" {
  endpoint { url = "http://127.0.0.1:8428/api/v1/write" }
}
```

- [ ] **Step 2: `services/observability/alloy/nixos.nix` を作成**

```nix
{
  config,
  pkgs,
  lib,
  vars,
}:
let
  alloyConfig = ./config.alloy;
in
{
  virtualisation.quadlet.containers.alloy = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/grafana/alloy:latest";
      networks = [ "host" ];
      exec = [
        "run"
        "--server.http.listen-addr=127.0.0.1:${toString vars.ports.alloy}"
        "/etc/alloy/config.alloy"
      ];
      volumes = [
        "${alloyConfig}:/etc/alloy/config.alloy:ro"
        "/var/log/journal:/var/log/journal:ro"
        "/etc/machine-id:/etc/machine-id:ro"
        "adguard-home-data:/var/log/adguard:ro"
        "alloy-data:/var/lib/alloy"
      ];
      healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.alloy}/-/healthy || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthRetries = 3;
      healthStartPeriod = "60s";
      logDriver = "journald";
    };
    unitConfig = {
      Requires = [
        "victorialogs.service"
        "victoriametrics.service"
      ];
      After = [
        "victorialogs.service"
        "victoriametrics.service"
      ];
    };
    serviceConfig.Restart = "always";
  };
}
```

- [ ] **Step 3: コミット**

```bash
git add services/observability/alloy/nixos.nix services/observability/alloy/config.alloy
git commit -m "feat(observability): Alloy quadlet-nix + config.alloy (host node + self scrape)

network_mode=host で journald source + 内蔵 unix exporter + Alloy self
メトリクスを収集。adguard-home-data volume を ro マウント済み (M4 先取
り、loki.source.file はコメントアウト)。VL/VM は 127.0.0.1 で到達。"
```

---

## Task 6: Grafana + Tailscale sidecar + provisioning

**Files:**

- Create: `services/observability/grafana/nixos.nix`
- Create: `services/observability/grafana/provisioning/datasources/victorialogs.yaml`
- Create: `services/observability/grafana/provisioning/datasources/victoriametrics.yaml`
- Create: `services/observability/grafana/provisioning/dashboards/dashboards.yaml`

- [ ] **Step 1: `services/observability/grafana/provisioning/datasources/victorialogs.yaml` を作成**

```yaml
apiVersion: 1
datasources:
  - name: VictoriaLogs
    type: victoriametrics-logs-datasource
    uid: victorialogs
    access: proxy
    url: http://host.containers.internal:9428
    isDefault: false
```

- [ ] **Step 2: `services/observability/grafana/provisioning/datasources/victoriametrics.yaml` を作成**

```yaml
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    type: prometheus
    uid: victoriametrics
    access: proxy
    url: http://host.containers.internal:8428
    isDefault: true
```

- [ ] **Step 3: `services/observability/grafana/provisioning/dashboards/dashboards.yaml` を作成**

```yaml
apiVersion: 1
providers:
  - name: "homelab"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: true
    updateIntervalSeconds: 60
    options:
      path: /etc/grafana/provisioning/dashboards
```

- [ ] **Step 4: `services/observability/grafana/nixos.nix` を作成**

```nix
{
  config,
  pkgs,
  lib,
  vars,
}:
let
  serveJson = pkgs.writeText "grafana-ts-serve.json" (
    builtins.toJSON {
      TCP = {
        "443" = {
          HTTPS = true;
        };
      };
      Web = {
        "\${TS_CERT_DOMAIN}:443" = {
          Handlers = {
            "/" = {
              Proxy = "http://127.0.0.1:${toString vars.ports.grafana}";
            };
          };
        };
      };
    }
  );
in
{
  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    grafana-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
          TS_HOSTNAME = "grafana";
          TS_STATE_DIR = "/var/lib/tailscale";
          TS_SERVE_CONFIG = "/config/serve.json";
          TS_USERSPACE = "true";
        };
        environmentFiles = [
          config.sops.templates."grafana-ts.env".path
        ];
        volumes = [
          "grafana-ts-state:/var/lib/tailscale"
          "${serveJson}:/config/serve.json:ro"
        ];
        healthCmd = "tailscale status --json | grep -q '\"Online\": true' || exit 1";
        healthInterval = "30s";
        healthTimeout = "10s";
        healthRetries = 3;
        healthStartPeriod = "60s";
        logDriver = "journald";
      };
      serviceConfig.Restart = "always";
    };

    # Grafana
    grafana = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/grafana/grafana:latest";
        environments = {
          GF_INSTALL_PLUGINS = "victoriametrics-logs-datasource";
        };
        environmentFiles = [
          config.sops.templates."grafana.env".path
        ];
        networks = [ "container:grafana-ts" ];
        volumes = [
          "grafana-data:/var/lib/grafana"
          "${./provisioning}:/etc/grafana/provisioning:ro"
        ];
        healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.grafana}/api/health || exit 1";
        healthInterval = "30s";
        healthTimeout = "10s";
        healthRetries = 3;
        healthStartPeriod = "60s";
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "grafana-ts.service" ];
        After = [ "grafana-ts.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };
}
```

> **注意**: `GF_INSTALL_PLUGINS = "victoriametrics-logs-datasource"` で VL datasource plugin を初回起動時に自動インストールする。Grafana 公式イメージにはバンドルされていない。

- [ ] **Step 5: コミット**

```bash
git add services/observability/grafana/
git commit -m "feat(observability): Grafana + TS sidecar + provisioning (host.containers.internal datasource)

Tailscale Serve 経由で HTTPS 公開 (既存 vaultwarden-ts パターン踏襲)。
datasource は host.containers.internal:9428 (VL) / :8428 (VM)。
VL plugin は GF_INSTALL_PLUGINS で自動インストール。"
```

---

## Task 7: homelab-overview ダッシュボード JSON

**Files:**

- Create: `services/observability/grafana/provisioning/dashboards/homelab-overview.json`

- [ ] **Step 1: `homelab-overview.json` を作成**

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
      "title": "Host resources",
      "type": "timeseries",
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "fillOpacity": 10
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Net RX" },
            "properties": [
              { "id": "unit", "value": "Bps" },
              { "id": "min", "value": null },
              { "id": "max", "value": null }
            ]
          }
        ]
      },
      "targets": [
        {
          "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "CPU %",
          "refId": "A"
        },
        {
          "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100",
          "legendFormat": "RAM %",
          "refId": "B"
        },
        {
          "expr": "(1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100",
          "legendFormat": "Disk %",
          "refId": "C"
        },
        {
          "expr": "rate(node_network_receive_bytes_total[5m])",
          "legendFormat": "Net RX",
          "refId": "D"
        }
      ]
    },
    {
      "title": "Scrape targets up",
      "type": "table",
      "gridPos": { "h": 6, "w": 12, "x": 0, "y": 10 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "fieldConfig": {
        "defaults": {},
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Value" },
            "properties": [
              {
                "id": "mappings",
                "value": [
                  {
                    "type": "value",
                    "options": {
                      "1": { "text": "UP", "color": "green" },
                      "0": { "text": "DOWN", "color": "red" }
                    }
                  }
                ]
              }
            ]
          }
        ]
      },
      "targets": [
        {
          "expr": "up",
          "format": "table",
          "instant": true,
          "refId": "A"
        }
      ],
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": { "Time": true, "__name__": true },
            "renameByName": { "job": "Job", "instance": "Instance", "Value": "Status" }
          }
        }
      ]
    },
    {
      "title": "Log volume by service",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 10 },
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
          "refId": "A"
        }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["homelab", "overview"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "homelab-overview",
  "uid": "homelab-overview",
  "version": 1
}
```

> **注意**: datasource uid は provisioning YAML で固定値 (`victoriametrics` / `victorialogs`) を設定し、dashboard JSON から同じ uid で参照している。uid が一致しないとパネルがデータを引けない。

- [ ] **Step 2: コミット**

```bash
git add services/observability/grafana/provisioning/dashboards/homelab-overview.json
git commit -m "feat(observability): homelab-overview dashboard

3 panel: Host resources (CPU/RAM/Disk/Net) / Scrape targets up (table) /
Log volume by service (stacked bar)。M1 時点では scrape は node + alloy
の 2 行。M2 でサービス /metrics 追加後に自動的に行が増える。"
```

---

## Task 8: Justfile + ルート mod 登録

**Files:**

- Create: `services/observability/Justfile`
- Modify: `Justfile`

- [ ] **Step 1: `services/observability/Justfile` を作成**

```just
default:
    @just --list

####################
# Observe (OCI NixOS — systemctl は root@oci で実行)
####################

oci_host := `sops -d --extract '["oci_host"]' ../../hosts/oci/secrets.yaml`

# Show status of observability units
[group('observe')]
status:
    ssh root@{{oci_host}} 'systemctl list-units --no-pager alloy.service victorialogs.service victoriametrics.service grafana.service grafana-ts.service'

# Show logs for an observability unit
[group('observe')]
logs unit="alloy" count="50":
    ssh root@{{oci_host}} 'journalctl -u {{unit}}.service -n {{count}} --no-pager'

# Follow logs for an observability unit
[group('observe')]
logs-follow unit="alloy":
    ssh root@{{oci_host}} 'journalctl -u {{unit}}.service -f'

# Restart all observability units
[group('lifecycle')]
restart:
    ssh root@{{oci_host}} 'systemctl restart victorialogs victoriametrics alloy grafana-ts grafana'

# Quick VL query (recent 5m logs)
[group('debug')]
vl-query query="_time:5m":
    ssh root@{{oci_host}} 'curl -sG http://127.0.0.1:9428/select/logsql/query --data-urlencode "query={{query}}" | head -10'

# Quick VM query (up metrics)
[group('debug')]
vm-query query="up":
    ssh root@{{oci_host}} 'curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode "query={{query}}" | jq -r ".data.result[]"'
```

- [ ] **Step 2: ルート `Justfile` に `mod observability` を追加**

`mod ollama` 行の後に追加:

```just
mod observability 'services/observability'
```

- [ ] **Step 3: コミット**

```bash
git add services/observability/Justfile Justfile
git commit -m "feat(observability): Justfile レシピ追加

just observability status / logs / restart / vl-query / vm-query。
ルート Justfile に mod observability 登録。"
```

---

## Task 9: README 群 (observability / 各サブコンポーネント)

**Files:**

- Create: `services/observability/README.md`
- Create: `services/observability/victorialogs/README.md`
- Create: `services/observability/victoriametrics/README.md`
- Create: `services/observability/alloy/README.md`
- Create: `services/observability/grafana/README.md`

- [ ] **Step 1: `services/observability/README.md` を作成**

````markdown
# Observability スタック

Alloy + VictoriaLogs + VictoriaMetrics + Grafana による観測スタック。OCI NixOS ホスト上で quadlet-nix (rootful モード) によりデプロイする。

## 構成

| コンポーネント  | ポート | network mode         | 役割                                              |
| --------------- | ------ | -------------------- | ------------------------------------------------- |
| VictoriaLogs    | 9428   | host                 | ログバックエンド (30d / 15GB)                     |
| VictoriaMetrics | 8428   | host                 | メトリクスバックエンド (90d / 10GB)               |
| Alloy           | 12345  | host                 | コレクタ (journald + node exporter + self scrape) |
| Grafana         | 3000   | container:grafana-ts | UI (Tailscale Serve で HTTPS 公開)                |
| grafana-ts      | —      | bridge + TS          | Tailscale sidecar                                 |

## 操作

```bash
just observability status         # ユニット稼働状況
just observability logs            # Alloy ログ (デフォルト)
just observability logs grafana    # Grafana ログ
just observability restart         # 全ユニット再起動
just observability vl-query        # VL 直接クエリ (直近 5 分)
just observability vm-query        # VM 直接クエリ (up)
```
````

## デプロイ

```bash
just oci-deploy                    # NixOS rebuild (observability 含む)
just oci-status                    # 全ユニット確認
```

## Secrets ローテーション

### Grafana admin パスワード

```bash
cd services/observability
sops secrets.yaml
# grafana.admin_password を変更して保存
just oci-deploy
```

### Tailscale authkey

Tailscale admin console で新しい reusable authkey を発行し、`secrets.yaml` の `grafana_ts.ts_authkey` を更新:

```bash
sops secrets.yaml
# grafana_ts.ts_authkey を変更して保存
just oci-deploy
```

## 関連ドキュメント

- [Spec: M1 Foundation](../../docs/superpowers/specs/2026-04-16-obs-m1-foundation-design.md)
- [ADR-007: VictoriaLogs](../../docs/design-docs/adr/007-log-backend-victorialogs.md)
- [ADR-008: Alloy 統一コレクタ](../../docs/design-docs/adr/008-alloy-unified-collector.md)
- [ADR-011: VictoriaMetrics](../../docs/design-docs/adr/011-metrics-backend-victoriametrics.md)

````

- [ ] **Step 2: `services/observability/victorialogs/README.md` を作成**

```markdown
# VictoriaLogs

ログバックエンド。`network_mode=host` で `:9428` に bind。

## 主要設定

| 設定                        | 値   | 根拠             |
| --------------------------- | ---- | ---------------- |
| retentionPeriod             | 30d  | M1 spec 決定 #1  |
| retention.maxDiskSpaceUsage | 15GB | OCI 100GB 内配分 |
| httpListenAddr              | :9428 | ホスト全 IF      |

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:9428/health'

# 直近 5 分のログ件数
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query --data-urlencode "query=_time:5m" | wc -l'

# ディスク使用量
just oci-ssh 'du -sh /var/lib/containers/storage/volumes/victorialogs-data'
````

````

- [ ] **Step 3: `services/observability/victoriametrics/README.md` を作成**

```markdown
# VictoriaMetrics

メトリクスバックエンド (Prometheus 互換)。`network_mode=host` で `:8428` に bind。

## 主要設定

| 設定             | 値   | 根拠             |
| ---------------- | ---- | ---------------- |
| retentionPeriod  | 90d  | M1 spec 決定 #2  |
| httpListenAddr   | :8428 | ホスト全 IF      |

ディスク上限の強制オプションは VM に存在しないため、retention 90d と書き込みレートで 10 GB 以内を維持する運用方針。

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:8428/health'

# scrape target 数
just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode "query=up" | jq ".data.result | length"'

# ディスク使用量
just oci-ssh 'du -sh /var/lib/containers/storage/volumes/victoriametrics-data'
````

````

- [ ] **Step 4: `services/observability/alloy/README.md` を作成**

```markdown
# Alloy

統一コレクタ。`network_mode=host` で journald / ホスト node メトリクス / Alloy self メトリクスを収集し、VL (loki push) / VM (remote_write) に送信。

## 収集対象 (M1)

| ソース                        | 宛先 | config.alloy ブロック          |
| ----------------------------- | ---- | ------------------------------ |
| journald                      | VL   | loki.source.journal "system"   |
| ホスト node (unix exporter)   | VM   | prometheus.scrape "node"       |
| Alloy self (/metrics)         | VM   | prometheus.scrape "alloy"      |
| AdGuard querylog (M4 で有効化) | VL   | loki.source.file (コメントアウト) |

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:12345/-/healthy'

# scrape targets 確認
just oci-ssh 'curl -s http://127.0.0.1:12345/api/v1/targets'

# config reload
just oci-ssh 'curl -X POST http://127.0.0.1:12345/-/reload'
````

````

- [ ] **Step 5: `services/observability/grafana/README.md` を作成**

```markdown
# Grafana

可視化 UI。Tailscale Serve 経由で `https://grafana.<tailnet>.ts.net` に公開。

## Datasource

| 名前            | タイプ                           | URL                                  |
| --------------- | -------------------------------- | ------------------------------------ |
| VictoriaLogs    | victoriametrics-logs-datasource  | http://host.containers.internal:9428 |
| VictoriaMetrics | prometheus                       | http://host.containers.internal:8428 |

## ダッシュボード

provisioning で `/etc/grafana/provisioning/dashboards/` 配下の JSON を自動読み込み。変更は Grafana UI で行った後 JSON エクスポートしてリポジトリにコミットする。

## トラブルシュート

```bash
# ヘルスチェック
just oci-ssh 'curl -s http://127.0.0.1:3000/api/health'
# 注: Grafana は container:grafana-ts の namespace 内にいるため、
# ホストからは直接届かない。grafana-ts コンテナ内から実行するか、
# Tailscale 経由でアクセスする。

# VL plugin インストール確認
just observability logs grafana 20  # "Plugin victoriametrics-logs-datasource installed" を確認
````

````

- [ ] **Step 6: コミット**

```bash
git add services/observability/README.md \
  services/observability/victorialogs/README.md \
  services/observability/victoriametrics/README.md \
  services/observability/alloy/README.md \
  services/observability/grafana/README.md
git commit -m "docs(observability): 各コンポーネント README 追加

スタック概要・構成図・運用手順・secrets ローテーション・トラブルシュート。"
````

---

## Task 10: ADR-011 訂正 + ロードマップ amend

**Files:**

- Modify: `docs/design-docs/adr/011-metrics-backend-victoriametrics.md`
- Modify: `docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md` (既に spec PR で amend 済みなら不要)

- [ ] **Step 1: ADR-011 の 200GB → 100GB 訂正 + Consequences に決定値追記**

`docs/design-docs/adr/011-metrics-backend-victoriametrics.md` を編集:

1. 「波及する未決事項」の `OCI 200 GB ブートボリューム` → `OCI 100 GB ブートボリューム`
2. 「良い面」セクション末尾に以下を追加:

```markdown
- M1 spec (2026-04-16) で retention / ディスク予算を確定: VictoriaMetrics 90d / 10 GB、VictoriaLogs 30d / 15 GB
```

- [ ] **Step 2: コミット**

```bash
git add docs/design-docs/adr/011-metrics-backend-victoriametrics.md
git commit -m "docs(adr): ADR-011 200GB→100GB 訂正 + retention 決定値追記

M1 spec で確定した retention / ディスク予算を Consequences に反映。"
```

---

## Task 11: log-strategy.md 更新

**Files:**

- Modify: `docs/design-docs/patterns/log-strategy.md`

- [ ] **Step 1: Phase 2 セクションを現状に格上げ**

`docs/design-docs/patterns/log-strategy.md` を編集:

- 「将来（Phase 2 ...）」の見出しを「現在（Phase 2 — Alloy + VictoriaLogs / VictoriaMetrics）」に変更
- 既存の「現在（Phase 1 ...）」の見出しを「以前（Phase 1 — journald 集約のみ）」に変更
- Phase 1 セクション末尾に注記を追加:

```markdown
> **注**: fluent-bit サイドカーは M4 で撤去予定。M1 で Alloy が導入されたため、journald 以外のログ (AdGuard querylog 等) も Alloy の `loki.source.file` で直接収集する方針に移行する。
```

- [ ] **Step 2: コミット**

```bash
git add docs/design-docs/patterns/log-strategy.md
git commit -m "docs(patterns): log-strategy.md を Phase 2 稼働に更新

Phase 2 (Alloy + VL/VM) を「現在」に格上げ。Phase 1 は「以前」に降格し、
fluent-bit 撤去予定の注記を追加。"
```

---

## Task 12: AGENTS.md 更新

**Files:**

- Modify: `AGENTS.md`

- [ ] **Step 1: AGENTS.md を 3 箇所更新**

1. **技術スタック表**: `観測スタック` 行を更新

```markdown
| 観測スタック | Alloy + VictoriaLogs + VictoriaMetrics + Grafana (Phase 2 / OCI 稼働中、リモート Alloy は M3) |
```

2. **機能概要 サービス一覧**: 追加

```markdown
- [services/observability/README.md](services/observability/README.md) — Alloy + VictoriaLogs + VictoriaMetrics + Grafana 観測スタック
```

3. **操作セクション**: 追加

```bash
just observability <recipe>       # observability 操作
```

4. **リポジトリ構成**: `services/` 配下に追加

```
├── observability/                    # → README.md 参照 (観測スタック)
```

- [ ] **Step 2: コミット**

```bash
git add AGENTS.md
git commit -m "docs(agents): AGENTS.md に observability スタック情報追加

技術スタック表・サービス一覧・Justfile 操作表・リポジトリ構成を更新。"
```

---

## Task 13: デプロイ + E2E 検証

**Files:** なし (OCI ホスト上での操作)

> **前提**: Task 2 の secrets.yaml がユーザーにより作成済みであること。

- [ ] **Step 1: ビルド確認**

```bash
just oci-build
```

ビルドエラーがあれば修正してコミット。

- [ ] **Step 2: デプロイ**

```bash
just oci-deploy
```

- [ ] **Step 3: journald 永続化確認**

```bash
just oci-ssh 'ls /var/log/journal/'
```

ディレクトリが存在しファイルがあること。もし `/var/log/journal/` が空か存在しない場合、journald が volatile モード (`/run/log/journal`) で動いている。その場合 `hosts/oci/configuration.nix` に以下を追加してから再デプロイ:

```nix
services.journald.extraConfig = ''
  Storage=persistent
  SystemMaxUse=2G
  MaxRetentionSec=180day
'';
```

- [ ] **Step 4: ユニット稼働確認**

```bash
just oci-status | grep -E 'alloy|victorialogs|victoriametrics|grafana'
```

5 ユニット (`alloy`, `victorialogs`, `victoriametrics`, `grafana`, `grafana-ts`) が `active (running)` であること。

- [ ] **Step 5: VictoriaLogs 疎通**

```bash
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query --data-urlencode "query=_time:5m" | head -5'
```

journald ログが JSON 行で返ること。

- [ ] **Step 6: VictoriaMetrics 疎通**

```bash
just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode "query=up" | jq ".data.result | length"'
```

期待値: `2` (node + alloy)。

- [ ] **Step 7: Grafana UI 確認**

ブラウザで `https://grafana.<tailnet>.ts.net` にアクセス:

1. admin ログインできる
2. VictoriaLogs datasource が「Connected」
3. VictoriaMetrics datasource が「Connected」
4. homelab-overview ダッシュボード:
   - Host resources panel に CPU / RAM / Disk / Net の値
   - Scrape targets up panel に node / alloy の 2 行
   - Log volume by service panel に journald 由来のサービス別カウント

- [ ] **Step 8: firewall 動作確認**

別マシンから OCI の公衆 IP で `:9428` / `:8428` にアクセスし、接続拒否されることを確認。

- [ ] **Step 9: Tailnet 経由 push エンドポイント確認 (M3 先取り)**

別マシン (Tailnet 参加済み) から:

```bash
curl -sG http://<oci-tailnet-ip>:9428/ping
curl -sG http://<oci-tailnet-ip>:8428/health
```

両方レスポンスが返ること。

- [ ] **Step 10: AdGuard ro マウント確認**

```bash
just oci-ssh 'podman exec alloy ls /var/log/adguard/'
```

`querylog.json` 等のファイルが見えること (ro マウント成功)。

- [ ] **Step 11: ダッシュボード JSON の最終化**

Grafana UI でパネルを微調整した場合、JSON エクスポートして `homelab-overview.json` を更新:

```bash
# ブラウザで調整後、Share → Export → Save to file
# ダウンロードした JSON でリポジトリの homelab-overview.json を上書き
git add services/observability/grafana/provisioning/dashboards/homelab-overview.json
git commit -m "feat(observability): homelab-overview dashboard JSON 最終化

Grafana UI で微調整した結果を provisioning JSON に反映。"
```

---

## Task 14: PR 作成

- [ ] **Step 1: ブランチを push して PR 作成**

```bash
git push -u origin feat/obs/m1-foundation
gh pr create --base main --title "feat(observability): M1 基盤バックエンド + OCI Alloy + Grafana" --body "$(cat <<'EOF'
## Summary

- VictoriaLogs / VictoriaMetrics / Alloy / Grafana を quadlet-nix で OCI NixOS に配置
- Alloy: journald source + 内蔵 unix exporter (host node) + self メトリクス
- Grafana: Tailscale Serve HTTPS + provisioning datasource + homelab-overview dashboard (3 panel)
- firewall trustedInterfaces で Tailnet + loopback のみ露出
- ADR-011 訂正、log-strategy.md 更新、AGENTS.md 更新

## Spec

- `docs/superpowers/specs/2026-04-16-obs-m1-foundation-design.md`

## Done 定義チェック

- [ ] 5 ユニットが active (running)
- [ ] VL に journald ログ到達、LogsQL で引ける
- [ ] VM に host node + alloy self メトリクス到達、PromQL で引ける
- [ ] homelab-overview 3 panel に実データ描画
- [ ] adguard-home-data ro マウント済み
- [ ] Tailnet 経由 push endpoint 到達
- [ ] eth0 から :9428/:8428 未到達
- [ ] Docs 更新済み

## Test plan

- [ ] `just oci-build` 成功
- [ ] `just oci-deploy` 成功
- [ ] `just oci-status` で 5 ユニット active
- [ ] VL/VM curl 疎通
- [ ] Grafana UI でダッシュボード描画確認
- [ ] firewall 動作確認 (公衆 IP から拒否)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
