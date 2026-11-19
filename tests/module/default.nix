{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  home = "/fixture/user";
  programs = import ../../nix/package.nix { inherit pkgs inputs; };
  # The production module, evaluated for one user and pointed at the fake Drive. The units it
  # generates are what the VM boots with.
  profile = (inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      (import ../../nix/module.nix { inherit inputs; })
      {
        services.drive = {
          enable = true;
          user = "fixture";
          api = "http://127.0.0.1:18475";
          pinned = [ "Pinned" ];
          followSeconds = 1;
          quietSeconds = 1;
          readers.deny = [ "never-reads" ];
          tray = true;
          freeFloorBytes = 0; # the test disk is small; with the default floor everything not pinned would be given back
        };
        networking.hostName = "module-test";
        users.users.fixture = { isNormalUser = true; inherit home; group = "users"; };
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        system.stateVersion = "24.11";
      }
    ];
  }).config;
  unit = name: "${profile.systemd.units.${name}.unit}/${name}";
  tray = profile.systemd.user.services.drive-tray;
in assert tray.wantedBy == [ "graphical-session.target" ] && pkgs.lib.hasSuffix "/bin/drive-tray" tray.serviceConfig.ExecStart
  && tray.environment.DRIVE_RUNTIME == "/run/drive" && tray.environment.DRIVE_MOUNT == "${home}/Drive"
  && profile.services.drive.statePaths == [ "/var/lib/drive" "${home}/.config/drive" ]
  && !profile.systemd.services.drive-door.restartIfChanged && profile.systemd.services.drive-engine.restartIfChanged
  && !profile.systemd.services.drive-engine.stopIfChanged
  && !(pkgs.lib.hasInfix "network-online.target" profile.systemd.units."drive-engine.service".text)  # the boot does not wait for the network on the engine's account
  && pkgs.lib.all (name: !(pkgs.lib.hasInfix "network-online.target" profile.systemd.units.${name}.text)) (pkgs.lib.filter (pkgs.lib.hasPrefix "drive-") (builtins.attrNames profile.systemd.units))
  && pkgs.lib.hasInfix "X-RestartIfChanged=false" profile.systemd.units."drive-door.service".text;  # a switch leaves the mount up and restarts the engine behind it  # the tray's icon starts with the desktop session and is told where the engine is
(import ../lib/vm-test.nix { inherit pkgs inputs; }) {
  name = "drive-module";
  nodes.machine = { ... }: {
    boot.kernelModules = [ "fuse" ];
    networking.hostName = "module-test";
    users.users.fixture = { isNormalUser = true; inherit home; uid = 1000; group = "users"; };
    systemd.tmpfiles.rules = [ "d /fixture 0755 root root -" ] ++ builtins.filter (pkgs.lib.hasInfix "/var/lib/drive") profile.systemd.tmpfiles.rules;
    environment.systemPackages = [ programs.drive programs.fake pkgs.curl pkgs.attr pkgs.python3 pkgs.libcap ];
    environment.sessionVariables = { inherit (profile.environment.sessionVariables) DRIVE_RUNTIME DRIVE_MOUNT; };
    systemd.packages = [ (pkgs.runCommand "drive-module-units" {} ''
      mkdir -p $out/lib/systemd/system
      cp ${unit "drive-door.service"} ${unit "drive-engine.service"} $out/lib/systemd/system/
    '') ];
    systemd.targets.multi-user.wants = [ "drive-door.service" "drive-engine.service" ];
    virtualisation.memorySize = 2048;
  };
  scenario = ./Main.btrc;
  extraFiles = [ ../Fixture.btrc ];
}
