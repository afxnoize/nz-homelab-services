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
