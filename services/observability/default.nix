{
  config,
  pkgs,
  lib,
  ...
}:
let
  vars = {
    retention = {
      logs = "30d";
      metrics = "90d";
    };
    diskBudget = {
      logs = "15GB";
      metrics = "10GB";
    };
    ports = {
      vl = 9428;
      vm = 8428;
      grafana = 3000;
      alloy = 12345;
    };
  };
in
{
  imports = [
    (import ./victorialogs/nixos.nix {
      inherit
        config
        pkgs
        lib
        vars
        ;
    })
    (import ./victoriametrics/nixos.nix {
      inherit
        config
        pkgs
        lib
        vars
        ;
    })
    (import ./alloy/nixos.nix {
      inherit
        config
        pkgs
        lib
        vars
        ;
    })
    (import ./grafana/nixos.nix {
      inherit
        config
        pkgs
        lib
        vars
        ;
    })
  ];

  # sops secrets (grafana admin, grafana-ts authkey)
  sops.secrets."grafana/admin_password" = {
    sopsFile = ./secrets.yaml;
    key = "grafana/admin_password";
    restartUnits = [ "grafana.service" ];
  };
  sops.secrets."grafana_ts/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "grafana_ts/ts_authkey";
    restartUnits = [ "grafana-ts.service" ];
  };

  sops.templates."grafana.env".content = ''
    GF_SECURITY_ADMIN_USER=admin
    GF_SECURITY_ADMIN_PASSWORD=${config.sops.placeholder."grafana/admin_password"}
    GF_USERS_ALLOW_SIGN_UP=false
  '';
  sops.templates."grafana-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."grafana_ts/ts_authkey"}
  '';
}
