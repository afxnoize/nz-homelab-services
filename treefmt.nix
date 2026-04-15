{ ... }:
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.oxfmt = {
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
}
