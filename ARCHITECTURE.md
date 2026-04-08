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

### Sidecar パターン（Tailscale 公開）

Tailscale を sidecar コンテナとして動かし、アプリコンテナと同一ネットワーク名前空間を共有するパターン。

```
┌─────────────────────────────────────┐
│  Pod (shared network namespace)     │
│                                     │
│  ┌─────────────┐  ┌──────────────┐  │
│  │  Tailscale  │  │     App      │  │
│  │  (sidecar)  │  │  container   │  │
│  │             │◄─┤              │  │
│  │  TS_SERVE   │  │  127.0.0.1   │  │
│  │  :443 HTTPS │  │  :<port>     │  │
│  └─────────────┘  └──────────────┘  │
└─────────────────────────────────────┘
        ▲
   Tailnet のみアクセス可
```

**実装の要点:**
- Tailscale コンテナに `Network=` を設定しない（デフォルト = 新規 namespace を作成）
- App コンテナに `Network=container:systemd-<name>-ts` を指定してネットワーク名前空間を共有
  - Quadlet はユニット名に自動で `systemd-` プレフィックスを付けるため、`<name>-ts` ではなく `systemd-<name>-ts` が正しい
- App コンテナは `127.0.0.1:<port>` でリッスンすれば Tailscale Serve からアクセス可能
- `TS_SERVE_CONFIG` で JSON ファイルを渡して Tailscale Serve の設定を宣言的に管理する

**起動順序の保証:**
```ini
[Unit]
Requires=<name>-ts.service
After=<name>-ts.service
```

**いつ使うか:** Tailnet 内部にのみ公開し、HTTPS を自動化したいとき。

---

### シークレットパイプライン

秘匿値を平文でディスクに残さずにテンプレートへ注入するパターン。

```
secrets.yaml       sops exec-env        gomplate
(SOPS 暗号化) ──► (環境変数に展開) ──► (テンプレート展開) ──► 展開済みファイル
                                 ▲
                        tailscale status
                        (TS_DOMAIN を動的に取得)
```

**deploy レシピの骨格:**
```bash
export TS_DOMAIN=$(tailscale status --json | jq -r '.MagicDNSSuffix')
sops exec-env ./secrets.yaml '
  gomplate -f quadlet/foo.container.tmpl -o ~/.config/containers/systemd/foo.container
'
```

**テンプレート側の参照:**
```ini
Environment=TS_AUTHKEY={{ .Env.ts_authkey }}
Environment=DOMAIN=https://app.{{ .Env.TS_DOMAIN }}
```

**いつ使うか:** Quadlet ファイルや設定ファイルに秘匿値またはランタイム値（TS_DOMAIN）を埋め込む必要があるとき。静的なファイルは `.tmpl` にしない。

---

### Quadlet 構成規約

**ファイル種別と用途:**

| 拡張子 | 用途 | デプロイ方法 |
|---|---|---|
| `.container` | 静的なコンテナ定義 | `cp` でそのままコピー |
| `.container.tmpl` | 秘匿値や動的値を含むコンテナ定義 | `sops exec-env` + `gomplate` で展開 |
| `.volume` | 名前付きボリューム | `cp` でそのままコピー |

**標準的なコンテナ設定:**
```ini
[Container]
AutoUpdate=registry     # podman auto-update でイメージ自動更新
LogDriver=journald      # journalctl でログを統一管理
HealthCmd=...           # ヘルスチェック（不要なら HealthCmd=none）

[Service]
Restart=always

[Install]
WantedBy=default.target
```

**デプロイ先:** `~/.config/containers/systemd/`（`$XDG_CONFIG_HOME/containers/systemd/`）

---

### 公開モデル

**Model A — Tailscale Serve（Tailnet 内公開）**

| 項目 | 内容 |
|---|---|
| アクセス範囲 | Tailnet 内のみ |
| TLS | Tailscale が自動管理 |
| 必要なもの | Tailscale sidecar コンテナ、`TS_SERVE_CONFIG`、`ts_authkey` シークレット |
| 典型例 | Vaultwarden |

**Model B — localhost バインド（ホスト内部のみ）**

| 項目 | 内容 |
|---|---|
| アクセス範囲 | ホスト内部のみ（`127.0.0.1`） |
| TLS | なし |
| 必要なもの | `PublishPort=127.0.0.1:<host>:<container>` |
| 典型例 | Gatus（Web UI をローカルに閉じる） |

**選択基準:**
- ネットワーク越しにアクセスしたい → Model A
- ホスト内の別プロセス（リバースプロキシなど）からのみ使う → Model B

---

## サービス追加チェックリスト

新しいサービスを `services/<name>/` に追加するときの手順。

### ディレクトリ構造

```
services/<name>/
├── Justfile
├── secrets.yaml              # sops で暗号化
├── secrets.example.yaml      # キー名だけ書いたプレーンテキスト
├── README.md
└── quadlet/
    ├── <name>.container(.tmpl)
    ├── <name>-data.volume
    └── (Tailscale Serve を使う場合)
        ├── <name>-ts.container.tmpl
        ├── <name>-ts-serve.json.tmpl
        └── <name>-ts-state.volume
```

### Justfile 標準レシピ

以下のレシピをすべて実装する。

| レシピ | 内容 |
|---|---|
| `deploy` | テンプレート展開 → quadlet dir へコピー → `daemon-reload` |
| `start` | `systemctl --user start <name>` |
| `stop` | `systemctl --user stop <name>` |
| `restart` | `systemctl --user restart <name>` |
| `status` | `systemctl --user status <name> --no-pager` |
| `logs` | `journalctl --user -u <name> --no-pager -n 50` |
| `logs-follow` | `journalctl --user -u <name> -f` |
| `update` | `podman auto-update` |

### Root Justfile への登録

```just
mod <name> 'services/<name>'
```

`deploy-all` / `status-all` が定義されていれば、そこにも追加する。

### ドキュメント更新

AGENTS.md の機能概要・リポジトリ構成に追記する（同一コミット）。

---

## デプロイフロー

`just <service> deploy` が実行されたときの内部処理。

```
1. TS_DOMAIN を取得
   └─ tailscale status --json | jq -r '.MagicDNSSuffix'

2. quadlet_dir を作成
   └─ mkdir -p ~/.config/containers/systemd/

3. テンプレートを展開（.tmpl ファイルのみ）
   └─ sops exec-env secrets.yaml '
        gomplate -f quadlet/foo.container.tmpl \
                 -o ~/.config/containers/systemd/foo.container
      '

4. 静的ファイルをコピー（.volume 等）
   └─ cp quadlet/*.volume ~/.config/containers/systemd/

5. systemd に反映
   └─ systemctl --user daemon-reload

   ※ daemon-reload が先。その後 restart が必要な場合は別途実行する。
```
