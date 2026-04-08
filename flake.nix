{
  description = "Test config for comin system-manager deployment on non-NixOS Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    comin = {
      url = "github:trycua/comin/claude/add-system-manager-guide-EWK3t";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, system-manager, comin, ... }:
  let
    system = "aarch64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in
  {
    systemConfigs.system-manager-test = system-manager.lib.makeSystemConfig {
      modules = [
        comin.systemManagerModules.comin
        ./configuration.nix
      ];
    };
  };
}
