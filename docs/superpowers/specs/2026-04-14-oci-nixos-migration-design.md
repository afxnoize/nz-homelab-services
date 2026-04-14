# OCI NixOS マイグレーション設計

## 概要

OCI Always Free Tier（Ampere A1: 4コア / 24GB / 200GB）に NixOS を導入し、
既存の4サービスを NixOS ネイティブで宣言的に管理する。

### 移行対象

| サービス | 移行 | 備考 |
|---|---|---|
| adguard-home | 対象（先行） | Tailscale DNS に追加して段階移行 |
| vaultwarden | 対象 | データ移行あり（vault DB） |
| gatus | 対象 | 履歴は捨てて新規 |
| backup-kopia-b2 | 対象 | ソース未定（元マシンにしかない） |
| ollama | 対象外 | WSL2 + GPU に残留 |

### 移行先スペック

- OCI Always Free Ampere A1
- 4 OCPU / 24 GB RAM / 200 GB ブートボリューム
- aarch64-linux

---

## アーキテクチャ

### 技術選定

| レイヤー | 選定 | 理由 |
|---|---|---|
| OS | NixOS (nixos-anywhere で導入) | 宣言的管理、ロールバック、再現性 |
| コンテナ | `virtualisation.oci-containers` (rootful Podman) | NixOS ネイティブ統合 |
| シークレット | sops-nix | gomplate 不要。NixOS に統合 |
| ネットワーク | Tailscale sidecar パターン維持 | 既存パターンの踏襲 |
| デプロイ | `nixos-rebuild switch --target-host` | 追加ツール不要 |
| ディスク | disko | パーティションも宣言的管理 |
| ホスト名秘匿 | sops で暗号化、Justfile から復号参照 | git にマシン名を出さない |

### デプロイフロー

```
ローカル (nix develop)
  │  just oci-deploy
  │    → sops -d でホスト名復号
  │    → nixos-rebuild switch --flake .#oci --target-host root@<host>
  ▼
OCI VM (NixOS aarch64)
  ├─ nix build (VM 上)
  ├─ sops-nix がシークレット復号 → /run/secrets/
  └─ switch (コンテナ定義・systemd ユニット適用)
```

### ネットワークトポロジー

```
Tailnet (Tailscale VPN)
  ├─ adguard-home.<domain>:443 → TS Serve → localhost:3000 (Web UI)
  │                            + :53 UDP/TCP (DNS)
  ├─ vaultwarden.<domain>:443  → TS Serve → localhost:80
  ├─ gatus.<domain>:443        → TS Serve → localhost:8080
  └─ (backup-kopia-b2 は外部公開なし、B2 への outbound のみ)
```

---

## リポジトリ構造

```
flake.nix                          # nixosConfigurations.oci 追加
hosts/
└── oci/
    ├── configuration.nix          # ホスト設定 (boot, network, users, tailscale, podman)
    ├── disko.nix                  # ディスクレイアウト (ESP + root)
    ├── hardware-configuration.nix # nixos-anywhere が生成
    ├── vars.nix                   # ホスト変数 (adminUser, sshKeys)
    └── secrets.yaml               # oci_host 等 (sops 暗号化)
services/
├── adguard-home/
│   ├── nixos.nix                  # NixOS モジュール (新規)
│   ├── quadlet/                   # 既存 Quadlet (レガシー参照)
│   ├── secrets.yaml               # ts_authkey (sops 暗号化)
│   ├── Justfile
│   └── README.md
├── vaultwarden/
│   ├── nixos.nix
│   ├── quadlet/
│   ├── secrets.yaml
│   └── ...
├── gatus/
│   ├── nixos.nix
│   ├── secrets.yaml               # ts_authkey, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
│   └── ...
├── backup-kopia-b2/
│   ├── nixos.nix
│   ├── secrets.yaml               # B2 credentials, kopia_password
│   └── ...
└── ollama/                        # 変更なし (WSL2 に残留)
    └── ...
```

### 設計原則

- **サービスは自己完結**: 各 `services/<name>/` に nixos.nix を含め、NixOS モジュール・シークレット・ドキュメントを同一ディレクトリに配置
- **ホスト設定は薄く**: `hosts/oci/configuration.nix` はサービスの import と OS レベルの設定のみ
- **既存ファイルは残す**: Quadlet テンプレートは削除せず、レガシー参照・ollama 用に維持

---

## flake.nix

