# Design Documents

設計文書のカタログ。各文書には検証ステータスを付与する。

## Status

| Status     | 意味                     |
| ---------- | ------------------------ |
| `draft`    | 草案。レビュー未実施     |
| `verified` | コードと一致を確認済み   |
| `stale`    | コードと乖離あり。要更新 |

## Documents

| Document               | Status   | Last Verified |
| ---------------------- | -------- | ------------- |
| [adr/](adr/README.md)  | verified | 2026-06-10    |
| [patterns/](patterns/) | verified | 2026-06-10    |

ADR は 001〜012 まで存在（最新: ADR-012 sing-box forward proxy / 2026-05-20）。

## Design Documents

- [OCI NixOS マイグレーション設計](../../docs/superpowers/specs/2026-04-14-oci-nixos-migration-design.md) — OCI Always Free への NixOS 移行設計
- [sing-box 選択的 forward proxy 設計](../../docs/superpowers/specs/2026-05-20-sing-box-forward-proxy-design.md) — Tailnet 内 forward proxy 設計
