# OCI CLI リファレンス (WIP)

OCI Always Free (Ampere A1) の運用で使う OCI CLI コマンド集。

> **Status:** WIP — 構築時に使ったコマンドを中心にまとめている。網羅的ではない。

## セットアップ

### 設定ファイル

```bash
# デフォルト
~/.oci/config

# カスタムパス (環境変数で指定)
export OCI_CLI_CONFIG_FILE=~/.config/oci/config
```

設定ファイルには tenancy OCID, user OCID, fingerprint, key_file, region が必要。OCI Console → Profile → API Keys で生成できる。

### インストール確認

```bash
oci --version
oci iam region list --output table   # 認証が通ることを確認
```

## 環境変数

操作のたびに OCID を指定するのは面倒なので、シェルの先頭で設定しておく。

```bash
# Tenancy (Compartment) OCID
export TENANCY="ocid1.tenancy.oc1..xxxxx"

# Instance OCID
export INSTANCE_ID="ocid1.instance.oc1.ap-tokyo-1.xxxxx"
```

OCID は OCI Console の各リソース詳細ページからコピーできる。

## Compute

### インスタンス状態の確認

```bash
oci compute instance get \
  --instance-id "$INSTANCE_ID" \
  --query 'data."lifecycle-state"' \
  --raw-output
```

出力例: `RUNNING`, `STOPPED`, `TERMINATED`

### インスタンスの停止・起動

```bash
# 停止 (graceful)
oci compute instance action \
  --instance-id "$INSTANCE_ID" \
  --action SOFTSTOP

# 起動
oci compute instance action \
  --instance-id "$INSTANCE_ID" \
  --action START

# 強制停止
oci compute instance action \
  --instance-id "$INSTANCE_ID" \
  --action STOP
```

### インスタンス一覧

```bash
oci compute instance list \
  --compartment-id "$TENANCY" \
  --query 'data[?!"lifecycle-state"==`TERMINATED`].{"name":"display-name","state":"lifecycle-state","id":"id"}' \
  --output table
```

`TERMINATED` を除外しないと過去の削除済みインスタンスも出てくる。

## Block Storage

### ブートボリュームのバックアップ

nixos-anywhere 実行前など、破壊的操作の前に必ず取る。

```bash
# ブートボリューム ID を取得
BV_ID=$(oci compute boot-volume-attachment list \
  --compartment-id "$TENANCY" \
  --instance-id "$INSTANCE_ID" \
  --query 'data[0]."boot-volume-id"' \
  --raw-output)

# バックアップ作成
oci bv boot-volume-backup create \
  --boot-volume-id "$BV_ID" \
  --display-name "pre-nixos-$(date +%Y%m%d-%H%M)"
```

### バックアップ一覧

```bash
oci bv boot-volume-backup list \
  --compartment-id "$TENANCY" \
  --query 'data[].{"name":"display-name","state":"lifecycle-state","time":"time-created"}' \
  --output table \
  --sort-by TIMECREATED \
  --sort-order DESC
```

### バックアップの削除

Always Free のストレージ上限があるため、不要なバックアップは消す。

```bash
oci bv boot-volume-backup delete \
  --boot-volume-backup-id "ocid1.bootvolumebackup.oc1.ap-tokyo-1.xxxxx"
```

## Networking

### パブリック IP の確認

```bash
oci compute instance list-vnics \
  --instance-id "$INSTANCE_ID" \
  --query 'data[0]."public-ip"' \
  --raw-output
```

### セキュリティリスト (ファイアウォール)

```bash
# VCN の OCID を確認
oci network vcn list \
  --compartment-id "$TENANCY" \
  --query 'data[].{"name":"display-name","id":"id"}' \
  --output table
```

NixOS 移行後はホスト側の `networking.firewall` で管理しているため、OCI のセキュリティリストは SSH (22/tcp) のみ開けておけばよい。Tailscale がトンネルを張るので、サービスポートを OCI 側で開ける必要はない。

## 出力フォーマット

```bash
# JSON (デフォルト)
oci compute instance get --instance-id "$INSTANCE_ID"

# テーブル
oci compute instance get --instance-id "$INSTANCE_ID" --output table

# JMESPath でフィルタ
oci compute instance get --instance-id "$INSTANCE_ID" \
  --query 'data.{"name":"display-name","state":"lifecycle-state"}'
```

`--query` は JMESPath 構文。`--raw-output` を付けるとクオートなしの生値が返る。

## 注意点

### Always Free の制約

| リソース | 上限 |
|---|---|
| Ampere A1 | 合計 4 OCPU / 24 GB (複数 VM で分割可) |
| Boot volume | 合計 200 GB |
| Object Storage | 20 GB |
| Boot volume backup | 5 個 |

1 VM に全リソースを割り当てるのが最もシンプル。

### `--raw-output` を忘れると引用符が付く

```bash
# NG: "RUNNING" (ダブルクオート付き)
oci compute instance get --instance-id "$INSTANCE_ID" \
  --query 'data."lifecycle-state"'

# OK: RUNNING
oci compute instance get --instance-id "$INSTANCE_ID" \
  --query 'data."lifecycle-state"' --raw-output
```

シェルスクリプトで状態判定する場合は `--raw-output` を付けないと文字列比較が壊れる。

### エラー出力の抑制

OCI CLI は stderr に認証やリトライの情報を出すことがある。スクリプトで使う場合は `2>/dev/null` を付けるとクリーンな出力が得られる。

```bash
STATE=$(oci compute instance get \
  --instance-id "$INSTANCE_ID" \
  --query 'data."lifecycle-state"' \
  --raw-output 2>/dev/null)
```
