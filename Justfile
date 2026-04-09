default:
    @just --list

mod backup 'services/backup-kopia-b2'
mod vaultwarden 'services/vaultwarden'
mod gatus 'services/gatus'
mod adguard-home 'services/adguard-home'

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
