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
- **Problem**: Tailscale authkey には有効期限がある。state が永続化されていれば（K-011 参照）期限切れでも動き続けるが、state を失うと再認証が必要になる。期限切れの authkey でコンテナを起動すると、Tailscale がネットワークに参加できず無言で失敗することがある。
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

### K-007: fluent-bit tail の位置永続化（adguard-home-querylog）【対処済み】

- **Trigger**: `adguard-home-querylog` コンテナ（fluent-bit）が再起動されたとき
- **Problem**: fluent-bit の tail input に `DB` パラメータを設定していないため、読み取り位置が永続化されない。再起動中に書き込まれたクエリログが欠損する。`Read_from_Head true` にすれば再読み込みされるが、journald に重複エントリが入る。
- **Solution**: state 用の named volume（`adguard-home-querylog-state.volume`）を作成し、`/state` にマウント。fluent-bit.conf に `DB /state/tail-pos.db` を追加した。data volume は `:ro` のため DB を同じボリュームに置けない点に注意。併せて `AdGuardHome.yaml` の `querylog.interval` を `720h` → `24h` に短縮（journald 側に記録済みのため長期保持不要）。
- **Confidence**: high
- **Source**: fluent-bit sidecar 導入時のレビュー（2026-04-09）、対処（2026-04-13）

### K-008: fluent-bit と AdGuardHome.yaml の querylog パス依存

- **Trigger**: AdGuardHome.yaml の `querylog.dir_path` を変更するとき
- **Problem**: fluent-bit.conf の `Path /data/querylog.json` は AdGuard Home のデフォルト出力先（`/opt/adguardhome/data/querylog.json`）に依存している。`dir_path` を変更すると fluent-bit がファイルを見つけられなくなり、クエリログが journald に流れなくなる。エラーも出ないため気づきにくい。
- **Solution**: `dir_path` を変更する場合は fluent-bit.conf の `Path` と adguard-home-querylog.container の `Volume` マウントも合わせて変更する。現状は `dir_path: ""`（デフォルト）に固定する前提で運用する。
- **Confidence**: high
- **Source**: fluent-bit sidecar 導入時のレビュー（2026-04-09）

### K-010: AdGuard Home の data ディレクトリは `/opt/adguardhome/work/data/`

- **Trigger**: AdGuard Home のデータ永続化ボリュームを設定するとき
- **Problem**: AdGuard Home の公式イメージは `/opt/adguardhome/data` ではなく `/opt/adguardhome/work/data/` にクエリログ・統計・フィルタを書き込む。`/opt/adguardhome/data` にボリュームをマウントしても空のままで、データが永続化されない。コンテナ再作成時にクエリログと統計が消失する。
- **Solution**: ボリュームのマウント先を `/opt/adguardhome/work/data` にする。
  ```ini
  Volume=adguard-home-data.volume:/opt/adguardhome/work/data
  ```
- **Confidence**: high
- **Source**: querylog 調査で発見（2026-04-09）。`podman exec ls -la /opt/adguardhome/data/` が空、`/opt/adguardhome/work/data/` にファイルが存在することで確認。

### K-009: fluent-bit の Log_Level を warn にしている理由

- **Trigger**: adguard-home と adguard-home-querylog を同時に起動したとき
- **Problem**: AdGuard Home は最初の DNS クエリが来るまで `querylog.json` を作成しない場合がある。fluent-bit の tail input は対象ファイルが存在しないときに warn ログを出す。実害はない（ファイル出現後に自動で読み始める）。起動直後に一時的な warn が出るが、DNS が Tailnet 全体で使われているためファイルはほぼ即座に生成される。
- **Solution**: `Log_Level warn` のまま運用する。error に絞ることも検討したが、query log の異常検知を fluent-bit 側の warn に頼る可能性があるため、情報量を残す判断をした。起動時の一時的な warn は許容する。Log_Level の変更判断は今後の query log 分析結果に基づいて行う。
- **Confidence**: high
- **Source**: fluent-bit sidecar 導入時のレビュー + query log 分析（2026-04-09）

### K-011: Tailscale sidecar の state 永続化には `TS_STATE_DIR` が必須

