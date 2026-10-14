_default:
    @just --list

mod backup 'services/backup-kopia-b2'
mod vaultwarden 'services/vaultwarden'
mod gatus 'services/gatus'
mod adguard-home 'services/adguard-home'
mod ollama 'services/ollama'          # WSL2 machine — not in deploy-all
mod observability 'services/observability'
mod sing-box 'services/sing-box'

# OCI NixOS host (deploy / boot / rollback / update-image / status / logs / ssh)
mod oci 'hosts/oci'

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
