{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
}:
# Each safety rule is cut out of the client's source, one at a time, and the scenario that covers it is run
# against that client. The scenario has to fail, and at the step that is there for the rule.
let
  pkgs = import inputs.nixpkgs { inherit system; };
  inherit (pkgs) lib;
  cut = file: from: to: "substituteInPlace ${file} --replace-fail ${lib.escapeShellArg from} ${lib.escapeShellArg to}\n";
  mutants = [
    {
      rule = "a not-downloaded file is never handed to the kernel as it is";
      scenario = ../door;
      mutation = cut "door/Door.btrc" ''probe.attribute("state").equals("cloud") && !self.unguarded;'' "false;";
      at = "A read fetches its own range and nothing else";
      sees = "FAIL: machine: [ \"$(head -c 100 /mnt/drive/Media/big.bin | sha256sum)\"";
    }
    {
      rule = "a program reads only so much without a yes";
      scenario = ../readers;
      mutation = cut "engine/Readers.btrc" ''return use.files.len > self.budgetFiles || use.bytes > self.budgetBytes ? "ask" : "ok";'' ''return "ok";'';
      at = "With nobody to ask, a program that reads past its allowance is stopped there";
      sees = "FAIL: machine: expected failure, exit 0: cat /mnt/drive/Quiet/f*.bin";
    }
    {
      rule = "a file changed on both sides is kept twice";
      scenario = ../writes;
      mutation = cut "engine/Uploader.btrc" "action == PLAN_KEEP_BOTH && self.overwriteConflicts" "action == PLAN_KEEP_BOTH"
        + cut "engine/Mirror.btrc" "uploader != null && !uploader.overwriteConflicts &&" "false &&";
      at = "A file changed on both sides is kept twice";
      sees = "timed out waiting for ls /mnt/drive | grep -q 'conflict TEST'";
    }
    {
      rule = "many deletions made here wait for a yes";
      scenario = ../writes;
      mutation = cut "engine/Uploader.btrc" "if (!self.allowed && Planner.tooManyDeletions(" "if (false && Planner.tooManyDeletions(";
      at = "Many deletions at once wait for a yes, here";
      sees = "timed out waiting for drive status --runtime /run/drive-test | grep -q 'deletions held'";
    }
    {
      rule = "many deletions made on the Drive wait for a yes";
      scenario = ../writes;
      mutation = cut "engine/Mirror.btrc" "if (!self.allowDeletions && deletions > 0 && Planner.tooManyDeletions(" "if (false && Planner.tooManyDeletions(";
      at = "And on the Drive, however few changes it reports at a time";
      sees = "timed out waiting for drive status --runtime /run/drive-test | grep -q 'deletions held'";
    }
    {
      rule = "the engine answers the mount and commands between the files of a batch";
      scenario = ../writes;
      mutation = cut "engine/Uploader.btrc" "worked > 0 && MonotonicClock.milliseconds() >= until" "worked < 0 && MonotonicClock.milliseconds() >= until";
      at = "A long batch on its way up keeps the engine from nothing else";
      sees = "FAIL: machine: timeout 8 cat /mnt/drive/during.bin";
    }
    {
      rule = "deletions held here are written down for the engine that starts next";
      scenario = ../held;
      mutation = cut "engine/Uploader.btrc" ''for id in self.removals { lines.push(f"removed {id}"); }'' "";
      at = "The engine is killed and started again, and both batches still wait";
      sees = "timed out waiting for drive held --runtime /run/drive-test | grep -q '  here$'";
    }
    {
      rule = "a batch the Drive deletes is counted on across a restart";
      scenario = ../held;
      mutation = cut "engine/Mirror.btrc" "self.streak = store.streak();" "self.streak = 0;";
      at = "The engine is killed and started again, and both batches still wait";
      sees = "timed out waiting for drive held --runtime /run/drive-test | grep -q 'on the Drive$'";
    }
    {
      rule = "only what the Drive calls removed or trashed is taken for a deletion";
      scenario = ../refusals;
      mutation = cut "engine/Mirror.btrc" "return change.removed || (file != null && file.trashed);" "return change.removed || file == null || file.trashed;";
      at = "The Drive reports a change to a file and nothing readable about the file";
      sees = "FAIL: machine: cmp /mnt/drive/Docs/kept.bin";
    }
    {
      rule = "a change feed position the Drive has forgotten is not waited on";
      scenario = ../refusals;
      mutation = cut "engine/Mirror.btrc" "failure.kind == DRIVE_EXPIRED ? -3 : -1" "failure.kind == DRIVE_EXPIRED ? -1 : -1";
      at = "The Drive no longer has the place its changes were read to";
      sees = "timed out waiting for cmp -s /mnt/drive/since.txt";
    }
    {
      rule = "a store in another format is not opened";
      scenario = ../refusals;
      mutation = cut "store/Format.btrc" ''if (!written.equals(f"{StoreFormat.current()}"))'' "if (false)";
      at = "A store in a format this client does not know";
      sees = "FAIL: machine: expected failure, exit";
    }
    {
      rule = "an engine still reading its store is said to be starting";
      scenario = ../crashes;
      mutation = cut "Main.btrc" "if (!early.running || !early.starting) {" "if (true) {";
      at = "Before the engine listens the status says it is starting, and with no engine it says that";
      sees = "FAIL: machine: mkdir -p /run/drive-early";
    }
    {
      rule = "a piece that arrived is measured where it lies, not read into memory";
      scenario = ../pinning;
      mutation = cut "remote/DriveApi.btrc" "FileSystem.stat(path).size == last - first + 1LL" "(long long)FileSystem.readBytes(path).length() == last - first + 1LL";
      at = "A large pinned file arrives without the engine holding a piece of it in memory";
      sees = "FAIL: the engine's memory stayed far below one piece";
    }
    {
      rule = "the engine does not sleep on its one thread while the Drive says later";
      scenario = ../refusals;
      mutation = cut "Main.btrc" "api.waits = false;" "api.waits = true;";
      at = "A Drive that keeps saying later does not keep the engine from answering";
      sees = "FAIL: the engine itself answers";
    }
    {
      rule = "starting reads the folders and does not look at each file";
      scenario = ../pinning;
      mutation = cut "store/Store.btrc" ''for entry in StorePaths.kinds(path, true) {  // the folders alone, said by the listing: nothing is made or asked for each of the files'' ''for entry in StorePaths.kinds(path) { if (FileSystem.isSymlink(f"{path}/{entry.substring(1, entry.len() - 1)}") || !FileSystem.isDir(f"{path}/{entry.substring(1, entry.len() - 1)}")) { continue; }'';
      at = "An engine that starts reads the folders and does not look at each file";
      sees = "FAIL: with 3,000 files in one folder, starting took";
    }
    {
      rule = "a mount and an engine of different versions ask nothing of each other";
      scenario = ../door;
      mutation = cut "door/Door.btrc" "if (self.engine == null || self.engineSpeaks == self.speaks) { return self.engine; }" "if (true) { return self.engine; }";
      at = "A mount left from another version of the client";
      sees = "FAIL: what is downloaded reads as before, and what is not refuses to open";
    }
  ];
  failed = mutant: pkgs.testers.testBuildFailure (import mutant.scenario { inherit inputs system; inherit (mutant) mutation; });
in pkgs.runCommand "drive-mutations" { passthru.runs = map failed mutants; } (''
  mkdir -p $out
'' + lib.concatMapStrings (mutant: ''
  log=${failed mutant}/testBuildFailure.log
  step="$(grep -F -B1 -- ${lib.escapeShellArg mutant.sees} "$log" | head -1)"  # the step the scenario was in when it failed
  if [ "$step" != ${lib.escapeShellArg mutant.at} ] || grep -q '^PASS' "$log"; then
    echo ${lib.escapeShellArg "Without the rule '${mutant.rule}' the scenario did not fail where it should:"}
    tail -30 "$log"
    exit 1
  fi
  printf '%s\n  in the step: %s\n  %s\n' ${lib.escapeShellArg "Without '${mutant.rule}' the scenario fails"} "$step" "$(grep -F -- ${lib.escapeShellArg mutant.sees} "$log" | head -1 | cut -c1-200)" | tee -a $out/report
'') mutants)
