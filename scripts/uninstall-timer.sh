#!/usr/bin/env bash
set -euo pipefail

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

systemctl --user disable --now kopia-backup.timer 2>/dev/null || true
rm -f "$UNIT_DIR/kopia-backup.service" "$UNIT_DIR/kopia-backup.timer"
systemctl --user daemon-reload

echo "kopia-backup.timer を削除した"
