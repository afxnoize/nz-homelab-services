# Ollama + Open WebUI デプロイ手順

WSL2 マシン上に Ollama (GPU) + Open WebUI + Tailscale Sidecar を Podman Quadlet で構築する。

> 前提: [WSL2 + Podman + NVIDIA GPU セットアップ](wsl-podman-gpu-setup.md) が完了していること。

## 構成図

```
Tailnet (HTTPS)
  │
  ▼
ollama-ts (Tailscale Sidecar)
  │  TS_SERVE :443 → 127.0.0.1:8080  (Open WebUI)
  │  TCP      :11434 → 127.0.0.1:11434 (Ollama API / Aider 用)
  │
  ├── ollama         (GPU, :11434)
  └── open-webui     (:8080)

※ 3コンテナが同一ネットワーク名前空間を共有
```

### アクセス経路

| 用途                  | URL                               | 備考                          |
| --------------------- | --------------------------------- | ----------------------------- |
| Open WebUI (ブラウザ) | `https://ollama.<ts-domain>/`     | HTTPS via Tailscale Serve     |
| Ollama API (Aider 等) | `http://ollama.<ts-domain>:11434` | TCP proxy via Tailscale Serve |

## Quadlet ファイル

実ファイルは [`../quadlet/`](../quadlet/) を参照。ここでは設計上のポイントのみ記載する。

- **ollama-ts**: 既存パターン (vaultwarden-ts) と同一。テンプレートで `ts_authkey` と `TS_DOMAIN` を注入
- **ollama**: static ファイル。`AddDevice=nvidia.com/gpu=all` で NVIDIA CDI 経由の GPU アクセス
- **open-webui**: static ファイル。`OLLAMA_BASE_URL=http://127.0.0.1:11434` でローカル接続
- **起動チェーン**: `ollama-ts` → `ollama` → `open-webui` (`Requires=` + `After=`)
- **ネットワーク**: 全コンテナが `Network=container:systemd-ollama-ts` で名前空間を共有

### Tailscale Serve 設定

HTTPS (:443) と TCP (:11434) の併用は Tailnet 内部の Serve でサポートされている（Funnel ではポート制限あり）。

`TCPForward` のキー名はバージョンで変わる可能性がある。デプロイ後に `tailscale serve status` で確認すること。

CLI で同等の設定を行う場合:

```bash
tailscale serve --https=443 http://127.0.0.1:8080
tailscale serve --tcp=11434 tcp://127.0.0.1:11434
```

## デプロイ手順

### 1. secrets.yaml を暗号化

`ts_authkey` に Tailscale authkey を記入し、SOPS で暗号化する。

```bash
sops services/ollama/secrets.yaml
```

### 2. デプロイ・起動

```bash
just ollama deploy
just ollama start
```

### 3. 動作確認

```bash
just ollama status
curl -s http://127.0.0.1:11434/api/tags | jq .
podman exec ollama nvidia-smi
```

## deploy-all との関係

このサービスは **別マシン (WSL2)** で動作するため、ルート justfile の `deploy-all` には含めない。
`mod ollama 'services/ollama'` で登録し、`just ollama deploy` で個別操作のみ可能にする。

> deploy-all のホスト分離については別途検討予定。

## トラブルシューティング

| 症状                                | 原因と対処                                                           |
| ----------------------------------- | -------------------------------------------------------------------- |
| GPU が認識されない                  | CDI スペックを確認: `nvidia-ctk cdi list`                            |
| コンテナ起動後すぐ落ちる            | `journalctl --user -u ollama` でログ確認                             |
| Tailscale に接続できない            | authkey の有効期限、`TS_STATE_DIR` の永続化を確認                    |
| Open WebUI から Ollama に繋がらない | `OLLAMA_BASE_URL` と Network 設定を確認 (同一ネットワーク名前空間か) |
| Windows 再起動後に復帰しない        | `loginctl enable-linger` を確認                                      |
