# デプロイフロー

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
