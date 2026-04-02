{
  description = "Kopia B2 backup for wisdom vault";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      kopia = pkgs.kopia;

      serviceUnit = builtins.readFile ./systemd/kopia-backup.service;
      timerUnit = builtins.readFile ./systemd/kopia-backup.timer;

      mkScript = name: text: pkgs.writeShellScriptBin name text;

      backupScript = mkScript "kopia-backup" ''
        set -euo pipefail
        export PATH="${kopia}/bin:$PATH"

        echo "==> kopia snapshot create --all"
        kopia snapshot create --all

        echo "==> スナップショット一覧"
        kopia snapshot list --all
      '';

      setupScript = mkScript "kopia-setup" ''
        set -euo pipefail
        export PATH="${kopia}/bin:${pkgs.sops}/bin:${pkgs.age}/bin:$PATH"

        REPO_DIR="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd || echo ".")"
        SECRETS_FILE="''${1:-$REPO_DIR/secrets.yaml}"

        if [ ! -f "$SECRETS_FILE" ]; then
          echo "secrets.yaml が見つからない: $SECRETS_FILE" >&2
          echo "Usage: nix run .#setup -- <path-to-secrets.yaml>" >&2
          exit 1
        fi

        endpoint=$(sops -d --extract '["b2_endpoint"]' "$SECRETS_FILE")
        bucket=$(sops -d --extract '["b2_bucket"]' "$SECRETS_FILE")
        key_id=$(sops -d --extract '["b2_key_id"]' "$SECRETS_FILE")
        secret_key=$(sops -d --extract '["b2_secret_key"]' "$SECRETS_FILE")

        echo "==> kopia repository connect s3"
        kopia repository connect s3 \
          --endpoint="$endpoint" \
          --bucket="$bucket" \
          --access-key="$key_id" \
          --secret-access-key="$secret_key"

        echo ""
        echo "接続完了。バックアップ対象を追加して:"
        echo "  kopia policy set ~/Documents/wisdom --keep-daily 7 --keep-weekly 4 --keep-monthly 6"
      '';

      installTimerScript = mkScript "kopia-install-timer" ''
        set -euo pipefail
        UNIT_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        mkdir -p "$UNIT_DIR"

        cat > "$UNIT_DIR/kopia-backup.service" << 'UNIT'
        ${serviceUnit}
        UNIT

        cat > "$UNIT_DIR/kopia-backup.timer" << 'UNIT'
        ${timerUnit}
        UNIT

        systemctl --user daemon-reload
        systemctl --user enable --now kopia-backup.timer

        echo "kopia-backup.timer を有効化した"
        systemctl --user status kopia-backup.timer --no-pager
      '';

      uninstallTimerScript = mkScript "kopia-uninstall-timer" (builtins.readFile ./scripts/uninstall-timer.sh);
    in
    {
      apps.${system} = {
        backup = {
          type = "app";
          program = "${backupScript}/bin/kopia-backup";
        };
        setup = {
          type = "app";
          program = "${setupScript}/bin/kopia-setup";
        };
        install-timer = {
          type = "app";
          program = "${installTimerScript}/bin/kopia-install-timer";
        };
        uninstall-timer = {
          type = "app";
          program = "${uninstallTimerScript}/bin/kopia-uninstall-timer";
        };
      };

      packages.${system}.default = kopia;

      devShells.${system}.default = pkgs.mkShell {
        packages = [ kopia pkgs.sops pkgs.age ];
      };
    };
}
