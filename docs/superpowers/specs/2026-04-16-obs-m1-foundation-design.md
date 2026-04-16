# Observability M1 — 基盤バックエンド + OCI Alloy + Grafana (E2E 疎通) spec

## 概要

Phase 2 観測スタック実装ロードマップの **M1 マイルストン** 個別 spec。OCI NixOS ホスト上に VictoriaLogs / VictoriaMetrics / Alloy / Grafana を quadlet-nix で配置し、既存サービス (vaultwarden / gatus / adguard-home) の journald ログ と **ホストレベルメトリクス (Alloy 内蔵 unix exporter + Alloy 自身)** を集約、Grafana の「homelab-overview」ダッシュボード 1 枚で E2E 疎通を検証する。

既存サービスの `/metrics` scrape は現状どのサービスも `/metrics` が有効化されておらず、かつ各サービスが TS サイドカーと network namespace を共有しているため、M1 では対象外とし **M2 (ダッシュボード整備) で各サービスの `/metrics` 有効化とあわせて scope 化** する。これに伴い ロードマップ spec の M1 done 定義 ② を本 spec PR 内で同時に amend する。

M1 は観測スタック全 5 マイルストンのうち、バックエンドと OCI 側コレクタ・UI の土台を一括投入する基盤 PR。後続マイルストン (M2 ダッシュボード整備 / M3 リモート Alloy / M4 AdGuard fluent-bit 撤去 / M5 vmalert) はこの土台の上に積む。

### 上流ドキュメント

- [ロードマップ spec](./2026-04-15-observability-implementation-roadmap.md) — M1 の scope / done 定義 / 決定ロック #1-7 を規定
- [ADR-007 ログバックエンドに VictoriaLogs を採用](../../design-docs/adr/007-log-backend-victorialogs.md)
- [ADR-008 Alloy 統一コレクタ](../../design-docs/adr/008-alloy-unified-collector.md)
- [ADR-010 アラート経路役割分担](../../design-docs/adr/010-alert-routing.md)
- [ADR-011 メトリクスバックエンドに VictoriaMetrics を採用](../../design-docs/adr/011-metrics-backend-victoriametrics.md)
- [パターン: Quadlet 構成規約](../../design-docs/patterns/quadlet-conventions.md)
- [パターン: Tailscale サイドカー](../../design-docs/patterns/tailscale-sidecar.md)
- [パターン: ログ戦略](../../design-docs/patterns/log-strategy.md)

### スコープ

**in scope**:

- `services/observability/` ディレクトリ新設 (umbrella `default.nix` + 4 サブモジュール)
- VictoriaLogs / VictoriaMetrics / Alloy の quadlet-nix 化、`network_mode=host` でホストネットワーク参加、firewall で tailscale0 + loopback のみ許可
- Alloy の設定 (journald source / 内蔵 unix exporter / Alloy self metrics / VL・VM への push)
- Grafana + Tailscale Serve サイドカー、provisioning による datasource 2 本 + ダッシュボード 1 枚
- AdGuard Home quadlet の `adguard-home-data` volume を Alloy コンテナに ro マウント (M4 先取り。`loki.source.file` はコメントアウト状態)
- **ロードマップ spec の M1 done 定義 ② の amend** (サービス `/metrics` → host メトリクスに縮小)
- ADR-011 の「200GB → 100GB」訂正 + retention / disk budget 決定値追記
- ドキュメント更新 (AGENTS.md / log-strategy.md / 新規 README)

**out of scope** (roadmap で他 M に割付 / M2 に寄せる):

- **既存サービス `/metrics` の有効化および scrape → M2** (vaultwarden admin metrics、adguard-exporter サイドカー追加、gatus /metrics 公開など各サービスの改修とセット)
- M2: 本格ダッシュボード整備
- M3: リモートホスト (LiRu / WSL2) Alloy 配置
- M4: AdGuard querylog の Alloy 直読み有効化 + fluent-bit 撤去
- M5: vmalert + 通知経路
- Phase 3 候補: cadvisor 包括追加、trace 基盤、object storage 階層化、外部公開 Grafana

---

## 決定ロック (M1)

ロードマップ spec の決定ロック表 #1-7 を本 spec で以下の値に確定する。

