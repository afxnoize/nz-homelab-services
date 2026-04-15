# OCI NixOS 構築 & デプロイ手順

OCI Always Free (Ampere A1 aarch64) に NixOS をインストールし、`just oci-deploy` でサービスをデプロイするまでの手順。

## 前提条件

- OCI アカウント (Always Free tier)
- ローカルに Nix がインストール済み (`nix develop` が使える状態)
- ローカル用の age 秘密鍵がある (`~/.config/sops/age/keys.txt`)
- Tailscale アカウント

## 1. OCI インスタンスの作成

OCI Console → Compute → Create Instance:

| 項目        | 値                                          |
| ----------- | ------------------------------------------- |
| Shape       | VM.Standard.A1.Flex (4 OCPU, 24 GB)         |
| Image       | Ubuntu 22.04 ARM                            |
| Boot volume | 200 GB                                      |
| SSH key     | `hosts/oci/vars.nix` に記載した公開鍵を登録 |

作成後、パブリック IP をメモしておく。

## 2. SSH 接続確認

```bash
ssh ubuntu@<PUBLIC_IP>
```

## 3. ブートボリュームのバックアップ

**nixos-anywhere は破壊的操作。必ず事前にバックアップを取る。**

OCI Console → Block Storage → Boot Volumes → Create Backup

## 4. vars.nix の SSH 公開鍵を確認

`hosts/oci/vars.nix` に実際の公開鍵が入っていることを確認する。nixos-anywhere 後はここに書いた鍵でしか SSH できなくなる。

## 5. nixos-anywhere の実行

```bash
cd <worktree or repo root>

nix run github:nix-community/nixos-anywhere -- \
  --flake .#oci \
  --build-on remote \
  --generate-hardware-config nixos-generate-config ./hosts/oci/hardware-configuration.nix \
  --ssh-option "StrictHostKeyChecking=no" \
  ubuntu@<PUBLIC_IP>
```

### ポイント

- `--generate-hardware-config` で `hardware-configuration.nix` が自動生成されてリポジトリに配置される。`configuration.nix` から import しているので、これがないとビルドが通らない
- `--build-on remote` で OCI 上でビルドする (aarch64 クロスビルドを避ける)
- Ubuntu のデフォルトユーザーは `ubuntu`。root ではなくこちらを指定する

### 完了後

nixos-anywhere がインスタンスを再起動する。再起動後は NixOS になっているため、SSH ユーザーが変わる。

```bash
ssh root@<PUBLIC_IP>
```

## 6. OCI 専用の age 鍵を生成・配置

ローカルと OCI で同じ age 秘密鍵を共有しない。ホストごとに鍵ペアを分離することで、片方が漏洩しても他方のシークレットは守られる。

### 6a. OCI 専用の鍵ペアを生成

ローカルで実行する。

```bash
age-keygen -o /tmp/oci-age.key
# Public key: age1yyyy... ← これをメモ
```

### 6b. `.sops.yaml` に OCI の公開鍵を追加

```yaml
creation_rules:
  - path_regex: secrets\.yaml$
    age: >-
      age1xxxx...,
      age1yyyy...
```

1 行目がローカル用、2 行目が OCI 用。sops は両方の公開鍵で Data Encryption Key を包むため、どちらの秘密鍵でも復号できる。

### 6c. 既存の secrets.yaml を再暗号化

`.sops.yaml` を更新したら、既存の暗号化ファイルを新しい鍵構成で再暗号化する。

```bash
# 念のためバックアップ
cp hosts/oci/secrets.yaml hosts/oci/secrets.yaml.bak

# 鍵構成を更新 (中身は変わらず、暗号化ヘッダだけ更新される)
sops updatekeys hosts/oci/secrets.yaml

# 各サービスの secrets.yaml も同様に
sops updatekeys services/gatus/secrets.yaml
# ... 他のサービスも同様
```

### 6d. OCI に秘密鍵を配置