```nix
{
  description = "Host service management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix }: {

    # 既存: devShell (x86_64)
    devShells.x86_64-linux.default = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in pkgs.mkShell {
      packages = with pkgs; [
        kopia sops age yq-go just gomplate
      ];
    };

    # 新規: OCI NixOS (aarch64)
    nixosConfigurations.oci = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/oci/configuration.nix
      ];
    };

    # 既存: default package
    packages.x86_64-linux.default =
      nixpkgs.legacyPackages.x86_64-linux.kopia;
  };
}
```

---

## ホスト設定

### hosts/oci/configuration.nix

```nix
{ config, pkgs, ... }:
let vars = import ./vars.nix;
in {
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../services/adguard-home/nixos.nix
    ../../services/vaultwarden/nixos.nix
    ../../services/gatus/nixos.nix
    ../../services/backup-kopia-b2/nixos.nix
  ];

  # Boot (OCI ARM)
  boot.initrd.kernelModules = [ "iscsi_tcp" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking
  networking.hostName = "oci-nix";

  # Tailscale (host-level)
  services.tailscale.enable = true;

  # Podman
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # User
  users.users.${vars.adminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = vars.sshKeys;
  };
  nix.settings.trusted-users = [ vars.adminUser ];

  # SSH
  services.openssh.enable = true;

  # Packages
  environment.systemPackages = with pkgs; [ vim git just ];

  # sops-nix
  sops.defaultSopsFile = ../../.sops.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/age-key.txt";

  system.stateVersion = "24.11";
}
```

### hosts/oci/vars.nix

```nix
{
  adminUser = "noize";
  sshKeys = [
    "ssh-ed25519 AAAAC3Nza..."
  ];
}
```

### hosts/oci/disko.nix

