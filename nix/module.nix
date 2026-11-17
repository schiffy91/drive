# services.drive: Google Drive at a mount point, for one user. The module knows nothing about the system it is
# used in beyond NixOS itself; what a host needs to know comes back in `statePaths`.
{ inputs }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.drive;
  home = config.users.users.${cfg.user}.home;
  programs = import ./package.nix { inherit pkgs inputs; };
  drive = "${programs.drive}/bin/drive";
  runtime = "/run/drive";
  credentials = "${home}/.config/drive/credentials.json";
  places = lib.concatStringsSep " " (lib.mapAttrsToList (path: location: "--place ${lib.escapeShellArg "${path}=${location}"}") cfg.placements
    ++ lib.mapAttrsToList (location: device: "--place-device ${lib.escapeShellArg "${location}=${device}"}") cfg.placementDevices);
  deny = pkgs.writeText "drive-readers.deny" (builtins.readFile ../src/readers.deny + lib.concatMapStrings (name: "${name}\n") cfg.readers.deny);
  engine = lib.concatStringsSep " " ([
    "${drive} engine --store ${lib.escapeShellArg cfg.store} --runtime ${runtime} --credentials ${lib.escapeShellArg credentials}"
    "--machine ${lib.escapeShellArg config.networking.hostName} --quiet ${toString cfg.quietSeconds} --follow ${toString cfg.followSeconds}"
    "--deny-file ${deny} --budget-files ${toString cfg.readers.budgetFiles} --ask ${programs.askSession}/bin/drive-ask-session"
    "--cache-bytes ${toString cfg.cacheBytes} --free-floor ${toString cfg.freeFloorBytes}"
    places
  ] ++ map (path: "--pin ${lib.escapeShellArg path}") cfg.pinned
    ++ map (name: "--ignore ${lib.escapeShellArg name}") cfg.ignore
    ++ lib.optional (cfg.api != null) "--api ${lib.escapeShellArg cfg.api}");
  # A door that died without unmounting leaves an endpoint that answers "not connected".
  prepare = pkgs.writeShellScript "drive-door-prepare" ''
    if ! ${pkgs.coreutils}/bin/stat ${lib.escapeShellArg cfg.mountPoint} >/dev/null 2>&1; then
      /run/wrappers/bin/umount -l ${lib.escapeShellArg cfg.mountPoint} >/dev/null 2>&1 || true
    fi
  '';
  # System units, not user ones: sleep freezes user.slice first, and a program waiting on a
  # mount whose server is already frozen can never freeze, so a suspend would fail.
  service = description: extra: lib.recursiveUpdate {
    inherit description;
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ home cfg.store ];
    unitConfig.StartLimitIntervalSec = 0; # keep trying; a unit that gave up would leave the mount missing until someone noticed
    serviceConfig = {
      User = cfg.user;
      RuntimeDirectory = "drive";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      Restart = "always";
      RestartSec = 1;
    };
  } extra;
