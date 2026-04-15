{ ... }:
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.prettier = {
    enable = true;
    includes = [
      "*.md"
      "*.yaml"
      "*.json"
    ];
    excludes = [
      "flake.lock"
      "**/secrets.yaml"
    ];
  };

  settings.formatter.prettier = {
    options = [
      "--no-cache"
      "--cache-location"
      "/tmp/.prettier-cache"
    ];
  };
}