| #   | 項目                                     | 決定値                                                                                                                         |
| --- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1   | VictoriaLogs 保持期間 / ディスク予算     | **30 日 / 15 GB**                                                                                                              |
| 2   | VictoriaMetrics retention / ディスク予算 | **90 日 / 10 GB**                                                                                                              |
| 3   | VictoriaMetrics backup 戦略              | **OCI ブートボリュームスナップショット依存**。`vmbackup` は不採用                                                              |
| 4   | リモート push 受信口の auth              | **Tailscale インターフェース bind のみ**。追加トークン・mTLS なし                                                              |
| 5   | 初期 scrape 対象                         | **Alloy 内蔵 `prometheus.exporter.unix` (ホスト node メトリクス) + Alloy 自身の `/metrics`**。既存サービス /metrics は M2 送り |
| 6   | Grafana 認証方式                         | **Tailscale Serve 前段 + Grafana ローカル admin**。admin パスワードは sops 管理                                                |
| 7   | M1 の初期 panel 内容                     | **「homelab-overview」1 ダッシュボード / 3 panel**: Host resources / Scrape targets up / Log volume by service                 |

観測スタック合計ディスク予算は **25 GB** (VL 15 + VM 10)。OCI ブートボリューム 100 GB のうち、OS + 既存サービス + nix store で ~30 GB 使用中の前提で、空き ~70 GB の 1/3 弱を割り当てる。

---

## アーキテクチャ

```
┌────────────────── OCI NixOS host (oci-nix) ──────────────────┐
│                                                              │
│  vaultwarden / gatus / adguard-home (既存、container:*-ts)   │
│        │ LogDriver=journald                                  │
│        ▼                                                     │
│   ┌────────────┐                                             │
│   │  journald  │◄──── Alloy (network_mode=host)              │
│   └────────────┘       loki.source.journal                   │
│                                                              │
│   ┌────────────────────────────────────────────────────┐     │
│   │ Alloy (network_mode=host)                          │     │
│   │  ├ loki.source.journal                             │     │
│   │  ├ loki.source.file     (adguard querylog, 無効)   │     │
│   │  ├ prometheus.exporter.unix (ホスト node メトリクス)│     │
│   │  ├ prometheus.scrape    (self + unix exporter)     │     │
│   │  ├ loki.write             → VL (127.0.0.1:9428)    │     │
│   │  └ prometheus.remote_write → VM (127.0.0.1:8428)   │     │
│   └────────────────────────────────────────────────────┘     │
│                                                              │
│   VictoriaLogs    (network_mode=host, :9428)                 │
│   VictoriaMetrics (network_mode=host, :8428)                 │
│     ▲              ▲                                         │
│     │ host.containers.internal                               │
│   ┌─┴──────────────┴─┐                                       │
│   │    Grafana       │◄── grafana-ts (sidecar, TS Serve 443) │
│   │(container:grafana-ts)                                    │
│   └──────────────────┘                                       │
│                                                              │
│   firewall: trustedInterfaces = [ "tailscale0" ]             │
│     → loopback + tailnet 到達。eth0 (公衆側) からは届かない  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                              ▲
                              │ https://grafana.<tailnet>.ts.net
                         [User browser]
                              ▲
                              │ M3 先取り: tailscale0:9428/8428 へ
                         [LiRu / WSL2 Alloy]
```

### データフロー

| 種別                     | 経路                                                                                                                        |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| コンテナ stdout          | container → journald (LogDriver=journald) → Alloy (loki.source.journal) → VL (loki.write, 127.0.0.1:9428)                   |
| AdGuard querylog.json    | (M1 では無効。M4 で有効化) adguard-home-data volume → Alloy (loki.source.file, ro) → VL                                     |
| ホスト node メトリクス   | Alloy (prometheus.exporter.unix) → Alloy (prometheus.scrape "node") → VM (127.0.0.1:8428)                                   |
| Alloy self メトリクス    | Alloy `/metrics` → Alloy (prometheus.scrape "alloy") → VM (127.0.0.1:8428)                                                  |
| Grafana クエリ           | user browser → TS Serve (tailscale0:443) → grafana-ts → Grafana (container:grafana-ts) → VL/VM (`host.containers.internal`) |
| M3 先取り: リモート push | LiRu/WSL2 Alloy → Tailnet → OCI ホスト (tailscale0:9428 / 8428) → VL/VM (network_mode=host)                                 |

