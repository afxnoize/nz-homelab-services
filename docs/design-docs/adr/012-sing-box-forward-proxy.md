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
