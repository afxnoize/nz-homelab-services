# Sidecar パターン（Tailscale 公開）

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
- state を永続化する named volume をマウントし、**必ず `TS_STATE_DIR=/var/lib/tailscale` を明示する**。これがないと `containerboot` は state を `mem:` に置き、再起動のたびに新ノードとして登録される（既存ホスト名が残っていると `<name>-1` のように suffix が付く）

**起動順序の保証:**

```ini
[Unit]
Requires=<name>-ts.service
After=<name>-ts.service
```

**いつ使うか:** Tailnet 内部にのみ公開し、HTTPS を自動化したいとき。
