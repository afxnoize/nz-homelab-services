# sing-box 選択的 forward proxy on OCI spec

## 概要

OCI Ampere A1 (NixOS, aarch64) 上に [sing-box](https://sing-box.sagernet.org/) を Podman Quadlet (Nix モード) で常駐させ、Tailnet 経由でクライアントに SOCKS5 + HTTP CONNECT forward proxy を提供する。クライアント側は PAC / FoxyProxy / アプリ単位設定により**選択的に**プロキシを経由する。AdGuard Home を sing-box の DNS upstream に指して、proxy 経由トラフィックにも既存 DNS フィルタを効かせる。

Tailscale exit node が all-or-nothing なのに対し、本サービスはアプリ / ドメイン粒度で routing を切り替えたいユースケース (外出先 WiFi のラップトップで一部通信のみ OCI 経由にしたい等) を狙う。公衆 expose はしない (Tailnet 内に閉じる)。

### 上流ドキュメント

- [GitHub Issue #21](https://github.com/afxnoize/nz-homelab-services/issues/21) — 原案
- [パターン: Quadlet 構成規約](../../design-docs/patterns/quadlet-conventions.md)
- [パターン: Tailscale サイドカー](../../design-docs/patterns/tailscale-sidecar.md)
- [パターン: 公開モデル](../../design-docs/patterns/exposure-models.md) (Model A 相当)
- [パターン: シークレットパイプライン](../../design-docs/patterns/secret-pipeline.md)
- [ADR-009: quadlet-nix によるコンテナ定義の統一](../../design-docs/adr/009-quadlet-nix-unification.md)

### スコープ

**in scope**:

- `services/sing-box/` ディレクトリ新設 (Nix module + config 生成 + README + justfile)
- Podman Quadlet (Nix モード) で sing-box + Tailscale sidecar を起動
- inbound: SOCKS5 (1080) + HTTP CONNECT (8080) を sidecar の `tailscale0` 経由のみで受付
- outbound: direct
- DNS: `dns.server` = AdGuard Home の Tailscale IP (plain 53/udp、Tailnet 内なので暗号化不要)
- `hosts/oci/configuration.nix` への統合
- `hosts/oci/secrets.yaml` に `sing_box_ts_authkey` を追加 (sops 暗号化)
- vmalert ルール: `sing-box.service` down で Telegram 通知 (既存 alert-routing 経由)
- ログ: journald → Alloy → VictoriaLogs (既存パイプラインで自動収集、追加設定なし)
- ADR-012 起票 (sing-box 採用 / プロトコル選択 / DNS upstream 選択の判断記録)
- ドキュメント: `docs/guides/sing-box-client-setup.md` 新設、AGENTS.md にサービス行追加

**out of scope** (本 PR に含めない):

- Clash API metrics の Alloy scrape (M2 完了後に別 issue で)
- Grafana ダッシュボード (同上)
- VLESS-Reality 等の暗号化 inbound (Tailscale 経由前提のため不要)
- 全トラフィック VPN 用途 (Tailscale exit node の領分)
- 認証 (Tailnet 内限定なので不要)
- 公衆 expose / Tailscale Funnel

---

## 決定ロック

| #   | 項目                | 決定値                                                                                                      |
| --- | ------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1   | inbound プロトコル  | **SOCKS5 (1080) + HTTP CONNECT (8080) を別ポートで併設**                                                    |
| 2   | sidecar 形態        | **Tailscale sidecar の netns を共有し `tailscale0` 経由で listen**。`TS_SERVE_CONFIG` は使わない            |
| 3   | DNS upstream        | **AdGuard Home の Tailscale IP** を `dns.server` に指定 (plain 53/udp)                                      |
| 4   | クライアント DNS    | **remote DNS モード必須** (SOCKS5 は `socks5h://` / HTTP CONNECT)。ガイドで明示                             |
| 5   | observability scope | **journald ログのみ + `sing-box.service` down alert**。Clash API metrics / Grafana ダッシュボードは別 issue |
| 6   | config 管理         | **Nix で `writeText` + `builtins.toJSON` 生成**。gomplate / sops-nix template は使わない (secret なし)      |
| 7   | image               | **`ghcr.io/sagernet/sing-box`** (multi-arch、aarch64 サポートを実装前に検証)                                |
| 8   | 認証                | **なし** (Tailnet 内限定で許容、Issue 要件)                                                                 |

---

## アーキテクチャ

```
┌────────────────────────────────────────────────────┐
│  OCI Ampere A1 (NixOS, aarch64)                    │
│                                                    │
│  ┌──────────────────────────────────────────────┐  │
│  │  Pod (shared netns)                          │  │
│  │                                              │  │
│  │  ┌──────────────┐    ┌──────────────────┐   │  │
│  │  │  tailscale   │    │     sing-box     │   │  │
│  │  │  sidecar     │    │  :1080  SOCKS5   │   │  │
│  │  │  (ts0)       │    │  :8080  HTTP     │   │  │
│  │  └──────────────┘    └──────────────────┘   │  │
│  │       │                       │              │  │
│  └───────┼───────────────────────┼──────────────┘  │
│          │ (tailnet)             │ (outbound dir.) │
└──────────┼───────────────────────┼─────────────────┘
           ▼                       ▼
    Tailnet clients          Internet (direct)
    + AdGuard (DNS)
```

- `tailscale-sidecar` パターンを踏襲。Tailscale コンテナと sing-box コンテナを同一 netns で動かす
- `TS_SERVE_CONFIG` は**設定しない** (Tailscale Serve は L7 HTTPS リバプロで、SOCKS5 / HTTP CONNECT を終端できないため)
- sing-box は `0.0.0.0:1080` / `0.0.0.0:8080` で listen。sidecar の netns には `tailscale0` と `lo` しか居ないので、結果的に Tailnet 経由でのみ到達可能
- outbound は direct (sing-box が解決済み IP に素で connect)
- DNS は sing-box の `dns.server` に AdGuard の Tailscale IP を指定。クライアントから受け取った FQDN を server-side で resolve → AdGuard のブロックリストが効く

### Loop / leak 防止

- **Loop**: 構造的に発生しない。sing-box → AdGuard → 外部 resolver の片方向で、AdGuard → sing-box の経路は存在しない
- **Leak の主リスクはクライアント側**: SOCKS5 で remote DNS モード (`socks5h://`) を使わないとクライアントが先に DNS 解決して IP を渡し、AdGuard を bypass する。HTTP CONNECT は常に remote DNS なので問題なし。クライアント設定ガイドで明示する

---

## ファイル構成

### 新規ファイル

```
services/sing-box/
├── default.nix           # Nix module entry point (containers + secrets)
├── config.nix            # sing-box JSON 設定を組み立てる関数
├── justfile              # deploy / status / logs / restart
├── README.md             # サービス概要・運用手順
└── (state volume は named volume で podman 側に置く、ファイルなし)

docs/
├── guides/
│   └── sing-box-client-setup.md  # クライアント側設定 (PAC / FoxyProxy / macOS / iOS / curl / ssh)
└── design-docs/
    └── adr/
        └── 012-sing-box-forward-proxy.md  # ADR
```

### 既存ファイル変更

- `hosts/oci/configuration.nix` — `services/sing-box/default.nix` を import
- `hosts/oci/vars.nix` — 必要なら `adguardTailscaleHost` (or 既存変数名) を追加 / 参照
- `hosts/oci/secrets.yaml` — `sing_box_ts_authkey` を追加 (sops 暗号化)
- `justfile` (root) — `mod sing-box "services/sing-box/justfile"` を追加
- `AGENTS.md` — サービス一覧と技術スタック表に sing-box 行を追加
- `ARCHITECTURE.md` — パターンカタログから sing-box を参照する場合のみ
- vmalert ルール (observability スタック内) — `sing-box.service` down 用ルール 1 件追加

---

## 主要コンポーネント詳細

### `services/sing-box/config.nix`

sing-box の JSON 設定を Nix 関数として表現する。引数で受ける可変要素は AdGuard の Tailscale IP (or MagicDNS 名) のみ。

```nix
{ adguardDnsHost }:
{
  log = {
    level = "info";
    timestamp = true;
  };
  dns = {
    servers = [
      { tag = "adguard"; address = adguardDnsHost; }
    ];
    final = "adguard";
  };
  inbounds = [
    { type = "socks";  tag = "socks-in"; listen = "0.0.0.0"; listen_port = 1080; }
    { type = "http";   tag = "http-in";  listen = "0.0.0.0"; listen_port = 8080; }
  ];
  outbounds = [
    { type = "direct"; tag = "direct"; }
  ];
  route = {
    final = "direct";
  };
}
```

`default.nix` 内で `pkgs.writeText "config.json" (builtins.toJSON (import ./config.nix { ... }))` として実体化し、コンテナへ ro マウントする。

### `services/sing-box/default.nix`

`virtualisation.quadlet.containers.sing-box-ts` と `.sing-box` を定義する Nix module。tailscale-sidecar.md の規約に準拠:

- `sing-box-ts` コンテナ: `tailscale/tailscale` image、`TS_AUTHKEY` (sops template から)、`TS_HOSTNAME=sing-box`、`TS_STATE_DIR=/var/lib/tailscale` を明示、state 永続化用 named volume をマウント
- `sing-box` コンテナ: `ghcr.io/sagernet/sing-box`、`networks = [ "container:sing-box-ts.service" ]`、`unitConfig.Requires = [ "sing-box-ts.service" ]` / `After = [ "sing-box-ts.service" ]`、`containerConfig.exec = [ "-c" "/etc/sing-box/config.json" "run" ]`、config を ro マウント

両コンテナとも `logDriver = "journald"`、`serviceConfig.Restart = "always"`、`autoStart = true`。

### `hosts/oci/secrets.yaml`

`sing_box_ts_authkey` を追加 (既存の他サービスの ts_authkey と同パターン)。sops template で Quadlet の environment file に展開。

### vmalert ルール

既存の vmalert ルールセット (observability スタック内) に以下を追加:

```yaml
- alert: SingBoxDown
  expr: |
    absent_over_time(systemd_unit_state{name="sing-box.service",state="active"}[2m]) == 1
  for: 1m
  labels: { severity: warning }
  annotations:
    summary: "sing-box forward proxy down"
```

(具体的なメトリクス名は実機 node exporter / Alloy の出力に合わせて調整。実装段階で確認)

### `docs/guides/sing-box-client-setup.md`

クライアント別の手順を案内:

- **macOS**: System Settings → Network → Proxies で SOCKS5 / HTTP プロキシを設定。PAC ファイルでドメイン条件付き routing
- **iOS**: sing-box-client / Shadowrocket / Surge で endpoint 登録
- **Browser**: FoxyProxy で SOCKS5 (`socks5h://` 指定で remote DNS) を設定。条件付き ON/OFF
- **CLI**:
  - `curl -x socks5h://sing-box.<tailnet>:1080 https://example.com` (`h` が remote DNS の鍵)
  - `curl -x http://sing-box.<tailnet>:8080 https://example.com`
  - `ssh -o ProxyCommand="nc -X 5 -x sing-box.<tailnet>:1080 %h %p"`
- **Leak 注意事項**: SOCKS5 は必ず `socks5h://` (remote DNS) を使うこと。`socks5://` だとクライアント側 DNS 解決で AdGuard を bypass する旨を明記

### ADR-012

採用決定の記録。Context / Decision / Consequences 形式。決定事項:

1. forward proxy ツールとして sing-box を採用 (Xray, V2Ray, dante, tinyproxy などとの比較表)
2. inbound プロトコルとして SOCKS5 + HTTP CONNECT を併設 (どちらか単独でないこと)
3. DNS upstream に AdGuard を指す (パブリック resolver にしない)
4. クライアント認証はなし (Tailnet 限定で許容)

---

## データフロー

1. クライアント (Tailscale 接続済) が PAC / FoxyProxy / アプリ設定により `socks5h://sing-box.<tailnet>:1080` または `http://sing-box.<tailnet>:8080` 経由でリクエストを送る
2. Tailscale WireGuard → OCI ホストの Tailscale sidecar (`tailscale0`) に到達
3. sing-box が SOCKS5 / HTTP CONNECT を受理。target FQDN を `dns.server` (AdGuard Tailscale IP) で resolve
4. AdGuard が FQDN を フィルタ判定 → 通過した場合のみ IP を返答
5. sing-box が outbound `direct` で解決済み IP に TCP connect、レスポンスをクライアントへ返す
6. sing-box / Tailscale sidecar のログは journald → Alloy → VictoriaLogs (既存パイプライン)

---

## 失敗モードとエラーハンドリング

| 失敗                     | 動作                                                                              |
| ------------------------ | --------------------------------------------------------------------------------- |
| sing-box プロセス crash  | systemd `Restart=always` で復帰                                                   |
| `sing-box.service` down  | vmalert ルール (1m for) → Telegram                                                |
| Tailscale sidecar 異常   | `Requires=sing-box-ts.service` で sing-box も停止 (起動順依存)                    |
| AdGuard 到達不可         | sing-box の DNS resolve 失敗 → クライアントへ proxy エラー。AdGuard 死活は別系統  |
| クライアント DNS leak    | docs/guides で `socks5h://` を案内、これは設計判断としては許容 (運用ガイドで対処) |
| Tailnet 外からのアクセス | sidecar が `tailscale0` 上にしか listen していないため到達不能                    |

---

## テスト / 検証手順

### ビルド / デプロイ

1. `nix flake check` — Nix 評価が通る
2. `just oci-build` — NixOS configuration がビルドできる
3. `just oci-deploy` — 実機反映
4. `just oci-status` / `just sing-box status` — `sing-box.service` / `sing-box-ts.service` が active

### 疎通

クライアント (Tailscale 接続済 Mac) から:

```bash
# SOCKS5 + remote DNS
curl -x socks5h://sing-box.<tailnet>:1080 https://example.com -v
# HTTP CONNECT
curl -x http://sing-box.<tailnet>:8080 https://example.com -v
```

両方 200 が返ること。

### フィルタ動作確認

- AdGuard クエリログに `example.com` 系の resolve 記録が残る (proxy 経由でも記録される証跡)
- AdGuard の blocklist に登録済みドメイン (例: 任意のテストドメイン) に proxy 経由でアクセス → リクエスト失敗

### Leak テスト

- クライアントで `socks5://` (h 抜き) を使った場合と `socks5h://` を使った場合で、AdGuard クエリログに記録が**残らない / 残る** ことを比較確認 (前者は leak、後者は OK)

### Alert

- 実機で `systemctl stop sing-box.service` → 1-2 分以内に Telegram 通知が来ること
- 復帰: `systemctl start sing-box.service`

---

## マイグレーション / 互換性

新規サービスなので破壊的変更なし。observability スタックは現在 `feat/obs/main` で M3/M4 等が進行中だが、本 spec の vmalert ルール追加は observability スタックの存在を前提とする。merge 順:

1. observability スタックが main に降りる (M2 / その先) のを待つ
2. その後 sing-box PR を main から切って実装
3. もしくは vmalert ルール追加は merge 順を見て別 PR / 別タイミングに分離する

実装着手は (1) を待たずに進められるが、deploy 検証時に observability が main に揃っていることを前提に進める。

---

## リスクと未確定事項

- **aarch64 image の動作**: `ghcr.io/sagernet/sing-box` の multi-arch tag を実装着手直後に手動 pull で確認。動かなければ build from source / 別 image を検討。本 spec は動作前提
- **メトリクス名**: vmalert ルールの式は `systemd_unit_state{...}` を仮置きしている。実機 Alloy + node exporter の出力に合わせて plan / 実装段階で確定
- **AdGuard Tailscale IP の入手経路**: `hosts/oci/vars.nix` に既存変数があるか、新設するかを実装時に確認
- **sing-box `mixed` inbound**: sing-box には SOCKS5 + HTTP CONNECT を単一ポートで受ける `mixed` type もある。1080 / 8080 別ポートで進めるが、実装時に `mixed` の方が運用シンプルなら採用も検討 (機能差は要検証)

---

## 完了条件

- [ ] `services/sing-box/` 一式が main に merge
- [ ] `hosts/oci/` の secrets / configuration 統合済
- [ ] `just oci-deploy` で実機に反映、`sing-box.service` / `sing-box-ts.service` 共に active
- [ ] Tailscale 接続済クライアントから SOCKS5 / HTTP CONNECT 両方で疎通成功
- [ ] AdGuard クエリログに proxy 経由トラフィックの resolve 記録が残ることを確認
- [ ] AdGuard blocklist が proxy 経由でも有効であることを確認
- [ ] `sing-box.service` 停止 → Telegram 通知が来ることを確認
- [ ] `docs/guides/sing-box-client-setup.md` / ADR-012 / AGENTS.md 更新済
- [ ] Issue #21 を close
