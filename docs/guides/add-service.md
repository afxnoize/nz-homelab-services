# サービス追加チェックリスト

新しいサービスを `services/<name>/` に追加するときの手順。

> このガイドは**手書き Quadlet モード**（WSL2 等の非 NixOS ホスト）が対象。OCI NixOS ホストに載せる場合は `services/<name>/nixos.nix` で `virtualisation.quadlet.containers.*` を定義し、デプロイは `just oci-deploy`（nixos-rebuild）で行う。justfile には deploy 系レシピを置かず観測・メンテ用のみ用意する（observability / sing-box が参考）。詳細は [oci-setup.md](oci-setup.md) と [ADR-009](../design-docs/adr/009-quadlet-nix-unification.md)。

## ディレクトリ構造

```
services/<name>/
├── justfile
├── secrets.yaml              # SOPS で暗号化して Git 管理
├── README.md
└── quadlet/
    ├── <name>.container(.tmpl)
    ├── <name>-data.volume
    └── (Tailscale Serve を使う場合)
        ├── <name>-ts.container.tmpl
        ├── <name>-ts-serve.json.tmpl
        └── <name>-ts-state.volume
```

## justfile 標準レシピ

以下のレシピをすべて実装する。

| レシピ        | 内容                                                      |
| ------------- | --------------------------------------------------------- |
| `deploy`      | テンプレート展開 → quadlet dir へコピー → `daemon-reload` |
| `start`       | `systemctl --user start <name>`                           |
| `stop`        | `systemctl --user stop <name>`                            |
| `restart`     | `systemctl --user restart <name>`                         |
| `status`      | `systemctl --user status <name> --no-pager`               |
| `logs`        | `journalctl --user -u <name> --no-pager -n 50`            |
| `logs-follow` | `journalctl --user -u <name> -f`                          |
| `update`      | `podman auto-update`                                      |

## Root justfile への登録

```just
mod <name> 'services/<name>'
```

`deploy-all` / `status-all` が定義されていれば、そこにも追加する。

## ドキュメント更新

AGENTS.md の機能概要・リポジトリ構成に追記する（同一コミット）。
