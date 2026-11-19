{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
, files ? 1500  # pinned files the engine downloads
, writes ? 300  # files written through the mount, which it sends
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  programs = import ../../nix/package.nix { inherit pkgs inputs; };
in (import ../lib/vm-test.nix { inherit pkgs inputs; }) {
  name = "drive-profile-sync";
  nodes.machine = { ... }: {
    boot.kernelModules = [ "fuse" ];
    environment.systemPackages = [ programs.drive programs.fake pkgs.curl pkgs.attr pkgs.python3 pkgs.perf ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 4;
  };
  scenario = ./Main.btrc;
  settings = { inherit files writes; };
  extraFiles = [ ../Fixture.btrc ];
}
