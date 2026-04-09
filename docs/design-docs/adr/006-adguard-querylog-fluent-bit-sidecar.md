# ADR-006: AdGuard Home クエリログを fluent-bit サイドカーで journald に転送

- **Status**: accepted
- **Date**: 2026-04-09

## Context

AdGuard Home はクエリログを独自の JSON ファイル（`querylog.json`）に書き出す。このログはコンテナ内に閉じており、ホスト側の journald から直接参照できない。

ホスト上の他サービスはすべて journald にログを集約しているため、クエリログだけ別経路になると運用が分断される。

## Decision

fluent-bit サイドカーコンテナを追加し、共有ボリューム経由で `querylog.json` を tail → stdout → journald に転送する。

```
adguard-home → querylog.json ─┐
                               │ shared volume (ro)
adguard-home-querylog (fluent-bit) ──┘→ tail → stdout → journald
```

## Consequences

- 良い面: クエリログが `journalctl -u adguard-home-querylog` で参照でき、他サービスと同じ運用フローに乗る
- 良い面: AdGuard Home 本体の設定や動作に手を加えない
- 悪い面: サイドカーコンテナが 1 つ増える（リソース消費は軽微）
- 悪い面: fluent-bit の設定ファイル（`fluent-bit.conf`, `parsers.conf`）の管理が増える
