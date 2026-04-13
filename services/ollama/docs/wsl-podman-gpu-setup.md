# WSL2 + Podman + NVIDIA GPU セットアップ

Ollama サービスの前提環境を WSL2 上に構築する手順。

## 前提条件

| 項目 | 要件 |
|------|------|
| OS | Windows 11 (または Windows 10 21H2+) |
| GPU | NVIDIA (Windows 側に最新ドライバをインストール済み) |
| WSL | 最新版 (`wsl --update` で更新) |

> **注意**: WSL2 内に Linux 用 NVIDIA ドライバをインストールしてはいけない。
> Windows ドライバが `/usr/lib/wsl/lib/` に CUDA ライブラリを自動エクスポートする。

## 1. WSL2 systemd 有効化

Podman Quadlet (systemd user unit) の動作に必須。

```bash
sudo tee /etc/wsl.conf <<'EOF'
[boot]
systemd=true
EOF
```

PowerShell で WSL を再起動:

```powershell
wsl --shutdown
```

確認:

```bash
systemctl --user status
# Active な出力が返れば OK
```

## 2. Podman インストール

Ubuntu/Debian の場合:

```bash
sudo apt update && sudo apt install -y podman
podman --version
```

> 他のディストロの場合は公式ドキュメントを参照。

## 3. NVIDIA Container Toolkit + CDI

### 3.1 Toolkit インストール

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update && sudo apt install -y nvidia-container-toolkit
```

### 3.2 CDI スペック生成

システムワイド (root):

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo chmod 644 /etc/cdi/nvidia.yaml
```

または rootless ユーザー向け:

```bash
mkdir -p ~/.config/cdi
nvidia-ctk cdi generate --output="$HOME/.config/cdi/nvidia.yaml"
```

### 3.3 確認

```bash
nvidia-ctk cdi list
# nvidia.com/gpu=all が表示されれば OK
```

## 4. loginctl enable-linger

Windows 再起動後もコンテナが自動復帰するために必須。

```bash
loginctl enable-linger "$USER"
```

## 5. Quadlet ディレクトリ作成

```bash
mkdir -p ~/.config/containers/systemd/
```

## 6. 動作確認

GPU がコンテナから見えることを確認:

```bash
podman run --rm --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

`nvidia-smi` の出力が返れば環境構築完了。

## 運用上の注意

| 状況 | 対応 |
|------|------|
| Windows 側の NVIDIA ドライバ更新後 | `nvidia-ctk cdi generate` を再実行 |
| WSL の更新後 | `systemctl --user status` で systemd 動作を確認 |
| CDI `unresolvable` エラー | パーミッション (644) と toolkit バージョンを確認 |
| コンテナが再起動後に復帰しない | `loginctl show-user $USER` で `Linger=yes` を確認 |
