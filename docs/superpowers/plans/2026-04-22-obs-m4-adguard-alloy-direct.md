# Observability M4 — AdGuard fluent-bit サイドカー撤去 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M1 で仕込んだ Alloy の `loki.source.file` を有効化して AdGuard `querylog.json` を直接 tail させ、同時に `adguard-home-querylog` (fluent-bit) サイドカーを NixOS 定義から撤去して、ログ経路を 2 ホップから 1 ホップに縮める。

**Architecture:** Alloy コンテナには M1 で `adguard-home-data:/var/log/adguard:ro` が既にマウント済み。`services/observability/alloy/config.alloy` のコメントアウト済みブロックをアンコメントして `host = "oci-nix"` ラベルを追加する。`services/adguard-home/nixos.nix` から `fluentBitConf` / `parsersConf` の `let` バインディングと `adguard-home-querylog` コンテナ定義を削除する。tail 位置永続化は `alloy-data:/var/lib/alloy` に自動保存される positions ファイルで担保（K-007 等価）。

**Tech Stack:** NixOS, quadlet-nix, Podman, Grafana Alloy (River DSL), `loki.source.file`, VictoriaLogs

**Spec:** `docs/superpowers/specs/2026-04-16-obs-m4-adguard-alloy-direct-design.md`

**Branch:** `feat/obs/m4-adguard-alloy-direct` → `feat/obs/main`

---

## ファイルマップ

### 変更

| ファイル                                              | 変更内容                                                                                                          |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `services/observability/alloy/config.alloy`           | `loki.source.file "adguard_querylog"` ブロックをアンコメント、`host = "oci-nix"` ラベル追加                       |
| `services/adguard-home/nixos.nix`                     | `let` ブロックの `fluentBitConf` / `parsersConf` バインディング削除、`adguard-home-querylog` コンテナ定義全体削除 |
| `services/adguard-home/README.md`                     | 構成表から `adguard-home-querylog` 行削除、ログ設計セクションを Alloy 直読みに書き換え                            |
| `docs/design-docs/adr/008-alloy-unified-collector.md` | 移行手順 step 3 にチェック済みマーク・M4 PR 参照追記                                                              |

### 新規作成

なし。

### 手動操作 (OCI ホスト)

- デプロイ後、`adguard-home-querylog-state` volume を `podman volume rm` で削除 (仕様 §3)

---

## 実装順序の根拠

spec の commit 分割案に従い、ロールアウト中のログ欠損を避けるために次の順序で進める。

1. **Alloy 側の file source を先に有効化** — Alloy と fluent-bit の両経路が一時的に並走する。service ラベルが異なる (`service=adguard-home` vs `service=adguard-home-querylog.service`) ため重複保存にはならず、querylog データは常に VL に到達する。
2. **fluent-bit 撤去** — Alloy 側で querylog 到達を確認した後に fluent-bit コンテナを削除する。
3. **ドキュメント更新** — コード変更完了後にまとめて反映 (ADR-008 と README)。

Alloy を後回しにすると、fluent-bit 撤去〜Alloy 有効化の間にログ欠損期間が生じるため避ける。

---

## Task 1: config.alloy で adguard querylog file source を有効化

**Files:**

- Modify: `services/observability/alloy/config.alloy:21-25`

- [ ] **Step 1: config.alloy のコメントアウトブロックをアンコメントして host ラベルを追加**

`services/observability/alloy/config.alloy` の 21-25 行を以下に置き換える。

```alloy
// --- AdGuard querylog (M4 activation) ---
loki.source.file "adguard_querylog" {
  targets    = [{ __path__ = "/var/log/adguard/querylog.json", service = "adguard-home", host = "oci-nix" }]
  forward_to = [loki.write.vl.receiver]
}
```

変更点は 2 点:

- 先頭の `// ` を外して River 構文として有効化
- `targets` の map に `host = "oci-nix"` を追加 (journald source と揃える)

- [ ] **Step 2: NixOS build で構文エラーがないこと確認**

Run: `just oci-build`
Expected: エラーなく build tree が生成される (`result` symlink)。config.alloy は NixOS 側では文字列としてコピーされるだけなので構文チェックは deploy 後の Alloy 起動時に行われる。

- [ ] **Step 3: OCI にデプロイ**

Run: `just oci-deploy`
Expected: `systemctl restart alloy.service` 相当が実行され、alloy が新 config で再起動。

