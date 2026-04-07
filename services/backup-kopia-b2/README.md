# backup-kopia-b2

Kopia + Backblaze B2 による vault の定期バックアップ。daily スナップショットを systemd timer で自動実行し、保持ポリシーに従って世代管理する。

## 構成

| ファイル | 役割 |
|---------|------|
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
sops services/backup-kopia-b2/secrets.yaml
```

`b2_key_id`, `b2_secret_key`, `kopia_password` を記入する。

### 3. デプロイ

```bash
nix develop
just backup deploy
```

B2 接続 + ポリシー設定 + systemd timer 有効化を一発で実行する。

## コマンド

| コマンド | 説明 |
|---------|------|
| `just backup deploy` | connect + timer-on（初回セットアップ・設定更新） |
| `just backup connect` | B2 リポジトリ接続 + ポリシー設定 |
| `just backup backup` | スナップショット作成 |
| `just backup status` | 接続状態・スナップショット一覧 |
| `just backup timer-on` | systemd user timer 登録・有効化 |
| `just backup timer-off` | timer 削除 |

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

## 設計判断

→ [ADR-003: kopia config ファイルの分離](../../docs/design-docs/adr.md#adr-003-kopia-config-ファイルの分離)
→ [ADR-004: systemd service における kopia パス解決](../../docs/design-docs/adr.md#adr-004-systemd-service-における-kopia-パス解決)
→ [ADR-005: バックアップポリシーの外部ファイル化](../../docs/design-docs/adr.md#adr-005-バックアップポリシーの外部ファイル化)
