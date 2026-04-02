# tool-vault-backup-kopia-b2

Kopia + Backblaze B2 による wisdom vault の定期バックアップ。

## 構成

| ファイル | 役割 |
|---------|------|
| `flake.nix` | kopia / sops / age パッケージ提供 + 4つの app |
| `secrets.yaml` | B2 接続情報（sops + age で暗号化） |
| `systemd/` | systemd user unit（daily timer） |

## セットアップ

### 1. B2 キー作成

```bash
b2 key create \
  --bucket ***REDACTED*** \
  ***REDACTED*** \
  listBuckets,listFiles,readFiles,writeFiles,deleteFiles,readBucketEncryption,writeBucketEncryption
```

### 2. secrets 編集

```bash
sops secrets.yaml
```

`b2_key_id`, `b2_secret_key`, `kopia_password` を記入する。

### 3. リポジトリ接続

```bash
nix run .#setup
```

### 4. ポリシー設定

```bash
nix develop -c kopia policy set ~/Documents/wisdom \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

### 5. systemd timer 有効化

```bash
nix run .#install-timer
```

## コマンド

| コマンド | 説明 |
|---------|------|
| `nix run .#backup` | 手動スナップショット作成 |
| `nix run .#setup` | B2 リポジトリ接続（secrets.yaml から読み取り） |
| `nix run .#install-timer` | systemd user timer 登録・有効化 |
| `nix run .#uninstall-timer` | timer 削除 |
| `nix develop` | kopia / sops / age が使えるシェル |

## 暗号化

- **B2 認証情報**: sops + age（`secrets.yaml`）
- **kopia リポジトリ**: AES256-GCM-HMAC-SHA256
- **スナップショット圧縮**: zstd
- **vault 自体**: Cryptomator（三重暗号化）

## 保持ポリシー

| 種別 | 世代数 |
|------|--------|
| daily | 7 |
| weekly | 4 |
| monthly | 6 |
