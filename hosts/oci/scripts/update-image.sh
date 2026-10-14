#!/usr/bin/env bash
# Runs on the OCI host (piped through ssh by `just oci update-image <name>`).
# Pull first, restart second: the host resolves DNS via adguard-home on itself (K-017),
# so pulling after a restart of adguard-home can fail.
set -euo pipefail

name="${1:?usage: update-image.sh <container-name>}"

image=$(podman inspect "$name" --format '{{.ImageName}}')
old_id=$(podman image inspect "$image" --format '{{.Id}}')

echo "image: $image"
podman pull -q "$image" >/dev/null
new_id=$(podman image inspect "$image" --format '{{.Id}}')

if [ "$old_id" = "$new_id" ]; then
  echo "already up to date: $name"
  exit 0
fi

# Keep the previous image reachable for rollback; tagged by ID so a pull cannot shadow it
backup="localhost/${name}:pre-$(date +%Y%m%d)"
podman image tag "$old_id" "$backup"
echo "previous image kept as $backup"

systemctl restart "$name.service"

# Containers without a healthcheck report an empty status; treat "running" as done for them
for _ in $(seq 1 40); do
  state=$(podman inspect "$name" --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}')
  case "$state" in
    "running healthy" | "running ") break ;;
  esac
  sleep 3
done

podman ps --filter "name=^${name}$" --format '{{.Names}}\t{{.Status}}'
journalctl -u "$name.service" -n 15 --no-pager | cut -c1-200

case "$state" in
  "running healthy" | "running ") ;;
  *)
    echo "not healthy after restart: $state" >&2
    exit 1
    ;;
esac