- **Trigger**: tailscale 公式コンテナ（`docker.io/tailscale/tailscale`）を sidecar として使い、state 用 volume を `/var/lib/tailscale` にマウントしているとき
- **Problem**: `containerboot` は `TS_STATE_DIR` が未設定だと state を `mem:state`（メモリ）に書く。volume をマウントしていても使われず、ログファイル（`tailscaled.log*`）しか残らない。再起動のたびに新しいマシン鍵で登録されるため、旧ノードが tailnet に残っている間は `<hostname>-1`, `-2` と suffix が付く。ホストの再起動や volume の再作成をきっかけに顕在化する。
- **Solution**: ts コンテナに `Environment=TS_STATE_DIR=/var/lib/tailscale` を明示する。既に suffix 付きで登録されてしまった場合は以下の手順:
  1. テンプレに `TS_STATE_DIR` を追加して `just <service> deploy`
  2. Tailscale admin (<https://login.tailscale.com/admin/machines>) で旧 `<hostname>`（offline）と `<hostname>-1`（active）の両方を削除
  3. `systemctl --user restart <service>-ts` で再認証。state が永続化され、以降は base hostname を保持する
- **Confidence**: high
- **Source**: ホスト再起動で adguard-home / vaultwarden が `-1` に化けた事案（2026-04-10）

### K-012: AdGuardHome.yaml に credentials を直書きしない

- **Trigger**: AdGuard Home の管理ユーザーを設定・変更するとき
- **Problem**: `AdGuardHome.yaml` の `users` にユーザー名と bcrypt ハッシュを書くと git 履歴に残る。bcrypt は salt 付きだがオフライン総当たりの対象になりうる。公開リポジトリでは特に危険。
- **Solution**: `AdGuardHome.yaml` は `users: []` のまま管理する。Quadlet 版では deploy 時に `yq` で volume 側の既存 `users` / `clients.persistent` をマージしていたが、NixOS 版では `ExecStartPre` が毎回 `AdGuardHome.yaml` を volume に上書きするため、このマージは行われない。結果として認証なし (`users: []`) で常に動作する。Tailscale Serve の裏にいるため Tailnet 外からはアクセスできず、実害はない。
- **Confidence**: high
- **Source**: リポジトリ公開準備時のセキュリティレビュー（2026-04-14）、NixOS 移行で yq マージ無効化を確認（2026-04-15）

### K-013: WSL2 スリープ復帰で Tailscale sidecar が再接続に失敗する

- **Trigger**: WSL2 上で動作するサービスの Tailscale sidecar が、Windows スリープ復帰後にアクセス不能になるとき
- **Problem**: Windows スリープで WSL2 のネットワークスタックが一時的に壊れ、Tailscale コンテナが control plane への再接続に失敗する。`PollNetMap: initial fetch failed 404: node not found` がループし、Tailscale Serve 経由のアクセスが全断する。コンテナ自体は active (running) のままなので systemd の `Restart=always` では検知できない。
- **Solution**: systemd timer + oneshot service で定期的にコンテナのヘルスチェックを監視し、unhealthy 検知時に自動 restart する。ollama サービスでは `ollama-ts-watchdog.timer`（2分間隔）として実装済み。`just ollama watchdog-on` で有効化。他の WSL2 サービスにも同じパターンを適用可能。
- **Confidence**: high
- **Source**: ollama Tailscale sidecar のスリープ復帰障害（2026-04-14）

### K-014: OCI 再作成時に Tailscale が自動参加しない

- **Trigger**: nixos-anywhere で OCI インスタンスを再作成したとき
- **Problem**: `services.tailscale.enable = true` だけでは初回起動時に tailnet に自動参加しない。手動で `tailscale up` または browser 認証が必要になる。OCI インスタンスはシリアルコンソール経由でしかアクセスできない場合があり、browser 認証が困難なケースがある。
- **Solution**: `services.tailscale.authKeyFile` に sops 管理の authkey を指定する。再起動時に自動で tailnet に参加し、Tailscale SSH が即座に使えるようになる。詳細は [#4](https://github.com/afxnoize/nz-homelab-services/issues/4) を参照。
- **Confidence**: medium（未実施。現状は browser 認証で運用中）
- **Source**: OCI NixOS マイグレーション（2026-04-15）

### K-015: quadlet-nix 移行で systemd unit 名から `podman-` プレフィックスが消える

- **Trigger**: NixOS ホスト上のコンテナサービスを `virtualisation.oci-containers` から `virtualisation.quadlet`（quadlet-nix）に移行したとき
- **Problem**: `virtualisation.oci-containers.containers.<name>` は systemd unit を `podman-<name>.service` として生成するが、Quadlet は `.container` ファイル名から `<name>.service` を生成する（プレフィックスなし）。移行直後は新旧どちらの unit 名も参照できる状態にならず、旧名を前提にした journalctl / systemctl コマンドやラベル定義が無言で空の結果を返す。deploy 直後に「ログが止まった」「監視が外れた」ように見えるが、実体は新 unit が走っているだけ。
- **Solution**:
  - Justfile の `oci-logs` / `oci-status` など、unit 名に `podman-` プレフィックスを決め打ちしている箇所を `<name>.service` に書き換える
  - sops-nix の `restartUnits = [ "podman-<name>.service" ]` を `[ "<name>.service" ]` に更新する（ADR-009 移行時にサービスごとに行う）
  - ログ・監視系の運用ツール（Alloy の `loki.source.journal` relabel など）も同タイミングで調整する
  - 混在期間中は `journalctl -u <name>.service -u podman-<name>.service ...` の両方指定で凌ぐこともできるが、順次移行していく前提ならシンプルに新名へ一括更新する方が保守しやすい
- **Confidence**: high
- **Source**: ADR-009 Phase 1（gatus パイロット移行、2026-04-15）
