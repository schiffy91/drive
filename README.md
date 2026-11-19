# drive

Google Drive at a mount point on Linux. Every file is in its place; its contents are downloaded when a
program opens it, and folders you pin are kept downloaded. Changes made here are uploaded, changes made
elsewhere arrive, and a large batch of deletions waits for a yes.

Written in [BTRC](https://github.com/schiffy91/btrc). `PLAN.md` is the design and the record of how it
was measured and put into use.

## Layout

```
flake.nix          packages, nixosModules.default, checks, nightly, devShells
src/               the client: engine, door (the mount), store, remote (the Drive API), status, ask, push,
                   auth, and testing/FakeDrive.btrc, a Drive API from memory for the tests
nix/package.nix    the five programs, built with btrc.lib.buildPackage
nix/module.nix     services.drive
tests/             unit programs and VM scenarios; tests/lib lays a build out as the checkout is
ci/                the jobs a local pass can stand in for, and the script that builds the checks
```

## Using it

```nix
inputs.drive = { url = "github:schiffy91/drive"; inputs.nixpkgs.follows = "nixpkgs"; inputs.btrc.follows = "btrc"; };

# in a NixOS configuration
imports = [ inputs.drive.nixosModules.default ];
services.drive = {
  enable = true;
  user = "me";
  pinned = [ "Documents" ];
};
```

Then, once, as that user: `drive auth`. The Drive appears at `~/Drive`.

`services.drive.statePaths` (read-only) lists what has to outlive a reinstall or an erased root: the store
under `/var/lib/drive` and the sign-in in `~/.config/drive`. The module persists nothing by itself; a host
that erases its root adds these paths to what it keeps. The other options are in `nix/module.nix`, each
with its description: where the Drive is mounted and stored, folders placed on another volume, how much
may stay downloaded, which programs may never cause a download, names that are never sent, and the tray
icon.

Two system units do the work, `drive-door` (the mount, no network) and `drive-engine` (everything that
talks to Google). They are system units because a suspend freezes user units first, and a program waiting
on a mount whose server is frozen can never freeze.

## Commands

| Command | What it does |
|---|---|
| `drive auth` | sign in; the token is kept in `~/.config/drive` |
| `drive status` | online or not, what is waiting to be sent or downloaded, and why it waits; `starting` while the engine still reads what is on this machine |
| `drive held` | the deletions the brake is holding, each with where it was deleted |
| `drive resume` | yes: let the held deletions through |
| `drive keep` | no: bring back what was deleted here and is held |
| `drive readers` | programs that were stopped from downloading |
| `drive pause`, `drive unpause` | stop and start downloads |

## Across an update

A system switch leaves the mount up: `drive-door` is not restarted when its package changes
(`restartIfChanged = false`), so files open under `~/Drive` stay open, and the engine is restarted behind
it. The door that keeps running is the old one until the next boot or `systemctl restart drive-door`.
Door and engine greet each other with the version of what they say to each other. If the versions
differ, downloaded files work as before, a file that is not downloaded refuses to open, `drive status`
says `door of another version`, and each side says once in its log which versions met.

## The delete brake

A batch of more deletions than `--delete-limit` (50), made here or reported by the Drive, is not carried
out. It waits, listed by `drive held`, until `drive resume` or `drive keep`. The batch is still held after
the engine or the machine restarts, and a yes covers only the batch that was waiting when it was given.

## When in doubt

The client deletes nothing on a guess, and says what it did not understand:

- Only a change the Drive calls removed or trashed is a deletion. A change that arrives without a
  readable description of its file is left out and named in the log; what is here stays as it is.
- If the Drive no longer has the place its changes were read to, the whole Drive is read again. That
  removes nothing: what the Drive deleted in between stays here until it is deleted here, and a file
  changed on both sides is kept twice.
- The store names its format in the file `format` (1 today). The engine and the door refuse a store in
  any other format before touching it.
- The sign-in and every request's address reach `curl` in a private file under the runtime directory,
  never on its command line, which every process on the machine can read.

## Tests

```
ci/checks.sh unit     # two programs built and run: the planner's rules, the Drive API client
ci/checks.sh vm       # fifteen VM scenarios against the fake Drive; needs KVM
nix build .#nightly.x86_64-linux.convergence-seeds   # the convergence scenario over three seeds
```

Every test uses `drive-fake`. Nothing in this repository talks to a real Drive.

| Check | What it proves |
|---|---|
| `unit-planner`, `unit-remote` | the rule for each pair of local and remote states; the API client against the fake, with failures, expiry and paging, and nothing secret on a command line |
| `vm-store`, `vm-door`, `vm-readers`, `vm-writes` | the store's facts on a real filesystem; the mount, also against an engine of another version; who may cause a download; uploads, conflicts and the delete brake |
| `vm-pinning`, `vm-placement`, `vm-crashes`, `vm-convergence` | pinned folders, and a large one arriving without being held in memory; a folder on another volume; an engine killed mid-read and mid-upload, and what the status says before it listens; two clients ending with one tree |
| `vm-held`, `vm-held-placed`, `vm-refusals` | held deletions across an engine restart and a reboot; yes and no inside a placed folder; a full disk, a full Drive, a withdrawn sign-in, an unreadable change, a forgotten feed position and a store in another format |
| `vm-dialog`, `vm-tray`, `vm-module` | the window that asks; the tray icon and its window; the units `services.drive` generates |
| `vm-mutations` | each safety rule cut out of the client in turn: the scenario that covers it must then fail |

CI: `ci/local.json` names `lint` (`nix flake check --no-build`), `unit` and `vm`. A pass recorded with
[`ci-local`](https://github.com/schiffy91/ci-local) on the owner's machine stands in for the same job on
GitHub; `vm` runs only there.

For the editor and a local compiler, `make testkit` links btrc's test library at `tests/testkit`, where a
Nix build places it.

## Known gaps

- A program that deletes fewer files per pass of the engine than the limit is never held: the brake counts
  what is pending at once, not what was deleted over time.
- An upload the Drive refuses for a reason that is neither transient nor quota (a plain 400 or 403) is
  tried again about once a second.
- The tray and the status window say "Offline" for a refused sign-in and "Syncing" for a full disk or a
  full Drive; only `drive status` gives the reason.
- A yes given while the Drive cannot be reached can stay in force for the next batch the Drive reports.
- A pinned file whose download ends in an error other than "offline" leaves the queue until the engine
  restarts.
- A disk with no room at all reads as offline, because the feed position cannot be written.
- The engine does one transfer at a time and answers the mount and commands between transfers. While one
  large file is on its way it answers nobody: opening a file that is not downloaded waits for it, and
  `drive status` says what the engine last wrote down, marked as such.
- macOS is not supported.