**M3 先取り配慮**: VL/VM は `network_mode=host` でホストの全インターフェースに bind し、firewall (`trustedInterfaces = [ "tailscale0" ]`) で Tailnet + loopback のみ許可する。同一ホスト内の Alloy は `127.0.0.1` で届き、リモート Alloy は Tailnet IP で同じプロセスに届く。同一プロセス / 同一受信口で両用途を捌ける。

---

## リポジトリ構成

```
services/observability/
├── default.nix                    # umbrella。4 サブモジュール import + 共有 let
├── README.md                      # スタック全体の概要・運用
├── Justfile                       # just observability <recipe>
├── secrets.yaml                   # 共有 sops (grafana admin pw, TS authkey)
│
├── alloy/
│   ├── nixos.nix                  # Quadlet (rootful Nix モード)
│   ├── config.alloy               # River 設定 (静的、sops 展開なし)
│   └── README.md
│
├── victorialogs/
│   ├── nixos.nix
│   └── README.md
│
├── victoriametrics/
│   ├── nixos.nix
│   └── README.md
│
└── grafana/
    ├── nixos.nix                  # Quadlet + TS sidecar + provisioning volume
    ├── provisioning/
    │   ├── datasources/
    │   │   ├── victorialogs.yaml
    │   │   └── victoriametrics.yaml
    │   └── dashboards/
    │       ├── dashboards.yaml    # provider config
    │       └── homelab-overview.json
    └── README.md
```

### umbrella 設計

`services/observability/default.nix` の構造:

```nix
{ config, pkgs, lib, ... }:
let
  vars = {
    retention = { logs = "30d"; metrics = "90d"; };
    diskBudget = { logs = "15GB"; metrics = "10GB"; };
    ports = { vl = 9428; vm = 8428; grafana = 3000; alloy = 12345; };
  };
in {
  imports = [
    (import ./victorialogs/nixos.nix { inherit config pkgs lib vars; })
    (import ./victoriametrics/nixos.nix { inherit config pkgs lib vars; })
    (import ./alloy/nixos.nix { inherit config pkgs lib vars; })
    (import ./grafana/nixos.nix { inherit config pkgs lib vars; })
  ];

  # 共有 sops (grafana admin, grafana-ts authkey)
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

import パターンは `hosts/oci/configuration.nix` 側で `imports = [ ../../services/observability ]` の 1 行のみ。

### hosts/oci/vars.nix

変更不要。VL/VM は `network_mode=host` でホスト全インターフェースに bind し、firewall (`trustedInterfaces = [ "tailscale0" ]`) で到達範囲を絞る方式を採るため、Tailnet IP をリポジトリに持つ必要は無い。

---

## ネットワーク / 露出 / 認証

| 成分            | network mode                 | bind                                | 露出先                               | 認証                        |
| --------------- | ---------------------------- | ----------------------------------- | ------------------------------------ | --------------------------- |
| VictoriaLogs    | `host`                       | `:9428` (全 IF、firewall で絞る)    | loopback + Tailnet                   | なし (Tailnet ACL に委譲)   |
| VictoriaMetrics | `host`                       | `:8428` (同上)                      | loopback + Tailnet                   | なし (同上)                 |
| Alloy           | `host`                       | `127.0.0.1:12345` (内部 HTTP UI)    | loopback のみ                        | なし                        |
| Grafana (本体)  | `container:grafana-ts`       | `127.0.0.1:3000` (サイドカー ns 内) | サイドカー ns 内のみ                 | Grafana 内蔵 admin          |
| grafana-ts      | 通常 (bridge) + userspace TS | TS Serve 443                        | Tailnet (`grafana.<tailnet>.ts.net`) | Tailnet ACL + Grafana admin |

### 露出制御

ホスト側で firewall を設定:

```nix
# hosts/oci/configuration.nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 ];           # 既存
  trustedInterfaces = [ "tailscale0" ]; # 追加
};
```

これにより VL (:9428) / VM (:8428) は `tailscale0` と `lo` からのみ到達可能。eth0 (公衆インターフェース) からは届かない。

### Grafana → VL/VM の経路

Grafana は `container:grafana-ts` で namespace を共有するが、grafana-ts は `TS_USERSPACE=true` でユーザースペース Tailscale を使うため、コンテナ ns 内には実 `tailscale0` は無い。Grafana がホスト上の VL/VM に届くには Podman 標準の **`host.containers.internal`** DNS (コンテナから見たホスト IP、通常 `10.88.0.1` 等のブリッジ IP) を使う:

- datasource URL: `http://host.containers.internal:9428` / `http://host.containers.internal:8428`
- 前提: VL/VM が `network_mode=host` でホスト全 IF に bind していること (上記の `:9428` / `:8428` 構成)
- 前提: Podman の `host.containers.internal` が解決可能であること (Podman 4.x 以降デフォルト有効、OCI NixOS の podman バージョンを実装時確認)