- [ ] **Step 4: Alloy ユニットが healthy であること確認**

Run:

```bash
just oci-ssh 'systemctl is-active alloy.service'
just oci-ssh 'podman healthcheck run alloy || echo "healthcheck failed"'
```

Expected: `active`、healthcheck exit 0 (エラー出力なし)。

- [ ] **Step 5: Alloy が config を pick up していること確認**

Run:

```bash
just oci-ssh 'journalctl -u alloy.service -n 30 --no-pager | grep -iE "(source.file|adguard|error|panic)"'
```

Expected: `adguard_querylog` component が起動したログがある、`error` / `panic` なし。

- [ ] **Step 6: Alloy が positions ファイルを作成していること確認**

Run:

```bash
just oci-ssh 'podman exec alloy ls -la /var/lib/alloy/ | head -20'
```

Expected: `positions.yml` またはディレクトリが `/var/lib/alloy/` 配下に存在 (Alloy 起動から数秒内に生成)。初回 tail 中なのでファイルが空の場合もあり、その場合は次 step で再確認。

- [ ] **Step 7: VictoriaLogs で service=adguard-home のログが到達していること確認**

Run:

```bash
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode "query=service:\"adguard-home\" _time:5m" | head -5'
```

Expected: querylog.json 由来の行 (JSON 文字列) が 1 行以上返る。DNS クエリが発生していない場合は `dig @<AdGuard IP> example.com` を別 shell で叩いて querylog を誘発する。

- [ ] **Step 8: 既存の fluent-bit 経路も並走していること確認 (データ欠損なし)**

Run:

```bash
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode "query=service:\"adguard-home-querylog.service\" _time:5m" | head -5'
```

Expected: fluent-bit 由来の行も並行して到達している (この Task 完了時点では撤去前のため)。これは Task 3 完了後に消える。

- [ ] **Step 9: 変更をステージして commit**

```bash
git add services/observability/alloy/config.alloy
git commit -m "$(cat <<'EOF'
feat(observability): Alloy config.alloy で adguard querylog file source を有効化

M1 で仕込んだコメントアウト済みブロックをアンコメントし、
journald source と整合する host="oci-nix" ラベルを付与する。
adguard-home-data:/var/log/adguard:ro マウントは M1 時点で設定済み。
tail 位置永続化は alloy-data:/var/lib/alloy の positions ファイルに委ねる。

Refs: docs/superpowers/specs/2026-04-16-obs-m4-adguard-alloy-direct-design.md
EOF
)"
```

---

## Task 2: adguard-home/nixos.nix から fluent-bit 定義を削除

**Files:**

- Modify: `services/adguard-home/nixos.nix:27-56` (`let` バインディング 2 つ)
- Modify: `services/adguard-home/nixos.nix:134-157` (`adguard-home-querylog` コンテナ定義)

- [ ] **Step 1: `let` ブロックから `fluentBitConf` バインディングを削除**

削除対象 (行 27-47):

```nix
  fluentBitConf = pkgs.writeText "adguard-home-fluent-bit.conf" ''
    [SERVICE]
        Flush        5
        Log_Level    warn
        Daemon       off
        Parsers_File /fluent-bit/etc/parsers.conf

    [INPUT]
        Name         tail
        Path         /data/querylog.json
        Tag          adguard.querylog
        Parser       json
        DB           /state/tail-pos.db
        Refresh_Interval 10
        Read_from_Head false

    [OUTPUT]
        Name         stdout
        Match        *
        Format       json_lines
  '';
```

- [ ] **Step 2: `let` ブロックから `parsersConf` バインディングを削除**

削除対象 (行 49-56):

```nix
  parsersConf = pkgs.writeText "adguard-home-parsers.conf" ''
    [PARSER]
        Name         json
        Format       json
        Time_Key     T
        Time_Format  %Y-%m-%dT%H:%M:%S.%L%z
        Time_Keep    On
  '';
```

削除後、`let` ブロックには `serveJson` と `adguardConfig` のみが残る。

- [ ] **Step 3: `virtualisation.quadlet.containers.adguard-home-querylog` 定義全体を削除**

