{
  config,
  pkgs,
  lib,
  vars,
}:
{
  virtualisation.quadlet.containers.victorialogs = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/victoriametrics/victoria-logs:latest";
      networks = [ "host" ];
      exec = [
        "-storageDataPath=/storage"
        "-retentionPeriod=${vars.retention.logs}"
        "-retention.maxDiskSpaceUsageBytes=${vars.diskBudget.logs}"
        "-httpListenAddr=:${toString vars.ports.vl}"
      ];
      volumes = [
        "victorialogs-data:/storage"
      ];
      # No healthCmd: the image ships neither sh nor wget since 20261001, so any CMD-SHELL probe fails (K-023)
      logDriver = "journald";
    };
    serviceConfig.Restart = "always";
  };
}