### Alloy → VL/VM / ホスト node メトリクス

Alloy 自身は `network_mode=host` のためホストの loopback 越しにすべて到達可能:

- VL push: `http://127.0.0.1:9428/insert/loki/api/v1/push`
- VM push: `http://127.0.0.1:8428/api/v1/write`
- ホスト node メトリクス: `prometheus.exporter.unix` が Alloy プロセス内で生成する targets を `prometheus.scrape` で拾う (実体的にはプロセス内 API、ネットワーク経由しない)
- Alloy self metrics: `http://127.0.0.1:12345/metrics` を self-scrape

---

## 実装詳細

### VictoriaLogs

- image: `docker.io/victoriametrics/victoria-logs:latest`
- `network_mode=host`
- コマンド引数:
  - `-storageDataPath=/storage`
  - `-retentionPeriod=30d`
  - `--retention.maxDiskSpaceUsageBytes=15GB`
  - `-httpListenAddr=:9428`
- volume: `victorialogs-data:/storage`
- 露出制御はホスト firewall の `trustedInterfaces = [ "tailscale0" ]` に委譲
- LogDriver=journald, Restart=always

### VictoriaMetrics

- image: `docker.io/victoriametrics/victoria-metrics:latest`
- `network_mode=host`
- コマンド引数:
  - `-storageDataPath=/storage`
  - `-retentionPeriod=90d`
  - `-httpListenAddr=:8428`
- volume: `victoriametrics-data:/storage`
- 露出制御はホスト firewall に委譲 (VL と同様)
- LogDriver=journald, Restart=always
- 注: VM のディスク予算 10 GB は運用上の上限。VM には `maxDiskSpaceUsageBytes` 相当の強制上限オプションは無いため、retention 90d と書き込みレートで事実上抑え、超過傾向を Grafana で監視する

### Alloy

- image: `docker.io/grafana/alloy:latest`
- `network_mode=host`
- コマンド引数: `run --server.http.listen-addr=127.0.0.1:12345 /etc/alloy/config.alloy`
- volumes:
  - `${./config.alloy}:/etc/alloy/config.alloy:ro` (store path 経由)
  - `/var/log/journal:/var/log/journal:ro` (journald read)
  - `/etc/machine-id:/etc/machine-id:ro` (journald 必須)
  - `adguard-home-data:/var/log/adguard:ro` (M4 先取り。M1 時点では file source 無効。querylog.json は `/var/log/adguard/querylog.json` で見える)
  - `alloy-data:/var/lib/alloy` (positions 永続化)
- `SYSTEMD_UNIT` などを拾うため `/run/systemd/journal/stdout` は journald の unix socket ではなく journal file 読み取りで対応 (`/var/log/journal` ro マウント)

### `alloy/config.alloy` 骨子

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

// --- AdGuard querylog (M4 で有効化。M1 ではコメントアウト) ---
// loki.source.file "adguard_querylog" {
//   targets    = [{ __path__ = "/var/log/adguard/querylog.json", service = "adguard-home" }]
//   forward_to = [loki.write.vl.receiver]
// }

// --- metrics: host node (Alloy 内蔵 unix exporter) ---
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

既存サービス (`vaultwarden` / `gatus` / `adguard-home`) の `/metrics` scrape は M2 で改修 + 追加する。M1 の `config.alloy` には該当ブロックを置かない。

### Grafana

- image: `docker.io/grafana/grafana:latest`
- volumes:
  - `grafana-data:/var/lib/grafana` (SQLite 永続化)
  - `${./provisioning}:/etc/grafana/provisioning:ro`
- environmentFiles: `config.sops.templates."grafana.env".path`
- networks: `[ "container:grafana-ts" ]` (Tailscale サイドカー経由)
- unitConfig: `Requires=[ "grafana-ts.service" ]; After=[ "grafana-ts.service" ];`
- healthCmd: `wget --spider -q http://127.0.0.1:3000/api/health || exit 1`

