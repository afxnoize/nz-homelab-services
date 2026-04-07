default:
    @just --list

mod backup 'services/backup-kopia-b2'
mod vaultwarden 'services/vaultwarden'
mod gatus 'services/gatus'

# Deploy all services
deploy-all:
    just backup deploy
    just vaultwarden deploy
    just gatus deploy

# Show status of all services
status-all:
    just backup status
    just vaultwarden status
    just gatus status
