# ADR-009: quadlet-nix によるコンテナ定義の統一

- **Status**: proposed
- **Date**: 2026-04-15

## Context

現状、コンテナの宣言経路がホストごとに分岐している。

| ホスト        | 実装                                           | 生成される unit         |
| ------------- | ---------------------------------------------- | ----------------------- |
| OCI NixOS     | `virtualisation.oci-containers.containers.*`   | `podman-<name>.service` |
| WSL2 (ollama) | 手書き Quadlet `.container` + `systemd --user` | `<name>.service` (user) |

この二重化には以下の問題がある。

- **原則との齟齬**: `ARCHITECTURE.md` の原則 #4 は「Podman Quadlet を使い、docker-compose は使わない」と定めるが、OCI 側は Quadlet を経由していない。`virtualisation.oci-containers` は Nix が `podman run` ベースの `.service` を直接生成する旧方式で、Quadlet の systemd generator は通っていない。
- **単一ソース化ができない**: 同じコンテナ構成を両ホストで共有できず、サービス追加時に nix 記述と `.container` 記述を別々に用意する必要がある。
- **Podman 側の推奨の逸脱**: Quadlet は Podman 4.4 以降の推奨統合機構であり、`podman generate systemd` 系を含む旧方式は順次非推奨化されている。
- **周辺計画との相性**: ADR-007 (VictoriaLogs) / ADR-008 (Alloy unified collector) で journald のラベル設計を進める際、unit 名の一貫性（`<name>.service`）を確保できた方がリレーベル定義が単純になる。

nixpkgs 本体にはまだ `virtualisation.quadlet.*` は存在せず（24.11 / 25.05 時点）、Quadlet を Nix で宣言的に扱うにはコミュニティの flake モジュールに依存する必要がある。

## Decision

`SEIAROTg/quadlet-nix` を flake input として導入し、全ホストの全コンテナサービスを Quadlet に統一する。

方針:

1. **OCI NixOS ホストの `services/*/nixos.nix` を `virtualisation.quadlet.containers.*` ベースに移行する**: 対象は `adguard-home` / `vaultwarden` / `gatus`。これにより ARCHITECTURE.md 原則 #4（「Podman Quadlet を使い」）の実態が全ホストで一致する（原則文自体の改訂は不要）。
2. **WSL2 ホスト (ollama) の手書き `.container` は Phase 2 として後続検討**: Nix ホストではないため、`quadlet-nix` の Home Manager モジュール採用可否は別判断。本 ADR のスコープ外。
3. **段階移行**: `gatus` → `vaultwarden` → `adguard-home` の順。`adguard-home` は fluent-bit サイドカー（ADR-006）を含むため最後に回す。
4. **パターンカタログを 2 モード併記に改訂する**: `docs/design-docs/patterns/quadlet-conventions.md` を「Nix 記述（NixOS ホスト、`quadlet-nix` 経由）」と「手書き `.container.tmpl` + gomplate（非 NixOS ホスト、ollama 系）」の両モードを併記する構成に書き換える。

採用候補として `mirkolenz/quadlet-nix` も検討したが、以下の理由で `SEIAROTg/quadlet-nix` を選定する。

- 採用実績が大きい（2026-04-15 時点で 338 stars / 93 commits / 2 open issues、v0 時代からの継続メンテナンス）。
- API が Quadlet の key-value 構造を 1:1 で Nix に写すため、手書き `.container` からの移行コストが低い。未マップキーは `rawConfig` で透過的に記述できる。
- rootful (NixOS module) と rootless (Home Manager module) を同一インターフェースで扱える。

## Consequences

### 良い面

- **単一パラダイム**: サービス追加時のコンテナ記述が全ホストで共通の語彙（Quadlet キー）になる。
- **Podman 推奨への追従**: 将来的な Podman アップデートでの互換性リスクが下がる。
- **unit 名の一貫性**: 全サービスが `<name>.service` に揃うため、ADR-008 (Alloy) の journald リレーベル設計が単純化される。
- **sops-nix との親和性**: `restartUnits = [ "<name>.service" ]` が引き続き透過的に機能する。
- **ADR-006 との整合**: AdGuard の fluent-bit サイドカーも Quadlet の `[Unit] Requires=` / `After=` で依存関係を自然に表現できる。

### 悪い面

- **外部 flake 依存の追加**: nixpkgs 外のモジュールへの依存が増える。`flake.lock` の更新時に追従が必要。upstream に `virtualisation.quadlet.*` が入った時点で移行を再評価する。
- **unit 命名変更に伴う周辺調整**: `podman-<name>.service` → `<name>.service` への変更により、sops-nix の `restartUnits`、Gatus による systemd 監視定義、ADR-008 の Alloy relabel 設計を同時に更新する必要がある。
- **healthcheck の既知不具合**: Podman の upstream issue `containers/podman#25034`（healthcheck が "starting" で固着）に遭遇する可能性がある。Nix 層の問題ではないが、ADR-006 の AdGuard healthcheck 実装時に挙動確認が必要。
- **ollama の扱いが分岐したまま残る**: Phase 1 の範囲では WSL2 は手書き Quadlet のまま。原則適用の完全統一は Phase 2 まで持ち越す。
- **aarch64 での実運用検証が必要**: OCI Ampere A1 (aarch64) 上での `quadlet-nix` の動作は本 ADR 採用時点で未検証。`gatus` パイロット移行で確認する。

## References

- [SEIAROTg/quadlet-nix](https://github.com/SEIAROTg/quadlet-nix)
- [Podman Quadlet 公式ドキュメント](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [ADR-006: AdGuard querylog fluent-bit サイドカー](./006-adguard-querylog-fluent-bit-sidecar.md)
- [ADR-008: Alloy unified collector](./008-alloy-unified-collector.md)