### grafana-ts (Tailscale サイドカー)

既存 `vaultwarden-ts` パターンを踏襲。`TS_HOSTNAME=grafana`、`TS_SERVE_CONFIG` で `:443 HTTPS → http://127.0.0.1:3000` をプロキシ。

### Grafana provisioning

`datasources/victorialogs.yaml`:

```yaml
apiVersion: 1
datasources:
  - name: VictoriaLogs
    type: victoriametrics-logs-datasource
    access: proxy
    url: http://host.containers.internal:9428
    isDefault: false
```

`datasources/victoriametrics.yaml`:

```yaml
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    type: prometheus
    access: proxy
    url: http://host.containers.internal:8428
    isDefault: true
```

`dashboards/dashboards.yaml`:

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

### `dashboards/homelab-overview.json`

Grafana ダッシュボード JSON。panel 3 枚:

| Panel                    | 種別               | Datasource      | Query                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------ | ------------------ | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Host resources        | time series (4 行) | VictoriaMetrics | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` (CPU 使用率) / `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` (RAM) / `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100` (Disk) / `rate(node_network_receive_bytes_total[5m])` (Net RX) |
| 2. Scrape targets up     | stat table         | VictoriaMetrics | `up` (M1 時点では `job=node` と `job=alloy` の 2 行のみ表示。M2 でサービス /metrics 追加後に自動的に行が増える)                                                                                                                                                                                                                                          |
| 3. Log volume by service | time series (area) | VictoriaLogs    | LogsQL: `* \| stats by (service) count()` を 5m レンジで評価                                                                                                                                                                                                                                                                                             |

JSON 本体は実装時に Grafana UI で組み、エクスポートして provisioning 配下にコミット。以降は JSON ファイルを真としメンテする。

---

## M4 先取り: AdGuard querylog ro マウント

`services/adguard-home/nixos.nix` は変更せず、`services/observability/alloy/nixos.nix` の alloy コンテナに既存 volume `adguard-home-data` を `/var/log/adguard` に `:ro` でマウントする (querylog.json の実体は `adguard-home-data:/opt/adguardhome/work/data/querylog.json`、Alloy から見たパスは `/var/log/adguard/querylog.json`)。これにより AdGuard 本体の quadlet 定義は不変、Alloy 側の変更だけで M4 切替が完結する。

`loki.source.file` ブロックは M1 では `config.alloy` にコメントアウトで残し、M4 でコメント解除 + fluent-bit 関連 Quadlet 削除を単一 PR で実施する。

ro マウントの副作用: AdGuard コンテナは `adguard-home-data` を rw マウントし続け、Alloy は同一 volume を ro マウントする。複数マウントは Podman / Quadlet で許容される。ただし Alloy コンテナ起動前に AdGuard が初回起動していて querylog.json が生成済みである必要は無く、`loki.source.file` が有効化された時点 (M4) でファイル存在を確認すればよい。

---

## Secrets / sops

`services/observability/secrets.yaml`:

```yaml
grafana:
  admin_password: ENC[...]
grafana_ts:
  ts_authkey: ENC[...]
```

- `grafana/admin_password` — 強パスワード (20 char 以上、記号含む)。ローテーション手順は `services/observability/README.md` に記載
- `grafana_ts/ts_authkey` — Tailscale admin console で `grafana` タグ付き reusable authkey を発行

sops の age recipient は既存 OCI ホストのものを流用。

---

## デプロイ / 検証手順

### ブランチ / PR

- spec PR: `docs/obs-m1-spec` → `main` (本 spec 先行 merge)
- 実装 PR: `feat/obs/m1-foundation` → `feat/obs/main`
- 実装後の OCI デプロイは `feat/obs/main` HEAD から `just oci-deploy`

### 実装順序 (単一 PR 内のコミット分割)

1. `feat(oci): firewall trustedInterfaces に tailscale0 追加`
2. `feat(observability): umbrella skeleton + secrets.yaml`
3. `feat(observability): VictoriaLogs quadlet-nix (network_mode=host)`
4. `feat(observability): VictoriaMetrics quadlet-nix (network_mode=host)`
5. `feat(observability): Alloy quadlet-nix + config.alloy (host node + self scrape)`
6. `feat(observability): Grafana + TS sidecar + provisioning (host.containers.internal datasource)`
7. `feat(observability): homelab-overview dashboard`
8. `feat(observability): adguard-home-data ro マウント (M4 先取り)`
9. `docs(spec): roadmap M1 done 定義 ② を host メトリクスに amend`
10. `docs(adr): ADR-011 200GB→100GB 訂正 + retention 決定値追記`
11. `docs: AGENTS.md / log-strategy.md / 各 README 更新`

コミット 3-6 は個別に `just oci-deploy` で段階検証可能だが、PR としては全部入り後 1 本にまとめる。

### 検証 (OCI 上、`just oci-deploy` 完了後)

```bash
# 1. ユニット稼働 (5 ユニットが active)
just oci-status | grep -E 'alloy|victorialogs|victoriametrics|grafana'

