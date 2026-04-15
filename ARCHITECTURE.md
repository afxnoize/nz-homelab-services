# Architecture

**Owner: Agent** — コードと同期して保守する。

## 設計思想

このリポジトリは4つの原則に従って設計されている。

1. **シークレットはディスクに平文で残さない**  
   秘匿値は SOPS で age 暗号化してリポジトリ管理する。デプロイ時に `sops exec-env` で一時的に環境変数へ展開し、gomplate がテンプレートを展開したらその後は消える。

2. **サービスは自己完結する**  
   各サービスは `services/<name>/` 以下に必要なものをすべて持つ。Justfile、secrets.yaml、quadlet ファイル、README.md がそろえば独立して運用できる。

3. **環境は Nix で再現可能にする**  
   ツールチェイン（SOPS, gomplate, just 等）はすべて `flake.nix` でバージョン固定する。ホストへの暗黙的な依存は持たない。

4. **systemd ネイティブで動かす**  
   Podman Quadlet を使い、docker-compose は使わない。コンテナが systemd ユニットとして管理されるため、ホスト再起動時の自動起動やログ統合が自然に得られる。

---

## パターンカタログ

| パターン                                                                 | 概要                                                            |
| ------------------------------------------------------------------------ | --------------------------------------------------------------- |
| [Tailscale Sidecar](docs/design-docs/patterns/tailscale-sidecar.md)      | Tailscale sidecar でネットワーク名前空間を共有し Tailnet に公開 |
| [シークレットパイプライン](docs/design-docs/patterns/secret-pipeline.md) | SOPS + gomplate で秘匿値をテンプレートに注入                    |
| [ログ戦略](docs/design-docs/patterns/log-strategy.md)                    | journald 集約（Phase 1）と Grafana + Loki 構想（Phase 2）       |
| [Quadlet 構成規約](docs/design-docs/patterns/quadlet-conventions.md)     | ファイル種別・標準設定・デプロイ先                              |
| [公開モデル](docs/design-docs/patterns/exposure-models.md)               | Tailscale Serve vs localhost バインドの選択基準                 |

## ガイド

| ガイド                                                   | 概要                                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| [サービス追加チェックリスト](docs/guides/add-service.md) | 新サービス追加時のディレクトリ構造・Justfile・ドキュメント更新手順 |
| [デプロイフロー](docs/guides/deploy-flow.md)             | `just <service> deploy` の内部処理ステップ                         |
