default:
    @just --list

mod backup 'services/backup-kopia-b2'
mod vaultwarden 'services/vaultwarden'
mod gatus 'services/gatus'
mod adguard-home 'services/adguard-home'
mod ollama 'services/ollama'          # WSL2 machine — not in deploy-all

####################
# Orchestrate
####################

# Deploy all services
[group('orchestrate')]
deploy-all:
    just backup deploy
    just vaultwarden deploy
    just gatus deploy
    just adguard-home deploy

# Show status of all services
[group('orchestrate')]
status-all:
    just backup status
    just vaultwarden status
    just gatus status
    just adguard-home status

####################
# OCI NixOS host
####################

oci_host := `sops -d --extract '["oci_host"]' hosts/oci/secrets.yaml`

# Deploy NixOS configuration to OCI host
[group('oci')]
oci-deploy:
    nix run nixpkgs#nixos-rebuild -- switch --flake .#oci --target-host root@{{oci_host}} --build-host root@{{oci_host}}

# Build NixOS configuration without deploying
[group('oci')]
oci-build:
    nix run nixpkgs#nixos-rebuild -- build --flake .#oci --target-host root@{{oci_host}} --build-host root@{{oci_host}}

# Rollback to previous NixOS generation
[group('oci')]
oci-rollback:
    nix run nixpkgs#nixos-rebuild -- switch --flake .#oci --target-host root@{{oci_host}} --rollback --build-host root@{{oci_host}}

# Show status of OCI services (oci-containers: podman-*.service / Quadlet: <name>.service from /etc/containers/systemd/)
[group('oci')]
oci-status:
    ssh root@{{oci_host}} 'quadlet_units=$(find /etc/containers/systemd -maxdepth 1 -name "*.container" -exec basename -s .container {} \; 2>/dev/null | sed "s/\$/.service/" | tr "\n" " "); systemctl list-units --no-pager "podman-*" $quadlet_units'

# Show logs for an OCI service (covers both oci-containers "podman-<name>.service" and Quadlet "<name>.service")
[group('oci')]
oci-logs service:
    ssh root@{{oci_host}} 'journalctl -u {{service}}.service -u podman-{{service}}.service -n 50 --no-pager'

# SSH into OCI host
[group('oci')]
oci-ssh:
    ssh root@{{oci_host}}