in {
  options.services.drive = with lib.types; {
    enable = lib.mkEnableOption "Google Drive at a mount point: every file in place, downloaded when opened, pinned folders kept downloaded";
    user = lib.mkOption { type = str; description = "The user whose Drive it is. The units run as this user, and the sign-in is in this user's ~/.config/drive."; };
    group = lib.mkOption { type = str; default = config.users.users.${cfg.user}.group; defaultText = lib.literalExpression "the user's group"; description = "The group of the store's directory."; };
    mountPoint = lib.mkOption { type = strMatching "/.+"; default = "${home}/Drive"; defaultText = lib.literalExpression "~/Drive"; description = "Where the Drive appears."; };
    store = lib.mkOption { type = strMatching "/.+"; default = "/var/lib/drive/${cfg.user}"; defaultText = lib.literalExpression "/var/lib/drive/<user>"; description = "The real tree behind the mount. Reached only through the mount."; };
    pinned = lib.mkOption { type = listOf str; default = []; description = "Folders kept downloaded, by their path in the Drive. Declare the same ones on every machine."; };
    placements = lib.mkOption { type = attrsOf (strMatching "/.+"); default = {}; description = "Folders stored on another volume, by their path in the Drive, each with the folder on that volume that holds it."; };
    placementDevices = lib.mkOption { type = attrsOf (strMatching "/.+"); default = {}; description = "For a placement's folder on its volume, a device path that exists exactly while the volume is attached."; };
    cacheBytes = lib.mkOption { type = ints.unsigned; default = 0; description = "How much content outside pinned folders may stay downloaded; the least recently opened files are given back beyond it. 0 keeps everything."; };
    freeFloorBytes = lib.mkOption { type = ints.unsigned; default = 10 * 1024 * 1024 * 1024; description = "Give content outside pinned folders back when the store's disk has less than this free."; };
    readers.deny = lib.mkOption { type = listOf str; default = []; description = "Programs that may list the Drive but never cause a download, beside the list the client ships."; };
    readers.budgetFiles = lib.mkOption { type = ints.unsigned; default = 20; description = "Not-downloaded files a program may open per window before someone is asked. 0 never asks."; };
    ignore = lib.mkOption { type = listOf str; default = []; description = "Names of files and folders that stay on this machine and are never sent, beside the client's own list of what programs call their unfinished files."; };
    quietSeconds = lib.mkOption { type = ints.positive; default = 5; description = "How long a changed file must be left alone before it is uploaded."; };
    followSeconds = lib.mkOption { type = ints.positive; default = 60; description = "How often the Drive's change feed is read when nothing announces a change."; };
    push = lib.mkOption { type = bool; default = false; description = "Wait on the account's Pub/Sub topic and read the change feed as soon as the Drive announces a change. Needs `drive auth` and `drive push prepare` once."; };
    tray = lib.mkOption { type = bool; default = false; description = "Show the Drive in the desktop's system tray."; };
    api = lib.mkOption { type = nullOr str; default = null; description = "Another address for the Drive API. Tests point this at the fake."; };
    statePaths = lib.mkOption { type = listOf str; readOnly = true; description = "What has to outlive a reinstall or an erased root: the store and the sign-in."; };
  };

  config = lib.mkIf cfg.enable {
    services.drive.statePaths = [ "/var/lib/drive" "${home}/.config/drive" ];
    services.drive.ignore = [ "*.part" "*.crdownload" "*.kate-swp" ".~lock.*" ".goutputstream-*" ".#*" ];  # other modules add their programs' names
    environment.systemPackages = [ programs.drive ] ++ lib.optional cfg.tray programs.statusEntry;
    environment.sessionVariables = { DRIVE_RUNTIME = runtime; DRIVE_MOUNT = cfg.mountPoint; };
    systemd.tmpfiles.rules = [ "d /var/lib/drive 0755 root root -" "d ${cfg.store} 0700 ${cfg.user} ${cfg.group} -" ];

    # The door: the mount itself. Small, no network. It needs the one capability that
    # mounting and handing opened files to the kernel take, and nothing else.
    systemd.services.drive-door = service "Drive: the mount at ${cfg.mountPoint}" {
      serviceConfig = {
        ExecStartPre = [ "+${prepare}" "${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg cfg.mountPoint}" ];
        ExecStart = "${drive} door --store ${lib.escapeShellArg cfg.store} --mount ${lib.escapeShellArg cfg.mountPoint} --runtime ${runtime} ${places}";
        AmbientCapabilities = [ "CAP_SYS_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
        LimitNOFILE = 1048576; # one descriptor for every file the kernel remembers
      };
    };

    # The engine: everything that talks to Google. It may stop and start without the mount going away.
    systemd.services.drive-engine = service "Drive: sync with Google Drive" {
      after = [ "network-online.target" "drive-door.service" ];
      wants = [ "network-online.target" "drive-door.service" ];
      unitConfig.ConditionPathExists = credentials; # nothing to do until `drive auth`
      environment.DRIVE_RUNTIME = runtime; # for the window that asks about a program
      serviceConfig = {
        ExecStart = engine;
        Nice = 5;
      };
    };

    # The tray's icon belongs to the desktop session; where there is no tray to show it in it ends quietly.
    systemd.user.services.drive-tray = lib.mkIf cfg.tray {
      description = "Drive: the icon in the system tray";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      unitConfig.ConditionUser = cfg.user;
      environment = { DRIVE_RUNTIME = runtime; DRIVE_MOUNT = cfg.mountPoint; };  # a session that began before the client was installed has neither
      serviceConfig = {
        ExecStart = "${programs.tray}/bin/drive-tray";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };

    systemd.services.drive-push = lib.mkIf cfg.push (service "Drive: wait for the Drive to announce changes" {
      after = [ "network-online.target" "drive-engine.service" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathExists = credentials;
      serviceConfig = {
        ExecStart = "${drive} push listen --quiet --runtime ${runtime} --credentials ${lib.escapeShellArg credentials} --machine ${lib.escapeShellArg config.networking.hostName}";
        RestartSec = 30;
      };
    });
  };
}
