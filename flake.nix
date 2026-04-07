{
  description = "Host service management for vault";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.default = pkgs.kopia;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.kopia
          pkgs.sops
          pkgs.age
          pkgs.yq-go
          pkgs.just
          pkgs.gomplate
        ];
      };
    };
}
