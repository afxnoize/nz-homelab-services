# シークレットパイプライン

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
