# tool-vault-backup-kopia-b2

Kopia + Backblaze B2 による vault の定期バックアップ。

## 構成

| ファイル | 役割 |
|---------|------|
| `flake.nix` | kopia / sops / age / yq / just パッケージ提供 |
| `Justfile` | 操作コマンド定義 |
| `secrets.yaml` | B2 接続情報（sops + age で暗号化） |
| `policy.yaml` | 保持ポリシー設定 |
| `sources.yaml` | バックアップ対象パス（gitignore） |
| `systemd/` | systemd user unit（daily timer） |

## セットアップ

### 1. B2 キー作成

```bash
b2 key create \
  --bucket nz-vault-backup \
  nz-vault-backup \
  listBuckets,listFiles,readFiles,writeFiles,deleteFiles,readBucketEncryption,writeBucketEncryption
```

### 2. secrets 編集

```bash
sops secrets.yaml
```

`b2_key_id`, `b2_secret_key`, `kopia_password` を記入する。

### 3. デプロイ

```bash
nix develop
just deploy
```

B2 接続 + ポリシー設定 + systemd timer 有効化を一発で実行する。

## コマンド

`nix develop` に入って `just` を使う。

| コマンド | 説明 |
|---------|------|
| `just deploy` | connect + timer-on（初回セットアップ・設定更新） |
| `just connect` | B2 リポジトリ接続 + ポリシー設定 |
| `just backup` | スナップショット作成 |
| `just status` | 接続状態・スナップショット一覧 |
| `just timer-on` | systemd user timer 登録・有効化 |
| `just timer-off` | timer 削除 |

## 暗号化

- **B2 認証情報**: sops + age（`secrets.yaml`）
- **kopia リポジトリ**: AES256-GCM-HMAC-SHA256
- **スナップショット圧縮**: zstd
- **vault 自体**: Cryptomator（三重暗号化）

## 保持ポリシー

`policy.yaml` で管理。

| 種別 | 世代数 |
|------|--------|
| daily | 7 |
| weekly | 4 |
