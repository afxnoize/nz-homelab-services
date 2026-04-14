{ config, pkgs, lib, ... }:
let
  serveJson = pkgs.writeText "adguard-home-ts-serve.json" (builtins.toJSON {
    TCP = { "443" = { HTTPS = true; }; };
    Web = {
      ":443" = {
        Handlers = {
          "/" = { Proxy = "http://127.0.0.1:3000"; };
        };
      };
    };
  });

  fluentBitConf = pkgs.writeText "adguard-home-fluent-bit.conf" ''
    [SERVICE]
        Flush        5
        Log_Level    warn
        Daemon       off
        Parsers_File /fluent-bit/etc/parsers.conf

    [INPUT]
        Name         tail
        Path         /data/querylog.json
        Tag          adguard.querylog
        Parser       json
        DB           /state/tail-pos.db
        Refresh_Interval 10
        Read_from_Head false

    [OUTPUT]
        Name         stdout
        Match        *
        Format       json_lines
  '';

  parsersConf = pkgs.writeText "adguard-home-parsers.conf" ''
    [PARSER]
        Name         json
        Format       json
        Time_Key     T
        Time_Format  %Y-%m-%dT%H:%M:%S.%L%z
        Time_Keep    On
  '';
in {
  # sops secrets
  sops.secrets."adguard-home/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    restartUnits = [ "podman-adguard-home-ts.service" ];
  };

  virtualisation.oci-containers.containers = {
    # Tailscale sidecar
    adguard-home-ts = {
      image = "docker.io/tailscale/tailscale:latest";
      environment = {
        TS_HOSTNAME    = "adguard-home";
        TS_STATE_DIR   = "/var/lib/tailscale";
        TS_SERVE_CONFIG = "/config/serve.json";
        TS_USERSPACE   = "true";
        TS_EXTRA_ARGS  = "--accept-dns=false";
      };
      environmentFiles = [
        config.sops.secrets."adguard-home/ts_authkey".path
      ];
      volumes = [
        "adguard-home-ts-state:/var/lib/tailscale"
        "${serveJson}:/config/serve.json:ro"
      ];
      extraOptions = [
        "--health-cmd=tailscale status --json | grep -q '\"Online\": true' || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=60s"
      ];
    };

    # AdGuard Home
    adguard-home = {
      image = "docker.io/adguard/adguardhome:latest";
      dependsOn = [ "adguard-home-ts" ];
      volumes = [
        "adguard-home-data:/opt/adguardhome/work/data"
        "${./AdGuardHome.yaml}:/opt/adguardhome/conf/AdGuardHome.yaml:ro"
      ];
      extraOptions = [
        "--network=container:adguard-home-ts"
        "--health-cmd=wget --quiet --tries=1 --spider http://127.0.0.1:3000 || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=60s"
      ];
    };

    # Fluent-bit querylog sidecar
    adguard-home-querylog = {
      image = "ghcr.io/fluent/fluent-bit:latest";
      dependsOn = [ "adguard-home" ];
      volumes = [
        "adguard-home-data:/data:ro"
        "adguard-home-querylog-state:/state"
        "${fluentBitConf}:/fluent-bit/etc/fluent-bit.conf:ro"
        "${parsersConf}:/fluent-bit/etc/parsers.conf:ro"
      ];
      cmd = [ "/fluent-bit/bin/fluent-bit" "-c" "/fluent-bit/etc/fluent-bit.conf" ];
    };
  };
}
