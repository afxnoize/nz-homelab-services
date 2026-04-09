# ログ戦略

すべてのサービスログを journald に集約する。コンテナの標準出力は `LogDriver=journald` で自動的に journald に入るが、アプリケーション固有のログファイルは別途対応が必要。

## 現在（Phase 1 — journald 集約）

```
コンテナ stdout/stderr ──► LogDriver=journald ──► journalctl -u <unit>

アプリ固有ログファイル ──► fluent-bit sidecar ──► stdout ──► journald
                          (shared volume, ro)
```

- 標準: `LogDriver=journald` を全コンテナに設定（[Quadlet 構成規約](quadlet-conventions.md)を参照）
- 例外: アプリがファイルにしかログを書かない場合（AdGuard Home の querylog 等）は fluent-bit サイドカーで tail → stdout → journald に転送する（[ADR-006](../adr/006-adguard-querylog-fluent-bit-sidecar.md)）

## 将来（Phase 2 — Grafana + Loki）

OCI 移行を想定し、journald 依存から Grafana + Loki スタックへの移行を検討中。

```
コンテナ ──► Alloy (or fluent-bit) ──► Loki ──► Grafana
```

- ログ収集: Alloy または fluent-bit。メトリクスも取りたければ Alloy を採用するか、fluent-bit と併用する
- Phase 1 の fluent-bit サイドカーは Phase 2 でも転用可能（出力先を stdout から Loki に切り替えるだけ）
- 移行判断は OCI 環境が確定した時点で ADR として記録する
