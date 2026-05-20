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

| コマンド                    | 説明                                         |
| --------------------------- | -------------------------------------------- |
| `just oci-deploy`           | NixOS configuration 反映 (sing-box デプロイ) |
| `just sing-box status`      | sing-box / sing-box-ts の状態                |
| `just sing-box logs`        | 直近 50 件のログ (sing-box + sidecar)        |
| `just sing-box logs 100`    | 直近 N 件のログ (件数指定)                   |
| `just sing-box logs-follow` | ログをリアルタイムで follow                  |
| `just sing-box update`      | コンテナイメージを更新 (podman auto-update)  |

> **再起動:** OCI ホスト上で `systemctl restart sing-box.service` (sidecar ごと再起動する場合は `systemctl restart sing-box-ts.service`) を直接実行する。`just oci-ssh` でホストに入ってから実行。

## 関連ドキュメント

- [ADR-012: sing-box forward proxy 採用](../../docs/design-docs/adr/012-sing-box-forward-proxy.md)
- [パターン: Tailscale サイドカー](../../docs/design-docs/patterns/tailscale-sidecar.md)
- [クライアント設定ガイド](../../docs/guides/sing-box-client-setup.md)
