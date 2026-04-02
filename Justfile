set dotenv-load := false

secrets := env("VAULT_SECRETS", "./secrets.yaml")
policy := env("VAULT_POLICY", "./policy.json")
config := env("XDG_CONFIG_HOME", env("HOME") / ".config") / "kopia/vault-b2.config"
unit_dir := env("XDG_CONFIG_HOME", env("HOME") / ".config") / "systemd/user"
kopia := "kopia --config-file=" + config

# Connect to B2 repository + set retention policy
connect:
    #!/usr/bin/env bash
    set -euo pipefail
    endpoint=$(sops -d --extract '["b2_endpoint"]' {{ secrets }})
    bucket=$(sops -d --extract '["b2_bucket"]' {{ secrets }})
    key_id=$(sops -d --extract '["b2_key_id"]' {{ secrets }})
    secret_key=$(sops -d --extract '["b2_secret_key"]' {{ secrets }})
    password=$(sops -d --extract '["kopia_password"]' {{ secrets }})
    echo "==> Connecting to B2 repository"
    {{ kopia }} repository connect s3 \
      --endpoint="$endpoint" \
      --bucket="$bucket" \
      --access-key="$key_id" \
      --secret-access-key="$secret_key" \
      --password="$password"
    echo "==> Connected"
    daily=$(jq -r '.["keep-daily"] // 0' {{ policy }})
    weekly=$(jq -r '.["keep-weekly"] // 0' {{ policy }})
    monthly=$(jq -r '.["keep-monthly"] // 0' {{ policy }})
    annual=$(jq -r '.["keep-annual"] // 0' {{ policy }})
    echo "==> Setting retention policy (daily:$daily weekly:$weekly monthly:$monthly annual:$annual)"
    {{ kopia }} policy set --global \
      --keep-daily "$daily" \
      --keep-weekly "$weekly" \
      --keep-monthly "$monthly" \
      --keep-annual "$annual"

# Install and enable systemd timer
timer-on:
    #!/usr/bin/env bash
    set -euo pipefail
    kopia_bin=$(which kopia)
    mkdir -p {{ unit_dir }}
    sed "s|ExecStart=.*|ExecStart=${kopia_bin} --config-file={{ config }} snapshot create --all|" \
      systemd/kopia-backup.service > {{ unit_dir }}/kopia-backup.service
    cp systemd/kopia-backup.timer {{ unit_dir }}/
    systemctl --user daemon-reload
    systemctl --user enable --now kopia-backup.timer
    echo "==> Timer enabled (kopia: ${kopia_bin})"
    systemctl --user status kopia-backup.timer --no-pager

# Disable and remove systemd timer
timer-off:
    -systemctl --user disable --now kopia-backup.timer
    rm -f {{ unit_dir }}/kopia-backup.service {{ unit_dir }}/kopia-backup.timer
    systemctl --user daemon-reload
    @echo "==> Timer removed"

# Connect + install timer
deploy: connect timer-on

# Create snapshots
backup:
    @echo "==> Creating snapshots"
    {{ kopia }} snapshot create --all
    @echo "==> Snapshot list"
    {{ kopia }} snapshot list --all

# Show connection status and snapshots
status:
    {{ kopia }} repository status || echo "Not connected"
    @echo ""
    -{{ kopia }} snapshot list --all