# 2. VL 疎通 (journald が入っている)
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode "query=_time:5m" | head -5'

# 3. VM 疎通 (up メトリクス — node + alloy の 2 行想定)
just oci-ssh 'curl -sG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode "query=up" | jq ".data.result | length"'
# 期待値: 2 (node + alloy)

# 4. Tailnet 経由で push endpoint が開いているか (M3 先取り確認)
curl -sG http://<oci-tailnet-ip>:9428/ping   # からのマシンから叩く
curl -sG http://<oci-tailnet-ip>:8428/health

# 5. Grafana UI
# ブラウザで https://grafana.<tailnet>.ts.net/d/homelab-overview
#   - Host resources panel に CPU/RAM/Disk/Net の値が出ている
#   - Scrape targets up panel に node / alloy の 2 行
#   - Log volume by service panel に journald 由来のサービス別カウント
```

5 点通過で done 定義充足。

### ロールバック

`just oci-rollback` で nixos generation を 1 つ戻す。5 ユニット + AdGuard の ro マウントが全て消え、既存 3 サービスは無影響 (状態共有なし)。

---

## Documentation-Code Coupling

| ファイル                                                                               | 更新内容                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/superpowers/specs/2026-04-15-observability-implementation-roadmap.md`            | M1 done 定義 ② を `vaultwarden / gatus / adguard-home の up` → `ホスト node + Alloy self の up` に amend。サービス /metrics は M2 scope 化の旨を追記                                                                            |
| `AGENTS.md`                                                                            | 技術スタック表の「観測スタック」行を `(Phase 2 / 計画中)` → `(Phase 2 / OCI 稼働中、リモート Alloy は M3)` に更新。サービス一覧に `services/observability/README.md` 追記。Justfile 操作表に `just observability <recipe>` 追加 |
| `docs/design-docs/patterns/log-strategy.md`                                            | Phase 2 図を「現状」セクションへ格上げ。fluent-bit サイドカー経路は「M4 で撤去予定」の注記付きで図を残す                                                                                                                        |
| `docs/design-docs/adr/011-metrics-backend-victoriametrics.md`                          | 「波及する未決事項」の `OCI 200 GB` を `OCI 100 GB` に訂正。Consequences に「M1 spec で retention 90d / 10 GB、VL は 30d / 15 GB に確定」を追記                                                                                 |
| `hosts/oci/configuration.nix`                                                          | `networking.firewall.trustedInterfaces = [ "tailscale0" ]` 追加。必要なら `services.journald.extraConfig` に `Storage=persistent` 追記                                                                                          |
| `services/observability/README.md` (新規)                                              | スタック概要、構成図、quick start (deploy / status / log / rollback)、secrets ローテーション手順                                                                                                                                |
| `services/observability/{alloy,victorialogs,victoriametrics,grafana}/README.md` (新規) | 各コンポーネントの役割・主要設定・トラブルシュート                                                                                                                                                                              |
| ルート `Justfile`                                                                      | `mod observability` 追加、`just observability <recipe>` を有効化                                                                                                                                                                |

Grafana ダッシュボード JSON は `services/observability/grafana/provisioning/dashboards/homelab-overview.json` で git 管理。provisioning 経由で自動復元される前提。

---

## Done 定義

