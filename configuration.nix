{ pkgs, lib, ... }:
{
  nixpkgs.hostPlatform = "aarch64-linux";

  services.comin = {
    enable = true;
    hostname = "system-manager-test";
    remotes = [{
      name = "origin";
      url = "https://github.com/trycua/system-manager-test.git";
      branches.main.name = "main";
    }];
  };

  # Example: install some packages via system-manager
  environment.systemPackages = [
    pkgs.htop
    pkgs.jq
    pkgs.curl
  ];
}