削除対象 (行 134-157、コメント「# Fluent-bit querylog sidecar」を含む):

```nix
    # Fluent-bit querylog sidecar
    adguard-home-querylog = {
      autoStart = true;
      containerConfig = {
        image = "ghcr.io/fluent/fluent-bit:latest";
        volumes = [
          "adguard-home-data:/data:ro"
          "adguard-home-querylog-state:/state"
          "${fluentBitConf}:/fluent-bit/etc/fluent-bit.conf:ro"
          "${parsersConf}:/fluent-bit/etc/parsers.conf:ro"
        ];
        exec = [
          "/fluent-bit/bin/fluent-bit"
          "-c"
          "/fluent-bit/etc/fluent-bit.conf"
        ];
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "adguard-home.service" ];
        After = [ "adguard-home.service" ];
      };
      serviceConfig.Restart = "always";
    };
```

削除後、`virtualisation.quadlet.containers` には `adguard-home-ts` と `adguard-home` の 2 コンテナのみが残る。

- [ ] **Step 4: NixOS build で構文エラー・未定義参照なしを確認**

Run: `just oci-build`
Expected: エラーなく build 成功。`fluentBitConf` / `parsersConf` の参照が残っていれば "undefined variable" エラーになるので検知できる。

- [ ] **Step 5: OCI にデプロイ**

Run: `just oci-deploy`
Expected: `adguard-home-querylog.service` ユニットファイル (`/etc/containers/systemd/adguard-home-querylog.container` 相当) が削除され、systemd daemon-reload 後にユニットが停止される。

- [ ] **Step 6: fluent-bit ユニットが消えていること確認 (spec 検証 1)**

Run:

```bash
just oci-ssh 'systemctl list-units --type=service --all | grep -i querylog'
```

Expected: 出力なし。

- [ ] **Step 7: adguard-home / adguard-home-ts が健全に稼働継続していること確認**

Run:

```bash
just oci-status
```

Expected: `adguard-home.service`, `adguard-home-ts.service`, および observability 5 ユニット (alloy, victorialogs, victoriametrics, grafana, grafana-ts) が `active (running)`。

- [ ] **Step 8: Alloy が querylog を依然として読めていること確認 (spec 検証 2)**

Run:

```bash
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode "query=service:\"adguard-home\" _time:5m" | head -5'
```

Expected: querylog 由来のログが引き続き到達 (Task 1 で確認した経路が生きている)。

必要なら別 shell から DNS クエリを発行して新規ログを誘発:

```bash
dig @<oci-tailscale-ip> example.com
```

- [ ] **Step 9: Alloy positions ファイルに adguard エントリが記録されていること確認 (spec 検証 3, K-007 等価性)**

Run:

```bash
just oci-ssh 'podman exec alloy find /var/lib/alloy -name "*.yml" -o -name "*positions*" 2>/dev/null | head -5'
just oci-ssh 'podman exec alloy sh -c "cat /var/lib/alloy/loki.source.file.adguard_querylog/positions.yml 2>/dev/null || find /var/lib/alloy -name positions.yml -exec cat {} \;"'
```

Expected: `querylog.json` の path と offset が記録された YAML が出力される。Alloy のバージョンによって厳密パスは異なる可能性があるため、`find` 側の出力でパスを特定してから `cat` する。

- [ ] **Step 10: fluent-bit 残骸 volume `adguard-home-querylog-state` を削除 (spec §3)**

Run:

```bash
just oci-ssh 'podman volume ls | grep querylog-state'
just oci-ssh 'podman volume rm adguard-home-querylog-state'
just oci-ssh 'podman volume ls | grep querylog-state'
```

Expected: 1 回目の `ls` で volume が listing される、`rm` 成功、2 回目の `ls` で空。

- [ ] **Step 11: 変更をステージして commit**

```bash
git add services/adguard-home/nixos.nix
git commit -m "$(cat <<'EOF'
feat(adguard-home): fluent-bit サイドカー (adguard-home-querylog) を削除

ADR-008 (Alloy 一元化) の移行手順 step 3 に相当する実装。
querylog.json の tail は M4 で有効化した Alloy の loki.source.file に
一元化され、fluent-bit サイドカーは不要になる。

- let ブロックの fluentBitConf / parsersConf バインディング削除
- adguard-home-querylog コンテナ定義削除
- adguard-home-querylog-state volume は OCI 上で手動削除済み

K-007 (tail 位置永続化) は Alloy の positions ファイルで等価維持。

Refs: docs/superpowers/specs/2026-04-16-obs-m4-adguard-alloy-direct-design.md
EOF
)"
```

---

## Task 3: adguard-home README の fluent-bit 記述削除

**Files:**

- Modify: `services/adguard-home/README.md:5-44` (構成表・ネットワーク設計・ログ設計)

- [ ] **Step 1: 構成表から `adguard-home-querylog` 行を削除**

`services/adguard-home/README.md` の「## 構成」セクション (行 5-12) を以下に置き換える。

```markdown
## 構成

| コンポーネント    | 役割                                                   |
| ----------------- | ------------------------------------------------------ |
| `adguard-home`    | AdGuard Home 本体（DNS + Web UI）                      |
| `adguard-home-ts` | Tailscale サイドカー（Web UI を Tailscale Serve 公開） |
```

- [ ] **Step 2: 「### ログ設計」セクション (行 25-43) を Alloy 直読みに書き換え**

元の記述 (fluent-bit 経由 journald) を以下で置換:

```markdown
### ログ設計

AdGuard Home のアプリケーションログはコンテナ stdout から journald に流れ、OCI ホストの Alloy が journald source で拾って VictoriaLogs に送る。クエリログ (`querylog.json`) は共有 volume `adguard-home-data` を Alloy コンテナに read-only でマウントし、Alloy の `loki.source.file` が直接 tail して VictoriaLogs に送る。
```

adguard-home → stdout → journald → Alloy (journal source) → VictoriaLogs
adguard-home → querylog.json → adguard-home-data (ro mount) → Alloy (loki.source.file) → VictoriaLogs

```

VictoriaLogs 上では `service` ラベルでフィルタする:

| 種別                 | service ラベル                   | 確認方法 (Grafana / LogsQL) |
| -------------------- | -------------------------------- | --------------------------- |
| アプリケーションログ | `adguard-home.service`           | journald 由来               |
| クエリログ           | `adguard-home`                   | Alloy file source 由来      |
```

旧「### ログ設計」セクションの下にあった systemd ユニット確認表はこの置換で消える。Justfile 経由のローカル確認コマンド記述 (`just adguard-home logs-*`) は「## 運用」セクションに残っているものを使う (別 scope)。

- [ ] **Step 3: 「## ファイル構成」の `fluent-bit/` 行を削除**

README 行 89-105 の「## ファイル構成」セクションから以下の行を削除:

```
├── fluent-bit/
│   ├── fluent-bit.conf                   # fluent-bit 設定（querylog tail → stdout）
│   └── parsers.conf                      # JSON パーサー定義
```

および `quadlet/` の中の以下の行を削除:

```
    ├── adguard-home-querylog.container   # fluent-bit サイドカー（クエリログ転送）
```

`quadlet/` ディレクトリ内の他ファイル (`adguard-home-data.volume`, `adguard-home-ts-state.volume`, テンプレート群) は legacy podman-user デプロイ用途で残置しているため、本 PR では削除しない。

> **Note:** `services/adguard-home/quadlet/adguard-home-querylog.container`, `services/adguard-home/quadlet/adguard-home-querylog-state.volume`, および `services/adguard-home/fluent-bit/` ディレクトリ自体はリポジトリに残ったままになる。これらは OCI NixOS 経路では参照されないが、ローカル podman 経路の Justfile (`just adguard-home deploy`) で参照されているため、別途 legacy クリーンアップ PR で処理する (M4 scope 外)。

- [ ] **Step 4: 変更をステージして commit**

```bash
git add services/adguard-home/README.md
git commit -m "$(cat <<'EOF'
docs(adguard-home): README から fluent-bit サイドカー記述を削除

M4 で fluent-bit サイドカーを撤去し querylog を Alloy 直読みに
切り替えたことに伴い、構成表・ログ設計・ファイル構成から
fluent-bit 関連記述を削除する。クエリログは Alloy の
loki.source.file 経由で VictoriaLogs の service=adguard-home
に到達する。

Refs: docs/superpowers/specs/2026-04-16-obs-m4-adguard-alloy-direct-design.md
EOF
)"
```

---

## Task 4: ADR-008 の移行手順チェック済み化

**Files:**

- Modify: `docs/design-docs/adr/008-alloy-unified-collector.md:71-77`

- [ ] **Step 1: 移行手順 step 3 にチェック済みマークを追加**

ADR-008 末尾の「### 移行手順（概略）」を以下に置き換える。

```markdown
### 移行手順（概略）

1. [x] Alloy の Quadlet / NixOS モジュールを整備し、journald source + 既存サービスのメトリクス scrape を動作確認 (M1 完了)
2. [ ] ダッシュボード・アラートを整備 (M2 / M5)
3. [x] AdGuard Home の `querylog.json` を Alloy 直読みに切り替え、fluent-bit サイドカー Quadlet を撤去 (M4 完了)
4. [ ] [log-strategy.md](../patterns/log-strategy.md) を本構成に書き換え、[ADR-006](006-adguard-querylog-fluent-bit-sidecar.md) を superseded として残す (log-strategy.md は M1 で格上げ済み、ADR-006 superseded も M1 で実施済み → 本項は close 可)
```

- [ ] **Step 2: 変更をステージして commit (Task 3 と同じ docs commit に含めるか別 commit にするかは任意。ここでは別 commit を採用)**

```bash
git add docs/design-docs/adr/008-alloy-unified-collector.md
git commit -m "$(cat <<'EOF'
docs(adr): ADR-008 移行手順に M4 完了マーク追記

step 3 (fluent-bit サイドカー撤去) を checked 状態に変更。
step 1 (M1 完了) と step 4 (log-strategy.md / ADR-006 は M1 で
既に処理済み) の状態も同時に反映する。

Refs: docs/superpowers/specs/2026-04-16-obs-m4-adguard-alloy-direct-design.md
EOF
)"
```

---

## Task 5: Done 定義に沿った最終確認

spec の「## Done 定義」と「## デプロイ / 検証手順」に対する最終スモークテスト。ここまでの Task で各項目は個別確認済みだが、単一のセッションでまとめて叩いて記録を残す。

- [ ] **Step 1: querylog が VictoriaLogs に到達 (Done 定義 1)**

Run:

```bash
just oci-ssh 'curl -sG http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode "query=service:\"adguard-home\" _time:10m" | wc -l'
```

Expected: 1 以上 (直近 10 分に querylog 行が存在)。

- [ ] **Step 2: fluent-bit ユニットが不在 (Done 定義 2)**

Run:

```bash
just oci-ssh 'systemctl list-units --type=service --all | grep -i querylog'
just oci-ssh 'ls /etc/containers/systemd/ | grep -i querylog'
```

Expected: 両コマンドとも出力なし。

- [ ] **Step 3: positions ファイル存在 (Done 定義 3)**

Run:

```bash
just oci-ssh 'podman exec alloy find /var/lib/alloy -name "positions.yml" -exec echo {} \; -exec cat {} \;'
```

Expected: `querylog.json` のパスと offset が YAML で出力される。

- [ ] **Step 4: 残骸 volume が不在 (Done 定義 4)**

Run:

```bash
just oci-ssh 'podman volume ls | grep querylog-state || echo "not found"'
```

Expected: `not found`。

- [ ] **Step 5: README / ADR が更新済み (Done 定義 5, 6)**

Run:

```bash
grep -c fluent-bit services/adguard-home/README.md
grep -nE '^\s*3\. \[x\]' docs/design-docs/adr/008-alloy-unified-collector.md
```

Expected: README の grep は `0`、ADR は step 3 の `[x]` マーク行を返す。

- [ ] **Step 6: Grafana homelab-overview で service=adguard-home のログボリュームが表示される (spec 検証 5)**

手動確認: ブラウザで Grafana (Tailscale Serve URL) → `homelab-overview` ダッシュボード → `Log volume by service` パネル。`adguard-home` が凡例に表示され、タイムシリーズが直近 10-30 分でゼロでないことを確認する。

Expected: `adguard-home` 系列が表示される。表示されない場合は LogsQL 側で直接叩いた service ラベル値 (`adguard-home`) とダッシュボードクエリのマッチ条件を突き合わせる。

- [ ] **Step 7: OCI 全ユニットが正常**

Run:

```bash
just oci-status
```

Expected: 稼働ユニット一覧 — `adguard-home` + `adguard-home-ts` + observability 5 (`alloy`, `victorialogs`, `victoriametrics`, `grafana`, `grafana-ts`) + `vaultwarden`, `gatus` など従来ユニット。`adguard-home-querylog` は出現しない。

---

## querylog.json ローテーション時の挙動観察 (spec リスク §2)

spec で指摘されている未決事項 ──「AdGuard Home は querylog.json を rename でローテートする。Alloy の inotify が新ファイル作成を検知できるか」── は M4 完了直後の verifiable task ではなく、本番運用中の観察事項。

- [ ] **Step 1: AdGuardHome.yaml の querylog 設定確認**

Run:

```bash
grep -nE 'querylog' services/adguard-home/AdGuardHome.yaml | head -20
```

Expected: `interval` 値 (保持期間、fluent-bit 時代から変更なしであること) と `enabled: true`、`file_enabled: true` を確認。

- [ ] **Step 2: Alloy ローテーション検知の監視ポイントを Issue にメモ**

ローテーション後に positions ファイルのオフセットがリセットされているか、Alloy ログに `file truncated` / `file rotated` 系メッセージが出るかは、次回 AdGuard がローテートするタイミングで確認する。GitHub Issue に観察タスクを起票し、M4 PR description に link する (任意、未発生なら skip 可)。

Issue タイトル案: "obs: AdGuard querylog.json ローテート時の Alloy loki.source.file 挙動を確認"

---

## ロールバック手順 (障害時)

本 PR が本番で問題を起こした場合の戻し方。

- [ ] **Rollback 1: NixOS 世代を前に戻す**

Run: `just oci-rollback`
Effect: 前世代の NixOS 定義 (fluent-bit サイドカー有 + config.alloy コメントアウト) に戻る。Alloy は loki.source.file を読まなくなり、fluent-bit が `adguard-home-querylog` として再起動する。

- [ ] **Rollback 2: 状態確認**

Run: `just oci-ssh 'systemctl list-units --type=service | grep -E "(adguard|alloy)"'`
Expected: `adguard-home-querylog.service` が `active` に戻っていること。

- [ ] **Rollback 3: volume 復旧**

fluent-bit サイドカーは初回起動時に `adguard-home-querylog-state` volume を自動作成するため、`podman volume rm` で削除済みでも自動再作成される。tail 位置 DB は新規作成されるため、querylog の先頭から再読込される (fluent-bit のデフォルト挙動、`Read_from_Head false` でも現行位置から追従)。

---

## PR 作成 (実装完了後)

- [ ] **Step 1: push して PR 作成**

```bash
git push -u origin feat/obs/m4-adguard-alloy-direct
gh pr create --base feat/obs/main --title "feat(observability): M4 AdGuard fluent-bit サイドカー撤去 + Alloy 直読み" --body "$(cat <<'EOF'
## Summary
- Alloy の `loki.source.file` で AdGuard `querylog.json` を直接 tail
- `adguard-home-querylog` (fluent-bit サイドカー) を NixOS 定義から撤去
- ログ経路を 2 ホップ (file→fluent-bit→journald→Alloy→VL) から 1 ホップ (file→Alloy→VL) に縮約
- ADR-008 移行手順 step 3 完了
- K-007 (tail 位置永続化) は Alloy の positions ファイルで等価維持

Spec: `docs/superpowers/specs/2026-04-16-obs-m4-adguard-alloy-direct-design.md`
Plan: `docs/superpowers/plans/2026-04-22-obs-m4-adguard-alloy-direct.md`

## Test plan
- [ ] `just oci-build` 成功
- [ ] `just oci-deploy` 成功
- [ ] VictoriaLogs で `service:"adguard-home"` の querylog が到達
- [ ] `adguard-home-querylog.service` がホスト上に存在しない
- [ ] Alloy positions ファイルに `querylog.json` のエントリあり
- [ ] `adguard-home-querylog-state` volume 削除済み
- [ ] Grafana homelab-overview の Log volume パネルで `adguard-home` 表示
EOF
)"
```

---

## 自己レビュー結果

- **Spec coverage**: 6 項目すべて Task にマップ済み
  - config.alloy uncomment → Task 1
  - nixos.nix コンテナ定義削除 → Task 2 Step 3
  - nixos.nix let バインディング削除 → Task 2 Step 1-2
  - K-007 等価性検証 → Task 2 Step 9 + Task 5 Step 3
  - README fluent-bit 記述削除 → Task 3
  - ADR-008 移行手順チェック → Task 4
- **Placeholder scan**: 「TBD」「TODO」「implement later」なし。全 step に実コマンド / 実コード記載済み
- **Type consistency**: `loki.source.file` のコンポーネント名 `adguard_querylog` は Task 1・Task 2・Task 5 で一貫。service ラベル値 `"adguard-home"` も全 Task で統一
- **out-of-scope の明示**: legacy `services/adguard-home/{quadlet,fluent-bit}/` ファイル群は Task 3 Step 3 で Note として明示し、別 PR の扱いに