- [ ] `just oci-status` に `alloy`, `victorialogs`, `victoriametrics`, `grafana`, `grafana-ts` の 5 ユニットが `active (running)` で表示
- [ ] VictoriaLogs に journald ログが到達し、Grafana 上で LogsQL クエリが引ける
- [ ] VictoriaMetrics に **ホスト node メトリクス (job=node) と Alloy self メトリクス (job=alloy)** が到達し、Grafana 上で PromQL クエリが引ける
- [ ] `homelab-overview` ダッシュボードの 3 panel 全てに実データが描画
- [ ] AdGuard の `adguard-home-data` volume が Alloy コンテナに `/var/log/adguard:ro` でマウント済み (M4 切替のため)
- [ ] Tailnet 経由で別マシンから `http://<oci-tailnet-ip>:9428/ping` と `:8428/health` が返る (M3 先取り確認)
- [ ] eth0 (公衆 IF) から `:9428` / `:8428` は届かない (firewall 動作確認)
- [ ] ロードマップ spec の M1 done 定義 ② が amend 済み (本 PR 内)
- [ ] AGENTS.md / log-strategy.md / ADR-011 / 新規 README が反映済み
- [ ] Grafana admin パスワードと TS authkey が sops 管理
- [ ] 観測スタック合計ディスク使用量が 25 GB 以下 (デプロイ直後)

---

## 前提 (spec 外で満たされていること)

- PR #10 (ADR-007/008/010/011) が main に merge 済み
- PR #11 (ロードマップ spec) が main に merge 済み
- ADR-009 (quadlet-nix 統一) が OCI 3 サービスで完了済み
- OCI NixOS ホストが稼働中、`services.tailscale.enable = true` で Tailnet 参加済み
- OCI ホストの Podman バージョンが `host.containers.internal` をサポート (Podman 4.1 以降、NixOS 24.11 系は満たす想定)
- `feat/obs/main` ブランチが remote に作成されている

---

## リスク / 未決事項 (M1 実装中に確認すべき点)

| 項目                                                              | 対応                                                                                                                                                                                                      |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `networking.firewall.trustedInterfaces = [ "tailscale0" ]` 未設定 | 実装時に `hosts/oci/configuration.nix` を確認し、無ければ本 PR で追加。既存サービスは影響なし (tailscale0 経由のトラフィックは現行でも許可されている想定)                                                 |
| Podman `host.containers.internal` の解決可否                      | Grafana コンテナ内から `getent hosts host.containers.internal` で確認。Podman バージョンが古ければ `networkMode = "pasta"` 等の代替設定 / 明示的 extra_hosts を検討                                       |
| Grafana の VictoriaLogs datasource plugin                         | `victoriametrics-logs-datasource` を `GF_INSTALL_PLUGINS` で注入するか、同梱済みイメージを使うか実装時判断                                                                                                |
| journald の `/var/log/journal` 永続化                             | 現状 `services.journald.extraConfig` に `Storage=persistent` 明示が無い場合、Alloy が読むログが volatile (`/run/log/journal`) になる可能性。実装時に確認し、必要なら `hosts/oci/configuration.nix` に追加 |
| VM のディスク強制上限オプション不在                               | 運用上 10 GB を超える兆候が出たら retention を短縮。監視ルール化は M5 で vmalert に載せる                                                                                                                 |
| `network_mode=host` での Quadlet 記法                             | quadlet-nix では `containerConfig.networks = [ "host" ]` もしくは `containerConfig.network = "host"` で指定。実装時に SEIAROTg/quadlet-nix のマッピング確認                                               |
| ro マウントされた querylog への複数コンテナ同時アクセス           | AdGuard (rw) + Alloy (ro) の同時マウントは Podman で許容される。rotation は AdGuard 側で制御、Alloy は inotify/tail で追随。M4 実装時に file source 有効化後の追随挙動を検証                              |

---

## Phase 2 内での位置付け

M1 完了後の依存:

- **M4** (fluent-bit 撤去): M1 で Alloy に仕込んだ ro マウントを活かし、`config.alloy` のコメント解除 + fluent-bit Quadlet 削除のみで完結
- **M2** (ダッシュボード整備): `homelab-overview` の provisioning 基盤をそのまま拡張
- **M3** (リモート Alloy): M1 の VL/VM push エンドポイント (Tailnet bind) が前提
- **M5** (vmalert): M1 の VM に接続してルール評価

M1 PR が `feat/obs/main` に merge された時点で、M4 の spec 作成をトリガする (roadmap の M spec 作成タイミング表に従う)。
