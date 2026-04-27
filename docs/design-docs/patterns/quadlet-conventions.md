# Quadlet 構成規約

本プロジェクトには Quadlet の記述モードが 2 つある。どちらも最終的に systemd generator を経由して `<name>.service` という同一命名の unit を生成する（ADR-009 で統一）。

## モード選択

| モード | ホスト                          | 記述方法                              | デプロイ経路                                                            | 動作レベル |
| ------ | ------------------------------- | ------------------------------------- | ----------------------------------------------------------------------- | ---------- |
| Nix    | NixOS ホスト (OCI)              | `virtualisation.quadlet.containers.*` | `nixos-rebuild` 経由で `/etc/containers/systemd/` に配置                | rootful    |
| 手書き | 非 NixOS ホスト (WSL2 / ollama) | `.container` / `.container.tmpl`      | justfile の `cp` + `gomplate` で `~/.config/containers/systemd/` に配置 | rootless   |

判断基準: **ホストが NixOS なら Nix モード**、それ以外は手書きモード。WSL2 の ollama は Phase 2 で再評価予定（ADR-009 参照）。

## 共通事項

以下のキーは両モードで原則として常に指定する。

- `LogDriver=journald` — ログを journald に統一（ADR-007 / ADR-008 参照）
- `HealthCmd` — ヘルスチェックコマンド。不要時は明示的に無効化（手書きは `HealthCmd=none`、Nix は `healthCmd` 省略）
- `Restart=always` — サービスはクラッシュ時に自動再起動
- サービス起動: 手書きは `[Install] WantedBy=default.target`、Nix は `autoStart = true`

systemd unit の依存関係（`Requires` / `After`）はサイドカー構成などで必要に応じて追加する。

## Nix モード

`SEIAROTg/quadlet-nix` の `virtualisation.quadlet.containers.<name>` に Quadlet キーを 1:1 で写す。未マップのキーは `rawConfig` で透過記述できる。

### 基本形

```nix
virtualisation.quadlet.containers = {
  gatus = {
    autoStart = true;
    containerConfig = {
      image = "ghcr.io/twin/gatus:stable";
      volumes = [
        "gatus-data:/data"
        "${config.sops.templates."gatus-config.yaml".path}:/config/config.yaml:ro"
      ];
      logDriver = "journald";
    };
    unitConfig = {
      Requires = [ "gatus-ts.service" ];
      After = [ "gatus-ts.service" ];
    };
    serviceConfig.Restart = "always";
  };
};
```

### ファイル種別

| 拡張子            | 対応キー            | 用途               |
| ----------------- | ------------------- | ------------------ |
| `.container` 相当 | `containers.<name>` | コンテナ本体       |
| `.volume` 相当    | `volumes.<name>`    | 名前付きボリューム |
| `.network` 相当   | `networks.<name>`   | 専用ネットワーク   |

### 秘匿値の扱い

`sops-nix` の placeholder を `sops.templates.*` で展開し、そのパスを `environmentFiles` / `volumes` にバインドする。`restartUnits = [ "<name>.service" ]` で secret ローテーション時の再起動が透過的に効く（Quadlet でも unit 名は `<name>.service` なので `podman-` プレフィックス不要）。

### サイドカー

Tailscale などのサイドカーは `networks = [ "container:<sidecar>.service" ]` と `unitConfig.Requires` / `After` で依存関係を表現する。参考: [tailscale-sidecar.md](./tailscale-sidecar.md)。

## 手書きモード

### ファイル種別

| 拡張子            | 用途                             | デプロイ方法                        |
| ----------------- | -------------------------------- | ----------------------------------- |
| `.container`      | 静的なコンテナ定義               | `cp` でそのままコピー               |
| `.container.tmpl` | 秘匿値や動的値を含むコンテナ定義 | `sops exec-env` + `gomplate` で展開 |
| `.volume`         | 名前付きボリューム               | `cp` でそのままコピー               |

### 基本形

```ini
[Container]
AutoUpdate=registry     # podman auto-update でイメージ自動更新
LogDriver=journald
HealthCmd=...           # 不要なら HealthCmd=none

[Service]
Restart=always

[Install]
WantedBy=default.target
```

### デプロイ先

`~/.config/containers/systemd/`（`$XDG_CONFIG_HOME/containers/systemd/`）

`systemctl --user daemon-reload` で unit を再生成し、`systemctl --user start <name>.service` で起動する。

## References

- [ADR-009: quadlet-nix によるコンテナ定義の統一](../adr/009-quadlet-nix-unification.md)
- [Podman Quadlet 公式ドキュメント](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [SEIAROTg/quadlet-nix](https://github.com/SEIAROTg/quadlet-nix)