```bash
ssh root@<PUBLIC_IP> 'mkdir -p /var/lib/sops-nix'
scp /tmp/oci-age.key root@<PUBLIC_IP>:/var/lib/sops-nix/age-key.txt
ssh root@<PUBLIC_IP> 'chmod 600 /var/lib/sops-nix/age-key.txt'
```

配置先は `configuration.nix` の `sops.age.keyFile` と一致させること。

### 6e. 生成した秘密鍵をローカルから削除

```bash
rm /tmp/oci-age.key
```

ローカルには OCI 用の秘密鍵を残さない。OCI にはローカル用の秘密鍵を置かない。

## 7. Tailscale への参加

authkey を使う方法とブラウザ認証の 2 通りがある。

### 方法 A: authkey

```bash
ssh root@<PUBLIC_IP> 'tailscale up --authkey=tskey-auth-...'
```

auth key は Tailscale admin console → Settings → Keys で生成する。

### 方法 B: ブラウザ認証

```bash
ssh root@<PUBLIC_IP> 'tailscale up'
```

表示された URL をブラウザで開いて認証する。authkey の発行が不要なので手軽。

## 8. secrets.yaml のホスト名を更新

`hosts/oci/secrets.yaml` にはプレースホルダーが入っている。Tailscale に参加したら実際のホスト名に更新する。

```bash
sops hosts/oci/secrets.yaml
# oci_host を Tailscale 上のホスト名に変更
```

これ以降、`just oci-ssh` や `just oci-deploy` が Tailscale 経由で動作する。

## 9. Tailscale 経由の SSH 確認

```bash
just oci-ssh
```

パブリック IP ではなく Tailscale 経由で接続できることを確認する。

## 10. 初回デプロイ

```bash
just oci-deploy
```

内部的には以下が実行される:

```
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#oci \
  --target-host root@<oci_host> \
  --build-host root@<oci_host>
```

- `--build-host root@<oci_host>` でリモートビルド (aarch64)
- `nix run nixpkgs#nixos-rebuild` でローカルに nixos-rebuild がなくても動作する
- ホスト名は `sops -d` で secrets.yaml から取得される

## 11. サービス起動確認

```bash
just oci-status
```

`podman-*` の systemd ユニットが active であることを確認する。個別のログは:

```bash
just oci-logs <service>   # e.g. just oci-logs adguard-home
```

## 日常の運用コマンド

| コマンド                  | 用途                           |
| ------------------------- | ------------------------------ |
| `just oci-deploy`         | configuration.nix の変更を反映 |
| `just oci-build`          | ビルドのみ (デプロイしない)    |
| `just oci-rollback`       | 前世代にロールバック           |
| `just oci-status`         | コンテナの状態確認             |
| `just oci-logs <service>` | サービスログ (直近 50 行)      |
| `just oci-ssh`            | SSH 接続                       |

## 既知の注意点

### hardware-configuration.nix は Git 管理する

`nixos-anywhere --generate-hardware-config` で生成されたファイルはコミットしておく。これがないと `nix flake check` も `nixos-rebuild` も失敗する。

### nixos-rebuild はローカルにない

ローカルマシンは NixOS ではないため `nixos-rebuild` コマンドがない。Justfile では `nix run nixpkgs#nixos-rebuild --` で代用している。

### sops の復号は just 起動時に走る

`oci_host` 変数は Justfile のトップレベルで定義されているため、OCI レシピを使わないときも `sops -d` が実行される。`nix develop` の外で `just --list` を叩くとエラーになる場合がある。

### Tailscale Serve の `:443` キー

Tailscale 1.96+ では serve.json の `Web` キーに `":443"` (ワイルドカード) を使うと TLS ハンドシェイクが失敗する。`"${TS_CERT_DOMAIN}:443"` を使うこと。`tailscale serve status` は正常に見えるのに HTTPS が通らない場合、これが原因。
