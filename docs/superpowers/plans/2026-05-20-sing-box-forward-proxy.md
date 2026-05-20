# sing-box forward proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OCI Ampere A1 (NixOS, aarch64) 上に sing-box を Tailscale sidecar 経由で常駐させ、Tailnet 内クライアントに SOCKS5 (1080) + HTTP CONNECT (8080) forward proxy を提供する。

**Architecture:** Podman Quadlet (Nix モード) で sing-box + Tailscale sidecar を同一 netns で起動。sing-box は sidecar の `tailscale0` 経由でのみ listen。outbound direct、DNS は AdGuard Home の Tailscale IP を upstream。

**Tech Stack:** sing-box, Podman Quadlet (quadlet-nix), Tailscale, NixOS, sops-nix, just

**Spec:** [`docs/superpowers/specs/2026-05-20-sing-box-forward-proxy-design.md`](../specs/2026-05-20-sing-box-forward-proxy-design.md)

**Related Issue:** [#21](https://github.com/afxnoize/nz-homelab-services/issues/21)

---

## 前提と注意

- 本 PR の merge target は `main`。worktree は `.worktrees/feat/sing-box-forward-proxy` で `feat/sing-box-forward-proxy` ブランチ
- spec で言及した `default.nix` / `config.nix` は、既存サービスの命名慣習に合わせて **`nixos.nix` 一本にまとめる** (gatus / vaultwarden / adguard-home と同パターン)。`config.nix` を分離する必要はない (config が短く、`nixos.nix` 内で `let` 束縛で済む)
- 既存サービスの `services/<name>/quadlet/` ディレクトリ (手書きモード残骸) は新規 sing-box では作らない。NixOS 専用 (OCI のみ) なので nixos.nix 経由で /etc/containers/systemd/ に配置される
- observability スタックは現時点で **main に未マージ** (`feat/obs/main` で進行中)。vmalert ルール追加 (Task 8) は observability が main に降りた後に取り込むため、本 PR では **保留** とし、別 PR / Issue を起こす
- treefmt lefthook により markdown table の余白を整える整形が自動で入る。commit 前に手動 format しなくても 1 回目失敗 → re-stage で通る

---

## File Structure

### 新規ファイル

```
services/sing-box/
├── nixos.nix              # NixOS module: sops.secrets + sops.templates + virtualisation.quadlet.containers
├── secrets.yaml           # sops 暗号化 (ts_authkey)
├── justfile               # OCI 操作の thin wrapper (status / logs / restart)
└── README.md              # サービス概要・運用手順

docs/
├── guides/
│   └── sing-box-client-setup.md      # クライアント設定ガイド (PAC / FoxyProxy / macOS / iOS / CLI)
└── design-docs/
    └── adr/
        └── 012-sing-box-forward-proxy.md  # ADR
```

### 既存ファイル変更

| ファイル                      | 変更内容                                                               |
| ----------------------------- | ---------------------------------------------------------------------- |
| `hosts/oci/configuration.nix` | `imports` に `../../services/sing-box/nixos.nix` を追加                |
| `justfile` (root)             | `mod sing-box 'services/sing-box'` を追加                              |
| `AGENTS.md`                   | 「機能概要」サービス一覧と「技術スタック」表に sing-box 行を追加       |
| `docs/design-docs/index.md`   | ADR-012 へのリンクを追加 (もし index にエントリ追加が慣習なら確認の上) |

---

## Task 1: 事前検証 (aarch64 image + 最小 config 動作確認)

**目的:** spec のリスク欄に挙げた「`ghcr.io/sagernet/sing-box` の aarch64 サポート」「最小 config で SOCKS5 と HTTP CONNECT が両方動くこと」を実機で確認する。コードを書く前に潰す。

**Files:**

- 作業はすべて OCI ホスト上の `/tmp/` で行い、リポジトリには何も add しない

- [ ] **Step 1: SSH で OCI に入って image manifest を確認**

```bash
just oci-ssh
# OCI 上で:
podman manifest inspect ghcr.io/sagernet/sing-box:latest 2>&1 | head -40
```

Expected: `"architecture": "arm64"` を含むエントリが返る。なければここで stop し、別 image (例: `docker.io/sagernet/sing-box`) や build from source を検討。

- [ ] **Step 2: 最小 config.json を OCI 上に置く**

OCI 上で:

```bash
mkdir -p /tmp/sing-box-test
cat > /tmp/sing-box-test/config.json <<'EOF'
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "socks", "tag": "socks-in", "listen": "0.0.0.0", "listen_port": 11080 },
    { "type": "http",  "tag": "http-in",  "listen": "0.0.0.0", "listen_port": 18080 }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF
```

ポートは本番衝突を避けて 11080 / 18080。

- [ ] **Step 3: 一時起動 (host network、後でクリーンアップ)**

```bash
podman run --rm --name sb-test --network host \
  -v /tmp/sing-box-test/config.json:/etc/sing-box/config.json:ro \
  ghcr.io/sagernet/sing-box:latest \
  -c /etc/sing-box/config.json run &
sleep 3
ss -tlnp | grep -E ':(11080|18080)'
```

Expected: 両ポートが listening 状態であること。

- [ ] **Step 4: ローカルから疎通**

OCI 上で (localhost からのテスト):

```bash
curl -x socks5h://127.0.0.1:11080 https://example.com -sS -o /dev/null -w '%{http_code}\n'
curl -x http://127.0.0.1:18080 https://example.com -sS -o /dev/null -w '%{http_code}\n'
```

Expected: 両方とも `200`。

- [ ] **Step 5: クリーンアップ**

```bash
podman stop sb-test 2>/dev/null || pkill -f sb-test || true
rm -rf /tmp/sing-box-test
```

- [ ] **Step 6: 結果を記録**

検証結果 (image arch / 起動成否 / 疎通成否) を Task 9 の README 執筆時に反映するためメモ。verified が確定したら **Task 2 へ進む**。verified しなかった場合は実装を止めて spec を改訂。

**No commit for this task** (リポジトリ変更なし)。

---

## Task 2: AdGuard の Tailscale IP / MagicDNS 名を確定

**目的:** sing-box の `dns.server` に何を書くかを実機で確定。

**Files:** (この段階では確定情報のメモのみ。次タスクで `nixos.nix` に反映)

- [ ] **Step 1: OCI 上で AdGuard コンテナの Tailscale IP を取得**

```bash
just oci-ssh
# OCI 上で:
podman exec -it systemd-adguard-home-ts tailscale ip -4 2>&1 || \
  podman exec -it adguard-home-ts tailscale ip -4
```

Expected: `100.x.x.x` 形式の Tailscale IP が返る (例: `100.64.1.2`)。これを記録。

- [ ] **Step 2: MagicDNS 名も控えておく**

```bash
# OCI 上で
tailscale status --json | jq -r '.Peer | to_entries[] | select(.value.HostName == "adguard-home") | "\(.value.DNSName)\(.value.TailscaleIPs[0])"'
```

Expected: `adguard-home.<tailnet>.ts.net.` のような MagicDNS 名と IP の対。

- [ ] **Step 3: 採用方針を決定**

採用は **IP リテラル** (例: `100.64.1.2`)。理由: 起動順に依存する DNS resolve を避ける (sing-box の起動時に MagicDNS が解決できない可能性を排除)。MagicDNS 名は将来の参考としてコードコメントに残す。

Tailscale IP は Tailscale ノードに対して安定 (再認証しても保持される) なので、変更時は手動更新でよい。

- [ ] **Step 4: 結果を記録**

確定した IP を Task 3 の `nixos.nix` で `adguardDnsHost` 変数として埋め込む。

**No commit for this task**。

---

## Task 3: services/sing-box/nixos.nix の作成

**目的:** Nix module で sops secret + Quadlet コンテナ定義を書く。

**Files:**

- Create: `services/sing-box/nixos.nix`
- Create: `services/sing-box/secrets.yaml` (空テンプレ。実 secret は Task 4 で sops で記入)

**参考:** `services/gatus/nixos.nix` を構造の手本にする。違いは Tailscale Serve を使わないこと、sing-box の config をテンプレートではなく `pkgs.writeText` で直接生成すること。

- [ ] **Step 1: `services/sing-box/secrets.yaml` を作成 (sops 化前のプレースホルダ)**

```bash
cat > services/sing-box/secrets.yaml <<'EOF'
ts_authkey: REPLACE_ME
EOF
```

この時点では平文。Task 4 で sops 暗号化する。

- [ ] **Step 2: `services/sing-box/nixos.nix` を書く**

`<ADGUARD_TS_IP>` は Task 2 で確定した IP リテラル (例: `100.64.1.2`) で置き換える。

```nix
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # AdGuard Home の Tailscale IP (Tailscale node の安定 IP)
  # 参考: MagicDNS 名は adguard-home.<tailnet>.ts.net だが、
  # 起動順依存を避けるため IP リテラルを採用 (ADR-012)
  adguardDnsHost = "<ADGUARD_TS_IP>";

  singBoxConfig = pkgs.writeText "sing-box-config.json" (
    builtins.toJSON {
      log = {
        level = "info";
        timestamp = true;
      };
      dns = {
        servers = [
          {
            tag = "adguard";
            address = adguardDnsHost;
          }
        ];
        final = "adguard";
      };
      inbounds = [
        {
          type = "socks";
          tag = "socks-in";
          listen = "0.0.0.0";
          listen_port = 1080;
        }
        {
          type = "http";
          tag = "http-in";
          listen = "0.0.0.0";
          listen_port = 8080;
        }
      ];
      outbounds = [
        {
          type = "direct";
          tag = "direct";
        }
      ];
      route = {
        final = "direct";
      };
    }
  );
in
{
  # sops secrets
  sops.secrets."sing-box/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "ts_authkey";
    restartUnits = [ "sing-box-ts.service" ];
  };

  # sops template: Tailscale env file
  sops.templates."sing-box-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."sing-box/ts_authkey"}
  '';

  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    sing-box-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
          TS_HOSTNAME = "sing-box";
          TS_STATE_DIR = "/var/lib/tailscale";
          TS_USERSPACE = "true";
        };
        environmentFiles = [
          config.sops.templates."sing-box-ts.env".path
        ];
        volumes = [
          "sing-box-ts-state:/var/lib/tailscale"
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

    # sing-box
    sing-box = {
      autoStart = true;
      containerConfig = {
        image = "ghcr.io/sagernet/sing-box:latest";
        networks = [ "container:sing-box-ts" ];
        volumes = [
          "${singBoxConfig}:/etc/sing-box/config.json:ro"
        ];
        exec = [
          "-c"
          "/etc/sing-box/config.json"
          "run"
        ];
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "sing-box-ts.service" ];
        After = [ "sing-box-ts.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };

  # Named volumes
  virtualisation.quadlet.volumes = {
    sing-box-ts-state = { };
  };
}
```

- [ ] **Step 3: `nix flake check` を走らせて評価が通ることを確認**

```bash
nix flake check 2>&1 | tail -30
```

Expected: エラーなし (sing-box.nixos.nix の Nix 評価エラーが出ないこと)。**この時点では configuration.nix に import していないので、評価対象に sing-box.nixos.nix は含まれない** → 次タスクで import 後に再評価する。

- [ ] **Step 4: commit (まだ secrets 未暗号化なので注意)**

`secrets.yaml` は **暗号化前の平文** なので、ここでは commit に**含めない**。`.gitignore` がなければ意図的に `git add` を services/sing-box/nixos.nix だけに絞る。

```bash
git status --short
git add services/sing-box/nixos.nix
git commit -m "feat(sing-box): NixOS Quadlet module を追加

services/sing-box/nixos.nix で sing-box + Tailscale sidecar を Nix モード
Quadlet として定義。inbound は SOCKS5 (1080) + HTTP CONNECT (8080)、
outbound は direct、DNS は AdGuard Home の Tailscale IP を upstream。

Refs: #21"
```

(secrets.yaml はステージしない)

---

## Task 4: secrets.yaml を sops で暗号化して ts_authkey を入れる

**目的:** Tailscale authkey を sops 暗号化された状態でコミット可能にする。

**Files:**

- Modify: `services/sing-box/secrets.yaml` (sops 暗号化)

- [ ] **Step 1: Tailscale admin console で sing-box 用 authkey を発行**

ブラウザで `https://login.tailscale.com/admin/settings/keys` を開き、authkey を発行 (reusable / preauthorized / ephemeral=false / タグ任意)。発行された `tskey-auth-...` をコピー。

- [ ] **Step 2: 既存サービスの sops 設定 (`.sops.yaml`) を確認**

```bash
cat .sops.yaml 2>&1
```

`services/.*/secrets\.yaml$` をカバーする規則があれば、`services/sing-box/secrets.yaml` も自動的に対象。なければ規則を追加してから次へ。

- [ ] **Step 3: secrets.yaml を sops で開いて暗号化保存**

`nix develop` シェル内で:

```bash
sops services/sing-box/secrets.yaml
```

エディタが開くので、`ts_authkey:` の値を `REPLACE_ME` から実 authkey に書き換えて保存。sops が age key で自動暗号化する。

- [ ] **Step 4: 暗号化を確認**

```bash
head -5 services/sing-box/secrets.yaml
```

Expected: `ENC[AES256_GCM,data:...]` 形式で値が暗号化されていること。`tskey-auth-` 文字列が平文で残っていない。

- [ ] **Step 5: commit**

```bash
git add services/sing-box/secrets.yaml
git commit -m "feat(sing-box): Tailscale authkey を sops で暗号化して追加

services/sing-box/secrets.yaml に ts_authkey (Tailscale 認証鍵) を
sops + age で暗号化して登録。"
```

---

## Task 5: hosts/oci/configuration.nix と root justfile に統合 + ビルド確認

**目的:** sing-box module を OCI ホストに組み込み、`just oci-build` が通ることを確認。

**Files:**

- Modify: `hosts/oci/configuration.nix`
- Modify: `justfile` (root)

- [ ] **Step 1: configuration.nix に import を追加**

`hosts/oci/configuration.nix:9-11` の imports リストに追加:

```nix
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
    ../../services/adguard-home/nixos.nix
    ../../services/vaultwarden/nixos.nix
    ../../services/gatus/nixos.nix
    ../../services/sing-box/nixos.nix
  ];
```

- [ ] **Step 2: root justfile に mod を追加**

`justfile:8` 付近 (既存 mod 群の最後) に追加:

```just
mod sing-box 'services/sing-box'
```

- [ ] **Step 3: `nix flake check` で評価**

```bash
nix flake check 2>&1 | tail -40
```

Expected: エラーなし (sing-box module も評価対象に含まれる)。

- [ ] **Step 4: `just oci-build` で NixOS ビルド確認**

```bash
just oci-build 2>&1 | tail -50
```

Expected: ビルド成功、最後に `building '/nix/store/.../oci-system.drv' ... successfully built` 系のログ。エラーがあれば nixos.nix の構文/オプション名を見直し。

- [ ] **Step 5: commit**

```bash
git add hosts/oci/configuration.nix justfile
git commit -m "feat(sing-box): OCI host に sing-box module を統合

hosts/oci/configuration.nix の imports に services/sing-box/nixos.nix を
追加し、ルート justfile に mod sing-box を登録。

Refs: #21"
```

---

## Task 6: OCI に deploy + 起動確認

**目的:** 実機に sing-box を載せて active 状態を確認する。

- [ ] **Step 1: `just oci-deploy` で実機反映**

```bash
just oci-deploy 2>&1 | tail -30
```

Expected: `activation finished successfully` 系のログ。エラーがあれば `just oci-rollback` で巻き戻す。

- [ ] **Step 2: OCI 上で systemctl status を確認**

```bash
just oci-status 2>&1 | grep -E 'sing-box'
```

Expected: `sing-box.service` と `sing-box-ts.service` の両方が `active (running)` で表示される。

- [ ] **Step 3: journalctl で起動ログを確認**

```bash
just oci-logs sing-box-ts 2>&1 | tail -30
just oci-logs sing-box 2>&1 | tail -30
```

Expected:

- `sing-box-ts`: Tailscale が起動し node 登録、`Online: true` で health check pass
- `sing-box`: `sing-box started` 系のログ、inbound 2 つが listen 開始 (1080 / 8080)

エラーがあれば config の syntax / exec オプションを見直し。

- [ ] **Step 4: Tailscale 管理画面で sing-box ノードを確認**

ブラウザで `https://login.tailscale.com/admin/machines` を開く。`sing-box` という hostname のノードが登録されていて、`Connected` 表示。

- [ ] **Step 5: OCI 内部から疎通の予備テスト**

```bash
just oci-ssh
# OCI 上で:
SBIP=$(podman exec -it systemd-sing-box-ts tailscale ip -4 | tr -d '\r')
echo "sing-box Tailscale IP: $SBIP"
curl -x socks5h://$SBIP:1080 https://example.com -sS -o /dev/null -w '%{http_code}\n'
curl -x http://$SBIP:8080 https://example.com -sS -o /dev/null -w '%{http_code}\n'
```

Expected: 両方とも `200`。失敗の場合は次タスクの leak / DNS テスト前に原因切り分け。

**No commit for this task** (デプロイ確認のみ)。

---

## Task 7: クライアント疎通 + AdGuard フィルタ + leak テスト

**目的:** Tailnet 上のクライアント (ローカル Mac) から SOCKS5 / HTTP CONNECT 両方で proxy が動くこと、AdGuard フィルタが効くこと、leak が起きないことを確認。

- [ ] **Step 1: Mac (ローカル) から SOCKS5 疎通**

```bash
curl -x socks5h://sing-box:1080 https://example.com -sS -o /dev/null -w '%{http_code}\n'
```

Expected: `200`。`sing-box` は MagicDNS で解決される (Tailscale 上に sing-box ノードが居る前提)。

- [ ] **Step 2: Mac から HTTP CONNECT 疎通**

```bash
curl -x http://sing-box:8080 https://example.com -sS -o /dev/null -w '%{http_code}\n'
```

Expected: `200`。

- [ ] **Step 3: AdGuard クエリログに proxy 経由のリクエストが記録されていることを確認**

ブラウザで AdGuard Home の Query Log を開き、過去 5 分のクエリに `example.com` (Step 1/2 で curl したドメイン) が記録されていることを確認。クライアント (源) は **sing-box ホストの Tailscale IP** または `sing-box.<tailnet>.ts.net` になるはず (proxy 経由で sing-box が代理 resolve するため)。

- [ ] **Step 4: AdGuard blocklist によるブロック確認**

AdGuard の Filtered domains に登録されている任意のドメイン (例: AdGuard デフォルトリストに含まれる広告ドメイン) を proxy 経由で叩く:

```bash
# Step 4-a: AdGuard でブロック対象になっているドメインを 1 つ特定 (AdGuard Web UI の Filter status から)
BLOCKED=<例: doubleclick.net>
curl -x socks5h://sing-box:1080 https://$BLOCKED -sS -o /dev/null -w '%{http_code}\n' -m 5 || echo "blocked"
```

Expected: ネットワークエラー or タイムアウト or 0/NXDOMAIN 系 (AdGuard が NXDOMAIN 返却 → sing-box DNS resolve 失敗 → 接続失敗)。AdGuard クエリログにもブロック記録あり。

- [ ] **Step 5: Leak テスト (socks5:// と socks5h:// の比較)**

```bash
# 5-a: socks5h (remote DNS) — AdGuard ログに記録される
curl -x socks5h://sing-box:1080 https://httpbin.org/ip -sS
# 5-b: socks5 (local DNS) — Mac 側 DNS で解決、AdGuard ログには **記録されない** (= leak)
curl -x socks5://sing-box:1080 https://httpbin.org/ip -sS
```

Step 5-a 後の AdGuard クエリログに `httpbin.org` がある、Step 5-b 後にはない、を確認。これが `socks5h://` 必須の理由 → クライアントガイドで明示する。

**No commit for this task** (確認のみ)。検証結果は Task 9 の README に反映。

---

## Task 8: services/sing-box/justfile と README

**目的:** 操作 wrapper と運用 doc を整える。

**Files:**

- Create: `services/sing-box/justfile`
- Create: `services/sing-box/README.md`

- [ ] **Step 1: justfile を書く**

OCI 専用なので、`gatus/justfile` の手書きモード recipe (deploy / start / stop / restart) は不要。OCI 操作の thin wrapper にする。

```just
_default:
    @just --list

####################
# OCI operations (sing-box runs on OCI NixOS host)
####################

# Show status of sing-box services on OCI
[group('observe')]
status:
    just ../../oci-status | grep -E 'sing-box'

# Show logs for sing-box (sidecar or app)
# Usage: just sing-box logs            -> sing-box.service
#        just sing-box logs ts         -> sing-box-ts.service
[group('observe')]
logs target="app":
    @if [ "{{ target }}" = "ts" ]; then just ../../oci-logs sing-box-ts; else just ../../oci-logs sing-box; fi

# Restart sing-box on OCI (does NOT restart the sidecar)
[group('lifecycle')]
restart:
    ssh root@$(sops -d --extract '["oci_host"]' ../../hosts/oci/secrets.yaml) 'systemctl restart sing-box.service'

# Restart Tailscale sidecar (will also restart sing-box due to Requires=)
[group('lifecycle')]
restart-ts:
    ssh root@$(sops -d --extract '["oci_host"]' ../../hosts/oci/secrets.yaml) 'systemctl restart sing-box-ts.service'
```

- [ ] **Step 2: README.md を書く**

```markdown
# sing-box

OCI Ampere A1 (NixOS, aarch64) 上で動く forward proxy。Tailnet 内のクライアントに SOCKS5 (1080) + HTTP CONNECT (8080) を提供し、AdGuard Home を DNS upstream に指して DNS フィルタを proxy 経由トラフィックにも効かせる。

## 構成

| ファイル       | 役割                                                             |
| -------------- | ---------------------------------------------------------------- |
| `nixos.nix`    | NixOS Quadlet module (sing-box + Tailscale sidecar、config 生成) |
| `secrets.yaml` | Tailscale authkey (sops + age 暗号化)                            |
| `justfile`     | OCI 上の sing-box.service / sing-box-ts.service 操作 wrapper     |

OCI 専用 (NixOS Quadlet) のため、`quadlet/` ディレクトリや手書きモードの container ファイルは持たない。設定は `nixos.nix` 内で `pkgs.writeText "config.json" (builtins.toJSON ...)` で生成し、コンテナへ ro マウント。

## セットアップ

1. Tailscale admin console で sing-box 用 authkey を発行
2. `sops services/sing-box/secrets.yaml` で `ts_authkey` を記入
3. `just oci-deploy` で NixOS configuration を適用

## クライアント側設定

詳細は [`docs/guides/sing-box-client-setup.md`](../../docs/guides/sing-box-client-setup.md) を参照。要点:

- SOCKS5: `socks5h://sing-box:1080` (remote DNS 必須、`socks5h` の `h` がそれ)
- HTTP CONNECT: `http://sing-box:8080`
- ホスト名 `sing-box` は Tailscale MagicDNS で resolve される

## アーキテクチャ
```

[Tailnet client]
│ socks5h / http_proxy
▼
sing-box-ts (Tailscale sidecar)
│ tailscale0 (only)
▼
sing-box (proxy)
│ dns → AdGuard Home (Tailscale IP)
│ outbound → direct
▼
[Internet]

```

- `tailscale0` のみで listen するため Tailnet 内限定でアクセス可能 (公衆 expose なし)
- DNS は AdGuard Home の Tailscale IP に投げるため、proxy 経由でも AdGuard フィルタが効く
- 認証なし (Tailnet 内限定で許容、ADR-012 参照)

## コマンド

| コマンド                    | 説明                                          |
| --------------------------- | --------------------------------------------- |
| `just oci-deploy`           | NixOS configuration 反映 (sing-box デプロイ)  |
| `just sing-box status`      | sing-box / sing-box-ts の状態                 |
| `just sing-box logs`        | sing-box.service のログ                       |
| `just sing-box logs ts`     | sing-box-ts.service のログ                    |
| `just sing-box restart`     | sing-box.service だけ再起動                   |
| `just sing-box restart-ts`  | Tailscale sidecar 再起動 (sing-box も連動)    |

## 関連ドキュメント

- [ADR-012: sing-box forward proxy 採用](../../docs/design-docs/adr/012-sing-box-forward-proxy.md)
- [パターン: Tailscale サイドカー](../../docs/design-docs/patterns/tailscale-sidecar.md)
- [クライアント設定ガイド](../../docs/guides/sing-box-client-setup.md)
```

- [ ] **Step 3: ローカルで `just sing-box` を試す**

```bash
just sing-box 2>&1
```

Expected: recipe 一覧が表示される (`_default` の `just --list`)。

```bash
just sing-box status 2>&1 | tail -10
```

Expected: 実機の sing-box.service / sing-box-ts.service の active 状態が表示される。

- [ ] **Step 4: commit**

```bash
git add services/sing-box/justfile services/sing-box/README.md
git commit -m "feat(sing-box): justfile + README を追加

OCI 上の sing-box.service / sing-box-ts.service を操作する thin wrapper
(status / logs / restart / restart-ts) と運用 README。

Refs: #21"
```

---

## Task 9: クライアント設定ガイド `docs/guides/sing-box-client-setup.md`

**目的:** macOS / iOS / Browser / CLI でのクライアント側設定を案内。leak 注意事項を明示。

**Files:**

- Create: `docs/guides/sing-box-client-setup.md`

- [ ] **Step 1: ガイドを書く**

````markdown
# sing-box クライアント設定ガイド

OCI 上の sing-box forward proxy をクライアント側で使うための設定。Tailscale 接続済であることが前提。

## 接続情報

| プロトコル   | URL                       | 用途                             |
| ------------ | ------------------------- | -------------------------------- |
| SOCKS5       | `socks5h://sing-box:1080` | CLI / 一部アプリ / SSH トンネル  |
| HTTP CONNECT | `http://sing-box:8080`    | ブラウザ / FoxyProxy / 一般 HTTP |

ホスト名 `sing-box` は Tailscale MagicDNS で resolve される。Tailscale 未接続だと到達不能。

## **重要: DNS leak 防止**

- SOCKS5 は必ず **`socks5h://`** (末尾 `h`) を使うこと
  - `socks5://` (`h` なし) はクライアント側で DNS を解決してから IP を proxy に渡すため、AdGuard を bypass する (= フィルタが効かない / クエリログにも記録されない)
  - `socks5h://` は FQDN を proxy に渡し、proxy 側 (sing-box → AdGuard) で resolve するためフィルタが効く
- HTTP CONNECT は仕様上常に FQDN を渡すため leak の心配なし

## macOS

### System-wide (Network preferences)

1. System Settings → Network → 使用中のサービス (Wi-Fi 等) → Details… → Proxies
2. **SOCKS Proxy** を有効化、サーバー `sing-box`、ポート `1080`
3. (or) **Secure Web Proxy (HTTPS)** を有効化、サーバー `sing-box`、ポート `8080`
4. 「Proxy 例外」リストでローカル / Tailnet 内アドレスを除外

macOS の System SOCKS は remote DNS をデフォルトで使う実装になっているが、アプリにより挙動が異なる。確実性が必要なら下記の app 別設定を使う。

### PAC ファイル (条件付きルーティング)

社内ドメインや特定サイトだけ proxy を経由したい場合:

```javascript
// pac.js
function FindProxyForURL(url, host) {
  // 特定ドメインだけ proxy 経由
  if (shExpMatch(host, "*.example.com") || shExpMatch(host, "*.target-site.com")) {
    return "SOCKS5 sing-box:1080";
  }
  return "DIRECT";
}
```
````

System Settings → Network → Proxies → Automatic Proxy Configuration に PAC URL (例: `file:///Users/you/pac.js`) を指定。

## iOS

### Shadowrocket / sing-box-client

- Type: SOCKS5
- Host: `sing-box`
- Port: `1080`
- "Remote DNS" を ON (これが `socks5h` 相当)

### iOS 標準 (Wi-Fi 個別設定)

設定 → Wi-Fi → 接続中の SSID → HTTP プロキシ → 手動

- サーバー: `sing-box`
- ポート: `8080`

(iOS 標準は HTTP CONNECT のみ、SOCKS5 は非対応)

## ブラウザ (FoxyProxy)

ドメイン条件で proxy を ON/OFF できる。

1. FoxyProxy 拡張 (Firefox / Chrome) をインストール
2. Add Proxy:
   - Type: **SOCKS5**
   - Address: `sing-box`
   - Port: `1080`
   - "Send DNS through SOCKS5 proxy" を **必ず ON** (これが remote DNS)
3. Patterns で条件指定 (例: `*://*.example.com/*` で `Use this proxy`)

## CLI

### curl

```bash
# SOCKS5 + remote DNS
curl -x socks5h://sing-box:1080 https://example.com

# HTTP CONNECT
curl -x http://sing-box:8080 https://example.com

# 環境変数で全体に適用
export ALL_PROXY=socks5h://sing-box:1080
curl https://example.com
```

`socks5h` の `h` を忘れないこと。

### git

```bash
git config --global http.proxy socks5h://sing-box:1080
git clone https://github.com/...
```

### ssh トンネル

```bash
ssh -o ProxyCommand="nc -X 5 -x sing-box:1080 %h %p" some-server.example.com
```

`-X 5` が SOCKS5 を指定。

## 動作確認

```bash
# Proxy 経由の出口 IP (OCI の出口 IP が返れば成功)
curl -x socks5h://sing-box:1080 https://api.ipify.org

# AdGuard のフィルタ動作 (AdGuard でブロック済みドメインなら接続失敗)
curl -x socks5h://sing-box:1080 https://doubleclick.net -m 5
```

AdGuard Home の Query Log にクエリ履歴が残ること、ブロック対象は遮断されることを確認。

## トラブルシューティング

| 症状                               | 原因と対処                                                       |
| ---------------------------------- | ---------------------------------------------------------------- |
| `Could not resolve host: sing-box` | Tailscale 未接続 / MagicDNS 無効。`tailscale status` で接続確認  |
| AdGuard クエリログに残らない       | `socks5://` (h なし) を使っている可能性。`socks5h://` に直す     |
| 接続できるが特定ドメインだけ失敗   | AdGuard でブロックされている可能性。AdGuard Query Log で確認     |
| TLS error / cert error             | クライアント側で certificate pinning しているアプリは proxy 不可 |

````

- [ ] **Step 2: commit**

```bash
git add docs/guides/sing-box-client-setup.md
git commit -m "docs(sing-box): クライアント設定ガイド追加

macOS / iOS / Browser (FoxyProxy) / CLI (curl, git, ssh) の各クライアント
での sing-box proxy 設定手順と、DNS leak 防止のための socks5h:// 必須
を明記。

Refs: #21"
````

---

## Task 10: ADR-012 を書く

**目的:** sing-box 採用とプロトコル / DNS 選択の判断記録を残す。

**Files:**

- Create: `docs/design-docs/adr/012-sing-box-forward-proxy.md`

**参考:** 既存 ADR (`docs/design-docs/adr/011-metrics-backend-victoriametrics.md` など) を構造の手本にする。

- [ ] **Step 1: ADR-012 を書く**

```markdown
# ADR-012: sing-box による Tailnet 内 forward proxy 採用

- Status: Accepted
- Date: 2026-05-20
- Deciders: noize

## Context

AdGuard Home は DNS フィルタのみで、HTTPS の通信内容は WiFi / ISP から見える。一部のクライアント (外出先のラップトップ等) に限って HTTP/HTTPS トラフィック経路を OCI 経由に切り替えたいケースがある。

Tailscale exit node はノード単位で全トラフィックを吸収するため、アプリ / ドメイン粒度の選択的 routing には不向き。アプリ単位 / ドメイン単位で proxy を ON/OFF したい用途には forward proxy が適している。

## Decision

1. **Forward proxy ツールに sing-box を採用** する
2. **inbound プロトコルは SOCKS5 (1080) + HTTP CONNECT (8080) を別ポートで併設** する
3. **DNS upstream は AdGuard Home の Tailscale IP** を指す
4. **クライアント認証は設けない** (Tailnet 内限定で許容)

### ツール選定の比較

| ツール       | Pros                                                                            | Cons                                           |
| ------------ | ------------------------------------------------------------------------------- | ---------------------------------------------- |
| **sing-box** | 単一バイナリ、SOCKS5/HTTP/暗号化プロトコル統合、設定が JSON、active development | 設定がやや独特、TUN モードなど未使用機能も多い |
| Xray-core    | 機能網羅、コミュニティ大                                                        | 設定が複雑、用途的に過剰                       |
| V2Ray        | 老舗                                                                            | sing-box / Xray に置き換わりつつある           |
| dante        | SOCKS5 専用で枯れている                                                         | HTTP CONNECT 不可、設定が古い                  |
| tinyproxy    | HTTP CONNECT 専用、軽量                                                         | SOCKS 不可、機能が単機能                       |

将来 VLESS-Reality など暗号化 inbound が必要になった場合、sing-box は同じバイナリで対応できるため拡張性が高い。

### プロトコル併設の理由

- **SOCKS5**: CLI ツール (curl, git, ssh -D)、アプリ単位設定 (Shadowrocket 等)、PAC で広く使われる
- **HTTP CONNECT**: ブラウザ・FoxyProxy・標準的な HTTP proxy 拡張で扱いが軽い。iOS 標準もこれのみ対応

どちらか一方では用途を狭めるため両方を別ポートで listen する。sing-box の `mixed` inbound (両プロトコルを単一ポートで自動判定) も検討したが、ポート単位で監視 / アクセス制御を分けやすいので別ポート構成を採用。

### DNS upstream の理由

- AdGuard を upstream にすれば proxy 経由のトラフィックも AdGuard のブロックリストの恩恵を受ける
- パブリック resolver (1.1.1.1 等) を直接使うと proxy 経由トラフィックは AdGuard フィルタを bypass する (= 本来の DNS フィルタ目的とずれる)
- Loop は構造的に発生しない (sing-box → AdGuard → 外部 resolver の片方向)
- Leak の主リスクはクライアント側 (`socks5://` で local DNS してしまうケース)。これはクライアント側ガイドで `socks5h://` を案内して対処する

IP リテラル vs MagicDNS 名: 起動順依存の DNS resolve を避けるため、Tailscale node の安定 IP リテラルを採用。MagicDNS 名は人間向けの参考としてコードコメントに残す。

### 認証なしの理由

- Tailnet 内限定 (`tailscale0` 経由のみ受付) のため、Tailscale auth が事実上の access control になる
- 追加で proxy 自身の auth を設けると運用コスト (credential 配布・更新) と利便性低下 (PAC に credential 埋め込み等) のデメリットの方が大きい
- 公衆 expose する場合は別途認証必須だが、本設計では公衆 expose しない

## Consequences

### Positive

- アプリ / ドメイン粒度の選択的 routing が可能 (exit node では不可能)
- AdGuard のフィルタが proxy 経由トラフィックにも適用される
- sing-box の active development により将来 VLESS-Reality 等の追加対応が容易
- 設定が JSON / NixOS Quadlet で宣言的に管理可能

### Negative

- クライアント側で SOCKS5 を使う際 `socks5h://` を意識する運用負荷 (ガイドで対処)
- sing-box の image (aarch64 multi-arch) が継続的に提供されることに依存
- Tailscale 接続必須なので、Tailscale auth 切れ時は proxy も到達不能

### Neutral

- Clash API metrics / Grafana ダッシュボードは別 issue に切り出し、observability マイルストン M2 完了後に追加
- VLESS-Reality 等の暗号化プロトコルは現時点で未採用 (Tailscale 経由前提のため不要)

## Related

- [Spec: sing-box 選択的 forward proxy on OCI](../../superpowers/specs/2026-05-20-sing-box-forward-proxy-design.md)
- [Issue #21](https://github.com/afxnoize/nz-homelab-services/issues/21)
- [Pattern: Tailscale Sidecar](../patterns/tailscale-sidecar.md)
- [Pattern: 公開モデル (Model A)](../patterns/exposure-models.md)
- [ADR-009: quadlet-nix によるコンテナ定義の統一](009-quadlet-nix-unification.md)
```

- [ ] **Step 2: commit**

```bash
git add docs/design-docs/adr/012-sing-box-forward-proxy.md
git commit -m "docs(adr): ADR-012 sing-box forward proxy 採用を記録

ツール選定 (sing-box vs Xray/V2Ray/dante/tinyproxy)、プロトコル併設の
理由、DNS upstream に AdGuard を指す理由、認証なしの理由を記録。

Refs: #21"
```

---

## Task 11: AGENTS.md にサービス行追加

**目的:** サービス一覧と技術スタック表に sing-box を追加 (Documentation-Code Coupling ルール)。

**Files:**

- Modify: `AGENTS.md`

- [ ] **Step 1: 「機能概要」セクションに sing-box の行を追加**

`AGENTS.md:54` 付近、`services/ollama/README.md` の行の後に追加:

```markdown
- [services/sing-box/README.md](services/sing-box/README.md) — sing-box 選択的 forward proxy (SOCKS5/HTTP、Tailscale 経由)
```

- [ ] **Step 2: 「技術スタック」表に sing-box の行を追加**

「DNS フィルタ」の行 (`| DNS フィルタ ...`) の下に追加:

```markdown
| Forward Proxy | sing-box + Tailscale Sidecar (OCI、SOCKS5/HTTP CONNECT) |
```

- [ ] **Step 3: 「リポジトリ構成」のサービス一覧に sing-box を追加**

`services/` ディレクトリ図 (現状 6 サービス) に追加:

```
├── adguard-home/                     # → README.md 参照
├── ollama/                           # → README.md 参照 (WSL2 マシン)
├── observability/                    # → README.md 参照 (※ feat/obs/main で進行中、main 未マージ)
└── sing-box/                         # → README.md 参照 (Tailscale 内 forward proxy)
```

(observability の行は main にまだ無いので追加しない。sing-box のみ追加)

- [ ] **Step 4: commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): sing-box サービスを AGENTS.md に追記

機能概要・技術スタック・リポジトリ構成の各セクションに sing-box の
エントリを追加。

Refs: #21"
```

---

## Task 12: PR 作成 + Issue #21 クローズ

**目的:** PR を出して merge 待ちに乗せる。

- [ ] **Step 1: 最新の main と rebase (必要なら)**

```bash
git fetch origin main
git rebase origin/main 2>&1 | tail -10
```

Conflict が出なければそのまま push。出た場合は手動で解消。

- [ ] **Step 2: branch を push**

```bash
git push -u origin feat/sing-box-forward-proxy 2>&1 | tail -10
```

- [ ] **Step 3: PR を作成**

```bash
gh pr create --title "feat(sing-box): OCI に Tailscale 経由 forward proxy を追加" --body "$(cat <<'EOF'
## Summary

- OCI Ampere A1 (NixOS, aarch64) に sing-box を Tailscale sidecar 経由で常駐
- inbound: SOCKS5 (1080) + HTTP CONNECT (8080) を別ポートで併設、`tailscale0` 経由のみで listen
- outbound: direct
- DNS: AdGuard Home の Tailscale IP を upstream (proxy 経由トラフィックにも AdGuard フィルタが効く)
- 認証: なし (Tailnet 内限定で許容)
- Clash API metrics scrape / Grafana ダッシュボード / vmalert alert は別 PR (observability M2 完了後)

## Design docs

- Spec: `docs/superpowers/specs/2026-05-20-sing-box-forward-proxy-design.md`
- Plan: `docs/superpowers/plans/2026-05-20-sing-box-forward-proxy.md`
- ADR: `docs/design-docs/adr/012-sing-box-forward-proxy.md`
- Client guide: `docs/guides/sing-box-client-setup.md`

## Test plan

- [x] `nix flake check` 通過
- [x] `just oci-build` 通過
- [x] `just oci-deploy` 成功、sing-box.service / sing-box-ts.service が active
- [x] Tailnet クライアントから `curl -x socks5h://sing-box:1080 https://example.com` 200 OK
- [x] Tailnet クライアントから `curl -x http://sing-box:8080 https://example.com` 200 OK
- [x] AdGuard クエリログに proxy 経由のクエリが記録される
- [x] AdGuard blocklist 対象が proxy 経由で遮断される
- [x] `socks5://` (h なし) で AdGuard を bypass することを確認 (= leak 注意の根拠)

## Follow-up

- Clash API metrics scrape (別 issue)
- Grafana ダッシュボード (別 issue)
- vmalert alert (`sing-box.service` down) を observability スタックに追加 (別 PR)

Closes #21
EOF
)" 2>&1
```

Expected: PR URL が標準出力に出る。

- [ ] **Step 4: PR URL を確認**

```bash
gh pr view --json url --jq .url
```

Expected: `https://github.com/afxnoize/nz-homelab-services/pull/<N>` が返る。

- [ ] **Step 5: Issue #21 の状態を確認**

PR body に `Closes #21` が入っているので、merge 時に自動 close されるはず。事前確認のみ:

```bash
gh issue view 21 --json state,title
```

Expected: `state: open` (まだ merge していない)。

merge 後に再度確認し、`state: closed` になっていれば完了。

**No additional commit for this task** (push と PR 作成のみ)。

---

## Follow-up (本 PR 外)

以下は本 PR の scope に含めず、別 issue / 別 PR で扱う:

1. **vmalert ルール追加** (`sing-box.service` down → Telegram): observability スタックが main に降りた後、observability の vmalert ルールセットに以下を追加する別 PR を出す。

   ```yaml
   - alert: SingBoxDown
     expr: |
       absent_over_time(systemd_unit_state{name="sing-box.service",state="active"}[2m]) == 1
     for: 1m
     labels: { severity: warning }
     annotations:
       summary: "sing-box forward proxy down"
   ```

   実機の Alloy + node exporter のメトリクス出力名を確認した上で式を確定する。

2. **Clash API metrics の Alloy scrape**: sing-box の Clash API (`experimental.clash_api`) を有効化、Alloy で scrape して VictoriaMetrics に保存。

3. **Grafana ダッシュボード**: 接続数 / トラフィック / inbound 別ポート別流量を可視化。observability M2 完了後に追加。

4. **`mixed` inbound への移行検討**: 別ポート構成で運用してみて、単一ポート (`mixed`) のほうが運用シンプルと判断した場合は別 PR で切り替える。

---

## Self-Review (plan 作成者向けチェックリスト)

このセクションは plan 作成時の自己レビュー用。実装者は無視してよい。

### Spec coverage

spec の各セクション項目と対応 task の対応表:

| Spec セクション                   | 対応 task                                     |
| --------------------------------- | --------------------------------------------- |
| 決定ロック #1 inbound プロトコル  | Task 3 (`nixos.nix` の inbounds)              |
| 決定ロック #2 sidecar 形態        | Task 3 (`virtualisation.quadlet.containers`)  |
| 決定ロック #3 DNS upstream        | Task 2 + Task 3 (AdGuard IP 確定 + 反映)      |
| 決定ロック #4 クライアント DNS    | Task 9 (クライアント設定ガイド)               |
| 決定ロック #5 observability scope | Follow-up に分離 (observability merge 待ち)   |
| 決定ロック #6 config 管理         | Task 3 (`pkgs.writeText` + `builtins.toJSON`) |
| 決定ロック #7 image               | Task 1 (事前検証) + Task 3 (image 指定)       |
| 決定ロック #8 認証                | (なし — 認証設定そのものが不要)               |
| アーキテクチャ全体                | Task 3                                        |
| Loop / leak 防止                  | Task 9 (クライアント側で対処) + Task 7 で検証 |
| ファイル構成 (新規 / 既存変更)    | Task 3, 5, 8, 9, 10, 11                       |
| データフロー                      | Task 6, 7 で動作確認                          |
| 失敗モードとエラーハンドリング    | Task 6 (Restart=always、起動順依存)           |
| テスト / 検証手順                 | Task 1, 6, 7                                  |
| ADR-012 起票                      | Task 10                                       |

### Placeholder scan

- `<ADGUARD_TS_IP>` は Task 2 で確定 → Task 3 で実 IP に置換する手順を明示済
- 「(memory)」「TBD」「TODO」「実装段階で確認」系の語は Task 内には残置せず、Task 2 / 事前検証 (Task 1) で確定させる構造になっている
- 一部 example.com / 100.64.1.2 などはサンプル値だが、コンテキスト上明確に判別可能

### 型整合性

- `sing-box` / `sing-box-ts` の unit / service 名は全 Task で一貫
- `services/sing-box/nixos.nix` のファイル名は全 Task で一貫 (`default.nix` ではない)
- `adguardDnsHost` 変数名は Task 3 内のみで使用、外部参照なし
- `socks5h://` の `h` を必要箇所すべてで一貫使用

問題なし。