```nix
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";  # OCI iSCSI boot volume
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

---

## サービス NixOS モジュール

### 構造パターン

各 `services/*/nixos.nix` は以下の構造を取る:

1. **sops シークレット定義** — `sops.secrets."<service>/*"`
2. **Tailscale sidecar コンテナ** — Serve 設定含む
3. **アプリケーションコンテナ** — sidecar のネットワーク名前空間を共有
4. **補助リソース** (必要に応じて) — systemd timer、設定ファイル等

### 例: services/adguard-home/nixos.nix

```nix
{ config, pkgs, ... }:
let
  tsServeConfig = builtins.toJSON {
    TCP."443".HTTPS = true;
    Web."443".Handlers."/".Proxy = "http://127.0.0.1:3000";
  };
in {
  # Secrets
  sops.secrets."adguard-home/ts_authkey" = {
    sopsFile = ./secrets.yaml;
  };

  # Tailscale sidecar
  virtualisation.oci-containers.containers.adguard-home-ts = {
    image = "ghcr.io/tailscale/tailscale:latest";
    environment = {
      TS_STATE_DIR = "/var/lib/tailscale";
      TS_SERVE_CONFIG = "/config/serve.json";
      TS_EXTRA_ARGS = "--accept-dns=false";
    };
    environmentFiles = [
      config.sops.secrets."adguard-home/ts_authkey".path
    ];
    volumes = [
      "adguard-home-ts-state:/var/lib/tailscale"
      "${pkgs.writeText "serve.json" tsServeConfig}:/config/serve.json:ro"
    ];
  };

  # AdGuard Home
  virtualisation.oci-containers.containers.adguard-home = {
    image = "adguard/adguardhome:latest";
    dependsOn = [ "adguard-home-ts" ];
    extraOptions = [ "--network=container:adguard-home-ts" ];
    volumes = [
      "adguard-home-data:/opt/adguardhome/work"
    ];
  };
}
```

### Quadlet → NixOS 対応表

| Quadlet (現在) | NixOS (移行後) |
|---|---|
| `*.container.tmpl` + gomplate | `virtualisation.oci-containers.containers.*` |
| `*.volume` | volumes は NixOS が自動作成 |
| `sops exec-env` + gomplate | `sops.secrets.*` + `environmentFiles` |
| `Network=container:systemd-*-ts` | `extraOptions = ["--network=container:*-ts"]` |
| Tailscale Serve JSON テンプレート | `pkgs.writeText` で Nix 内に生成 |
| systemd timer | `systemd.timers.*` / `systemd.services.*` |

---

## デプロイワークフロー

### Justfile

```just
# Justfile (root)

# 既存 (元ホスト用)
mod ollama 'services/ollama'

# OCI
oci_host := `sops -d --extract '["oci_host"]' hosts/oci/secrets.yaml`

[group('oci')]
oci-deploy:
    nixos-rebuild switch --flake .#oci --target-host root@{{oci_host}}

[group('oci')]
oci-build:
    nixos-rebuild build --flake .#oci --target-host root@{{oci_host}}

[group('oci')]
oci-rollback:
    nixos-rebuild switch --flake .#oci --target-host root@{{oci_host}} --rollback

[group('oci')]
oci-status:
    ssh root@{{oci_host}} 'systemctl list-units "podman-*" --no-pager'
```

### 運用コマンド対照表

| 操作 | 現在 | 移行後 |
|---|---|---|
| 全デプロイ | `just deploy-all` | `just oci-deploy` |
| ロールバック | 手動 | `just oci-rollback` |
| ビルド確認 | なし | `just oci-build` |
| ログ確認 | `just gatus logs` | `ssh root@<host> journalctl -u podman-gatus` |
| 状態確認 | `just status-all` | `just oci-status` |

---

## 移行フェーズ

### Phase 0: OCI VM の NixOS 化

1. 既存の Oracle Linux 9 インスタンスを削除
2. Ubuntu 22.04 ARM で新規作成
3. ブートボリュームのスナップショットを取得
4. ローカルから nixos-anywhere を実行:
   ```bash
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#oci \
     root@<OCI-VM-public-IP>
   ```
5. 再起動後、SSH で接続確認
6. age 鍵を配置: `scp age-key.txt root@<IP>:/var/lib/sops-nix/age-key.txt`
7. `tailscale up --authkey=tskey-...` で Tailnet に参加

### Phase 1: adguard-home 先行移行

1. `services/adguard-home/nixos.nix` を作成
2. `just oci-deploy` で適用
3. OCI の adguard-home が Tailscale Serve で公開されることを確認
4. Tailscale admin console で DNS サーバーに OCI の adguard-home を追加（既存は残す）
5. 名前解決が両方から応答されることを確認
6. 問題なければ旧 adguard-home を DNS サーバーから除外

### Phase 2: 残りサービスの移行

7. vaultwarden のデータ移行:
   ```bash
   # 旧ホスト
   podman volume export vaultwarden-data -o vaultwarden-data.tar
   scp vaultwarden-data.tar root@<host>:/tmp/
   # OCI
   podman volume create vaultwarden-data
   podman volume import vaultwarden-data /tmp/vaultwarden-data.tar
   ```
8. `services/vaultwarden/nixos.nix` を作成、デプロイ、動作確認
9. `services/gatus/nixos.nix` を作成、デプロイ、監視対象を OCI 側に向ける
10. `services/backup-kopia-b2/nixos.nix` を作成、デプロイ（ソースは後日設定）
11. 旧ホストの vaultwarden, gatus, backup を停止

### Phase 3: クリーンアップ

12. 旧ホストの Quadlet ファイル・systemd ユニットを無効化
13. OCI で全サービスの正常性確認
14. ドキュメント更新 (README, ARCHITECTURE.md, 各サービス README)

---

## データ移行

| ボリューム | 中身 | 移行 | 理由 |
|---|---|---|---|
| vaultwarden-data | Bitwarden vault DB | 必須 | パスワードデータ |
| gatus-data | ヘルスチェック履歴 | 不要 | 新規作成で問題ない |
| adguard-home-data | DNS 設定、クエリログ | 不要 | AdGuardHome.yaml は git 管理 |
| *-ts-state | Tailscale 認証情報 | 不要 | 新しい auth key で参加 |
| backup-kopia-b2 | なし | 不要 | `kopia repository connect` し直す |

---

## 初回セットアップで必要な手動作業

| 作業 | タイミング | 内容 |
|---|---|---|
| age 鍵配置 | Phase 0 | `/var/lib/sops-nix/age-key.txt` に配置 |
| Tailscale 認証 | Phase 0 | ホストレベルの `tailscale up` |
| Tailscale auth key 発行 | Phase 1-2 | 各サービスの sidecar 用 |
| DNS 設定変更 | Phase 1 | Tailscale admin console で DNS サーバー追加 |
| vaultwarden データ移行 | Phase 2 | `podman volume export/import` |
| kopia リポジトリ接続 | Phase 2 | `kopia repository connect` |

---

## 変更されないもの

- `services/ollama/` — WSL2 に残留、変更なし
- Tailscale sidecar パターン — コンテナ構成は同じ、定義方法が Quadlet → NixOS に変わるだけ
- シークレットの暗号化方式 — SOPS + age のまま、復号パイプラインが gomplate → sops-nix に変わる
- 既存の Quadlet ファイル — 削除せずレガシー参照として残す
