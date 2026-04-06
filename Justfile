default:
    @just --list

mod backup 'services/backup-kopia-b2'
mod vaultwarden 'services/vaultwarden'

# Deploy all services
deploy-all:
    just backup deploy
    just vaultwarden deploy

# Show status of all services
status-all:
    just backup status
    just vaultwarden status
