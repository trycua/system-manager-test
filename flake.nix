{
  description = "System-manager config for CUA desktop environment (VNC + XFCE + CUA API)";

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
    novnc-src = {
      url = "github:trycua/noVNC";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, system-manager, comin, novnc-src, ... }:
  {
    systemConfigs.system-manager-test = system-manager.lib.makeSystemConfig {
      modules = [
        comin.systemManagerModules.comin
        { _module.args.novnc-src = novnc-src; }
        ./configuration.nix
      ];
    };
  };
}
