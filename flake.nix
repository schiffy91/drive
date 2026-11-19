{
  description = "drive: Google Drive at a mount point, every file in place, downloaded when opened";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    btrc = { url = "github:schiffy91/btrc"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, btrc }@inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = body: nixpkgs.lib.genAttrs systems body;
      pkgsFor = system: import nixpkgs { inherit system; };
      # A check is a test's default.nix, given this flake's inputs. `unit-` checks build and run a program;
      # `vm-` checks boot a NixOS guest and need KVM.
      test = system: path: import path { inherit inputs system; };
    in {
      packages = each (system:
        let programs = import ./nix/package.nix { pkgs = pkgsFor system; inherit inputs; };
        in { inherit (programs) drive tray ask status fake; default = programs.drive; });

      nixosModules.default = import ./nix/module.nix { inherit inputs; };

      checks = each (system: {
        unit-planner = test system ./tests/planner;
        unit-remote = test system ./tests/remote;
      } // builtins.listToAttrs (map (name: { name = "vm-${name}"; value = test system (./tests + "/${name}"); })
        [ "store" "door" "readers" "writes" "convergence" "pinning" "placement" "crashes" "held" "held-placed" "refusals" "dialog" "tray" "module" "mutations" ]));

      # Longer forms of checks, for a run that is not waited on: `nix build .#nightly.x86_64-linux.convergence-seeds`.
      nightly = each (system: {
        convergence-seeds = import ./tests/convergence { inherit inputs system; seeds = [ "20261113" "7" "424242" ]; };
        profile-sync = import ./tests/profile { inherit inputs system; };  # a measurement: where a sync's processor time goes
      });

      devShells = each (system: {
        default = (pkgsFor system).mkShell { packages = [ btrc.packages.${system}.btrcpy (pkgsFor system).pkg-config ]; };
      });
    };
}
