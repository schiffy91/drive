{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  programs = import ../../nix/package.nix { inherit pkgs inputs; };
  contract = (inputs.btrc.lib.buildPackage pkgs) {
    name = "drive-remote-contract";
    src = (import ../lib/test-source.nix { inherit pkgs inputs; }) {
      root = ../..;
      fileset = pkgs.lib.fileset.unions [
        ./Main.btrc (pkgs.lib.fileset.fileFilter (file: file.hasExt "btrc") ../../src/remote)
      ];
    };
    programs.drive-remote-contract = "tests/remote/Main.btrc";
  };
  recorder = pkgs.writeShellScriptBin "curl" ''
    printf '%s\n' "$@" >> "$CURL_ARGUMENTS"
    exec ${pkgs.curl}/bin/curl "$@"
  '';  # stands where curl is found, and writes down what it was started with
in pkgs.runCommand "drive-remote" { nativeBuildInputs = [ recorder ]; } ''
  ${programs.fake}/bin/drive-fake 18473 > fake.log &
  fake=$!
  for attempt in $(seq 50); do grep -q READY fake.log && break; sleep 0.1; done
  mkdir scratch
  export CURL_ARGUMENTS=$PWD/curl-arguments
  ${contract}/bin/drive-remote-contract 18473 "$PWD/scratch" "$CURL_ARGUMENTS" || { kill $fake; exit 1; }
  kill $fake
  touch $out
''
