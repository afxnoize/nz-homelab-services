# Knowledge Base

既知の落とし穴と解決策。ADR が「決めたこと」なら、ここは「踏んだ地雷」。

## Format

```markdown
### K-{番号}: {タイトル}

- **Trigger**: どういう状況で発生するか
- **Problem**: 何が起きるか
- **Solution**: どう対処するか
- **Confidence**: high / medium / low
- **Source**: 発見元の commit / ADR（該当する場合）
```

---

## Entries

### K-001: Quadlet ユニット名の `systemd-` プレフィックス

- **Trigger**: `Network=container:<name>-ts` のように他コンテナのネットワーク名前空間を参照するとき
- **Problem**: Podman Quadlet は `.container` ファイル名からユニット名を生成する際に自動で `systemd-` プレフィックスを付ける。そのため `foo-ts.container` → ユニット名は `systemd-foo-ts`。`Network=container:foo-ts` と書くと存在しないネットワークを参照してコンテナが起動しない。
- **Solution**: `Network=container:systemd-foo-ts` と書く。
- **Confidence**: high
- **Source**: ADR-002

### K-002: `sops exec-env` 内のシェルクオート

- **Trigger**: `sops exec-env secrets.yaml '...'` の中で gomplate コマンドを書くとき
- **Problem**: シングルクオートで囲んだコマンド文字列の中にシングルクオートを含めると、シェルがクオートを正しく解釈できずにエラーになる。特に gomplate のオプションで値を渡す際に起こりやすい。
- **Solution**: バックスラッシュで行継続するときはシングルクオートの外で `\` を書く。コマンド全体をシングルクオートで包むため、内部でシングルクオートが必要な場合はダブルクオートで代替するか、事前に環境変数に代入しておく。
  ```bash
  sops exec-env secrets.yaml ' \
    gomplate -f foo.tmpl -o foo.out \
  '
  ```
- **Confidence**: high
- **Source**: K-001 と同時期に発見

### K-003: `daemon-reload` → `restart` の順序

- **Trigger**: Quadlet ファイルを編集してサービスを再起動するとき
- **Problem**: `systemctl --user restart <name>` を先に実行しても、systemd はディスク上の古い定義を使う。`daemon-reload` なしでは変更が反映されない。
- **Solution**: 必ず `daemon-reload` を先に実行してから `restart` する。`just deploy` はこの順序を保証しているが、手動で操作するときは注意。
  ```bash
  systemctl --user daemon-reload
  systemctl --user restart <name>
  ```
- **Confidence**: high

### K-004: Tailscale authkey の有効期限

- **Trigger**: コンテナを破棄・再作成するとき（volume 削除後の再デプロイ等）
- **Problem**: Tailscale authkey には有効期限がある。volume に保存された状態（`/var/lib/tailscale`）があれば期限切れでも動き続けるが、volume を削除すると再認証が必要になる。期限切れの authkey でコンテナを起動すると、Tailscale がネットワークに参加できず無言で失敗することがある。
- **Solution**: volume を削除する前に新しい authkey を発行して `secrets.yaml` を更新する。`just <service> logs` で Tailscale のログを確認し、認証エラーがないか確認する。
- **Confidence**: high

### K-005: `.tmpl` ファイルと静的ファイルの混在

- **Trigger**: `deploy` レシピを書くとき
- **Problem**: `.container.tmpl` は gomplate で展開が必要だが、`.volume` は静的なため `cp` でよい。これを混同すると、gomplate に静的ファイルを渡してエラーになるか、テンプレートを未展開のまま systemd に渡して `{{ .Env.xxx }}` がリテラルとして残る。
- **Solution**: `deploy` レシピでは `.tmpl` ファイルは `gomplate` で処理し、それ以外は `cp` で直接コピーする。ファイル名で区別できるように管理する。
- **Confidence**: high

### K-006: SOPS age キーのパス

- **Trigger**: 新しいマシンや環境で `sops` を実行するとき
- **Problem**: SOPS は age キーを `~/.config/sops/age/keys.txt` から読む。このファイルが存在しないと `failed to get the data key required to decrypt the SOPS file` のようなエラーになる。エラーメッセージから age キーの問題だと気づきにくい。
- **Solution**: `~/.config/sops/age/keys.txt` に秘密鍵を配置する。`.sops.yaml` に記載された公開鍵に対応する秘密鍵であることを確認する。
  ```bash
  mkdir -p ~/.config/sops/age
  # age キーをここに置く
  ls ~/.config/sops/age/keys.txt
  ```
- **Confidence**: high
