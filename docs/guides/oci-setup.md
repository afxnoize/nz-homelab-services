# OCI NixOS 構築 & デプロイ手順

OCI Always Free (Ampere A1 aarch64) に NixOS をインストールし、`just oci deploy` でサービスをデプロイするまでの手順。

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

ローカルと OCI で同じ age 秘密鍵を共有しない。ただし鍵ペアを分けるだけでは足りない。OCI の公開鍵を宛先に入れたファイルは、OCI の秘密鍵で復号できる。OCI に載せないサービスの `secrets.yaml` まで宛先に入れると、OCI が侵害されたときにバックアップ用の B2 認証情報まで読まれる。宛先は OCI が実際に復号するファイルに限る (6b)。

### 6a. OCI 専用の鍵ペアを生成

ローカルで実行する。

```bash
age-keygen -o /tmp/oci-age.key
# Public key: age1yyyy... ← これをメモ
```

### 6b. `.sops.yaml` に OCI の公開鍵を追加

```yaml
creation_rules:
  # OCI にデプロイするサービス: ローカル + OCI
  - path_regex: (^|/)services/(adguard-home|vaultwarden|gatus|observability|sing-box)/secrets\.yaml$
    age: >-
      age1xxxx...,
      age1yyyy...
  # それ以外 (hosts/oci, backup-kopia-b2, ollama, 新規サービス): ローカルのみ
  - path_regex: secrets\.yaml$
    age: age1xxxx...
```

`age1xxxx...` がローカル用、`age1yyyy...` が OCI 用。1 つ目のルールに一致するファイルは、sops が両方の公開鍵で Data Encryption Key を包むため、どちらの秘密鍵でも復号できる。

- ルールは上から順に評価され、最初に一致したものだけが使われる。包括ルールを先頭に置くと許可リストが効かなくなる
- `hosts/oci/secrets.yaml` は `hosts/oci/justfile` がローカルで読むだけで、OCI 上では復号しない。`backup-kopia-b2` と `ollama` は OCI に載せない。この 3 つがローカルのみになる理由はそこにある
- ルールが効くのは新規作成時と `sops updatekeys` 時だけ。既存ファイルの宛先は `updatekeys` をかけるまで変わらない

### 6c. 既存の secrets.yaml を再暗号化

`.sops.yaml` を更新したら、既存の暗号化ファイルに `sops updatekeys` をかけて宛先をルールに揃える。`updatekeys` は 1 回に 1 ファイルしか受け付けない。

```bash
# 1 件目は -y を付けずに、追加・削除される宛先を目で確認する
sops updatekeys hosts/oci/secrets.yaml

# 残りは確認なしで
for f in services/*/secrets.yaml; do sops updatekeys -y "$f"; done

# 宛先の数を確認する。許可リストの 5 サービスは 2、それ以外は 1
for f in hosts/oci/secrets.yaml services/*/secrets.yaml; do
  echo "$(grep -c 'recipient: ' "$f") $f"
done
```

値は変わらず、`sops.age` の宛先リストだけが更新される。バックアップは git で足りる。`.bak` を作ると、旧い宛先のままの暗号文が手元に残る。

git 履歴には旧い宛先の暗号文が残る。宛先から外した鍵が漏れた疑いがあるときは、`updatekeys` だけでは足りず、シークレットの値そのものを入れ替える。

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

これ以降、`just oci ssh` や `just oci deploy` が Tailscale 経由で動作する。

## 9. Tailscale 経由の SSH 確認

```bash
just oci ssh
```

パブリック IP ではなく Tailscale 経由で接続できることを確認する。

## 10. 初回デプロイ

```bash
just oci deploy
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
just oci status
```

`podman-*` の systemd ユニットが active であることを確認する。個別のログは:

```bash
just oci logs <service>   # e.g. just oci logs adguard-home
```

## 日常の運用コマンド

| コマンド                       | 用途                                                                |
| ------------------------------ | ------------------------------------------------------------------- |
| `just oci deploy`              | configuration.nix の変更を反映 (switch)                             |
| `just oci boot`                | 次回起動用に登録 (switch inhibitor で拒否されるメジャー更新、K-022) |
| `just oci build`               | ビルドのみ (デプロイしない)                                         |
| `just oci rollback`            | 前世代にロールバック                                                |
| `just oci update-image <name>` | コンテナイメージを更新 (差分があるときだけ restart)                 |
| `just oci update-tailscale`    | Tailscale sidecar を一括更新                                        |
| `just oci status`              | コンテナの状態確認                                                  |
| `just oci logs <service>`      | サービスログ (直近 50 行)                                           |
| `just oci ssh`                 | SSH 接続                                                            |

`update-image` は旧イメージを `localhost/<name>:pre-<日付>` として残す。失敗時は、そのタグを `:latest` に付け直して restart すれば戻せる (DB を持つサービスはスキーマ移行後は戻せないため、更新前にバックアップを取る)。

## 既知の注意点

### hardware-configuration.nix は Git 管理する

`nixos-anywhere --generate-hardware-config` で生成されたファイルはコミットしておく。これがないと `nix flake check` も `nixos-rebuild` も失敗する。

### nixos-rebuild はローカルにない

ローカルマシンは NixOS ではないため `nixos-rebuild` コマンドがない。justfile では `nix run nixpkgs#nixos-rebuild --` で代用している。

### sops の復号は just 起動時に走る

`oci_host` 変数は justfile のトップレベルで定義されているため、OCI レシピを使わないときも `sops -d` が実行される。`nix develop` の外で `just --list` を叩くとエラーになる場合がある。

### Tailscale Serve の `:443` キー

Tailscale 1.96+ では serve.json の `Web` キーに `":443"` (ワイルドカード) を使うと TLS ハンドシェイクが失敗する。`"${TS_CERT_DOMAIN}:443"` を使うこと。`tailscale serve status` は正常に見えるのに HTTPS が通らない場合、これが原因。
