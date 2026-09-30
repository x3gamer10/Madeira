# Update packs

An update pack delivers changed Windows-side files to an installed Madeira without a new
IPA, so a fix to a Windows DLL does not cost a reinstall.

## What a pack can and cannot change

- **Can:** anything in the bundle's `aarch64-windows`, `arm64ec-windows` and
  `i386-windows` folders (Wine's PE DLLs, the FEX modules `xtajit.dll`/`xtajit64.dll`,
  DXMT's PE side, the 32-bit farm, Madeira Dock). To iOS these files are data: Wine maps
  them and runs the JIT pool's copy, so they are not covered by the app's code signature.
- **Cannot:** Madeira's own native code (the app, the unix side of Wine and DXMT, FEX's
  host side, the audio driver, the JIT pool). iOS only runs native code signed into the
  installed app, so those changes need a new IPA.

## How it works

1. `scripts/build-all-macos.sh` (stage `ipa`) hashes every file in the three folders into
   `build-logs/pe-manifest.txt` and stamps the manifest's SHA-256 into the app's
   `Info.plist` as `MadeiraPEBase`, the build's identity.
2. `scripts/make-update-pack.sh <installed build's pe-manifest.txt>` packs the files whose
   hash changed (or that are new) into `madeira-update.zip`, containing `madeira-updates/`
   with the same folder layout and `base.txt` = the installed build's `MadeiraPEBase`.
3. On the device, `madeira-updates` goes into On My iPhone › Madeira (the app's Documents).
4. At session start `WineProcessBridge.m` uses the pack only when `base.txt` equals the
   running build's `MadeiraPEBase`:
   - it links the pack's copy instead of the bundle's into `system32`, `syswow64`,
     `sysx64`, `sysaa64`, `syswow64\wbem` and `winsxs`, and
   - it exports `MADEIRA_DLL_OVERRIDES`, which `build/ntdll-unix/loader_ios.c`
     (`set_dll_path`) puts ahead of the bundle in the builtin DLL search path.

   The log says `[updates] pack active for build <id>: N file(s) in <folder>`, or
   `[updates] pack IGNORED` when the pack was made for another build. Installing a newer
   IPA therefore never runs an old pack's files; delete the folder to clean up.

A pack cannot remove a file the installed build has (the script warns when one was
removed). Packs are cumulative: make each one against the installed IPA's run, not
against the previous pack.

## Making a pack in CI

Every run of `.github/workflows/build-ios.yml` uploads a small `pe-manifest` artifact.
Start the workflow with **update_base_run** set to the run ID of the IPA installed on the
device; the run then also uploads `madeira-update` (the zip), or nothing when no
Windows-side file changed.

```
gh workflow run build-ios.yml -R <owner>/Madeira -f update_base_run=<run id of the installed IPA>
```

Builds before this feature carry no `MadeiraPEBase`, so they ignore every pack: the first
IPA with it has to be installed normally.
