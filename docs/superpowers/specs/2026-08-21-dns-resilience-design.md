# DNS 冗長化・フィルタリング両立の検討メモ

- Status: draft（検討のみ、未実装）
- Date: 2026-08-21
- 背景: tailscale sidecar 更新作業中に adguard-home が停止し、tailnet 全体の DNS が巻き添えになった（→ [K-017](../../knowledge.md), [K-018](../../knowledge.md)）。「adguard-home が SPOF」問題と「フィルタリングの確実性」を両立する構成を検討した。

## 前提として確認した Tailscale の仕様

| 仕様                               | 内容                                                                                                                                                               |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Global nameservers                 | 複数登録すると**並列クエリ・最速応答勝ち**。優先順位・フェイルオーバーの概念はない。adguard + 8.8.8.8 を並べると、フィルタを素通りするクエリが常時確率的に発生する |
| Split DNS (restricted nameservers) | ドメイン単位の resolver 指定。こちらは**順次フォールバックあり**（要実挙動確認）だが、catch-all にはできない                                                       |
| Tailscale Services (TailVIP)       | 複数ホストで広告でき HA になるが **TCP のみ**。DNS (UDP/53) は移行不可。HTTP 系サービスの sidecar 廃止には使える（別件）                                           |
| DNS の自動広告                     | ノードが「自分が DNS」と手を挙げる仕組みは存在しない。DNS 設定は admin console / API の中央管理のみ                                                                |

## 検討した選択肢

1. **現状維持**（global = adguard + Google 並列）: 可用性◯、フィルタ確実性✕（素通りあり）
2. **AdGuard 2台目** + global に両方登録: 根本解決。並列 race でも両方フィルタするので素通りなし。**要: 2台目の常時稼働ホスト**（ローカル機/WSL2 は不適。OCI 無料枠の2台目 VM が候補）。設定同期は adguardhome-sync
3. **Tailscale API watchdog**: gatus 等の死活検知で API (`/api/v2/tailnet/-/dns/nameservers`) を叩き nameserver を差し替える自作フェイルオーバー。動くが運用物が増える。watchdog の配置に注意（adguard と同居だとホスト死に対応できない）
4. **NextDNS 統合**: console で繋ぐだけのフィルタ DNS SaaS。自前ホスト不要になるがフィルタルールの自由度と引き換え
5. **Cloudflare で domain 取得 + DNS-01 証明書 + AdGuard の DoT/DoH**: 約 $10.44/年 (.com at-cost)。public A レコードに tailnet IP を書き、Let's Encrypt DNS-01 で証明書取得（非公開サーバーでも取れる）。Cloudflare Tunnel は DNS 用途には不適（DoT 不可・公開 = open resolver 化）なので使わない
6. **¥0 案（有力）**: 下記

## 有力案: global は public DNS、フィルタはデバイス単位 opt-in

```text
tailnet global DNS: 1.1.1.1 / 8.8.8.8      ← 全デバイスのベースライン（SPOF なし）
opt-in デバイスのみ:
  Android → Private DNS = adguard-home.<tailnet>.ts.net（DoT）
  PC      → tailscale set --accept-dns=false + OS DNS を adguard の tailnet IP に
```

- opt-in デバイスは常に adguard だけを見るため、フィルタ確実性は並列 race 構成より**上がる**
- OCI ホスト自身はベースライン側になるので K-017 の自己依存も構造的に解消
- adguard 停止時の被害半径は「opt-in デバイスのみ、デバイス側の設定変更で退避可能」に縮小（SPOF の解消ではなく封じ込め）

### 実装 TODO

- [ ] `tailscale cert` で ts.net 名の証明書を取得し AdGuard の Encryption に設定（DoT:853 / DoH 有効化）。更新の自動化込み
- [ ] `accept-dns=false` にした PC は MagicDNS を失う → AdGuard に `*.ts.net` の条件付き upstream を追加して補う（経路の実挙動要確認）
- [ ] Android の Private DNS は strict だと adguard 停止時 fail-closed（全 DNS 遮断）になる点を運用メモに残す

### PC で複数 DNS を並べる場合の OS 挙動（調査済み）

| 環境                           | 挙動                                                                                                                              | 評価                                                                                     |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Windows（優先/代替）           | タイムアウトで代替に切替後、**応答が良い方に居座る**（sticky fail-open）。復帰検知は不透明                                        | フィルタ保証なし。許容するか adguard 単独か                                              |
| Linux / glibc resolv.conf      | 毎クエリ順番に試行。居座りなしだが 1 本目死亡中は**全クエリ +5 秒**（デフォルト timeout）                                         | 優先順位に最も近いが遅延が痛い                                                           |
| Linux / systemd-resolved       | サーバーは**対等扱い**、失敗で切替後は動く方に固定（sticky fail-open）。`FallbackDNS=` は「未設定時」用でフェイルオーバーではない | フィルタ保証なし                                                                         |
| Linux / dnsmasq `strict-order` | primary 優先・失敗時のみ fallback・復帰で戻る、**本物の優先順位フェイルオーバー**                                                 | Linux 常用機の推奨。Windows に同等の native 手段はなし（サードパーティ resolver が必要） |

## 未決事項

- ¥0 案を採用するか（採用時は ADR 化して exposure-models.md / tailscale-sidecar.md に反映）
- 2台目 AdGuard（案2）をいつやるか。Tailscale Services の UDP 対応が来たら「adguard×2 + svc VIP」の完全形を再検討
