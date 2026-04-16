# Observability スタック

Alloy + VictoriaLogs + VictoriaMetrics + Grafana による観測スタック。OCI NixOS ホスト上で quadlet-nix (rootful モード) によりデプロイする。

## 構成

| コンポーネント  | ポート | network mode         | 役割                                              |
| --------------- | ------ | -------------------- | ------------------------------------------------- |
| VictoriaLogs    | 9428   | host                 | ログバックエンド (30d / 15GB)                     |
| VictoriaMetrics | 8428   | host                 | メトリクスバックエンド (90d / 10GB)               |
| Alloy           | 12345  | host                 | コレクタ (journald + node exporter + self scrape) |
| Grafana         | 3000   | container:grafana-ts | UI (Tailscale Serve で HTTPS 公開)                |
| grafana-ts      | —      | bridge + TS          | Tailscale sidecar                                 |

## 操作

```bash
just observability status         # ユニット稼働状況
just observability logs            # Alloy ログ (デフォルト)
just observability logs grafana    # Grafana ログ
just observability restart         # 全ユニット再起動
just observability vl-query        # VL 直接クエリ (直近 5 分)
just observability vm-query        # VM 直接クエリ (up)
```

## デプロイ

```bash
just oci-deploy                    # NixOS rebuild (observability 含む)
just oci-status                    # 全ユニット確認
```

## Secrets ローテーション

### Grafana admin パスワード

```bash
cd services/observability
sops secrets.yaml
# grafana.admin_password を変更して保存
just oci-deploy
```

### Tailscale authkey

Tailscale admin console で新しい reusable authkey を発行し、`secrets.yaml` の `grafana_ts.ts_authkey` を更新:

```bash
sops secrets.yaml
# grafana_ts.ts_authkey を変更して保存
just oci-deploy
```

## 関連ドキュメント

- [Spec: M1 Foundation](../../docs/superpowers/specs/2026-04-16-obs-m1-foundation-design.md)
- [ADR-007: VictoriaLogs](../../docs/design-docs/adr/007-log-backend-victorialogs.md)
- [ADR-008: Alloy 統一コレクタ](../../docs/design-docs/adr/008-alloy-unified-collector.md)
- [ADR-011: VictoriaMetrics](../../docs/design-docs/adr/011-metrics-backend-victoriametrics.md)
