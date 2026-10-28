# Windows portable CI helpers

These scripts are new QA/packaging tools, not a Windows executable. They have not
been run locally: this Linux executor has no PowerShell or Windows desktop.
Run the actual parser on the Windows runner **before** the expensive build:

```powershell
powershell.exe -NoProfile -File ci/test-script-syntax.ps1
if ($LASTEXITCODE -ne 0) { throw 'PowerShell parser failed' }
```

After building `solidcraft.exe` with the required `portable` feature:

```powershell
powershell.exe -NoProfile -File ci/windows-portable-smoke.ps1 `
  -Exe <release-exe> -EvidenceDir <new-smoke-directory>
if ($LASTEXITCODE -ne 0) { throw 'Native GUI smoke failed' }

powershell.exe -NoProfile -File ci/package-windows-portable.ps1 `
  -Exe <release-exe> -SourceRoot <reconstructed-source-root> `
  -BuildReceipt <build-receipt.json> `
  -SmokeResult <new-smoke-directory>/smoke-result.json `
  -OutputDir <new-dist-directory>
if ($LASTEXITCODE -ne 0) { throw 'Portable packaging failed' }
```

## Receipt contract

Build receipt required fields:

```json
{
  "build_status": "PASS",
  "engine_lift_plan": "PASS",
  "ui_lift_plan": "PASS",
  "portable_tests": "PASS",
  "base_commit": "7770f8982de8bf00cabfe421b7f563b34c7af90f",
  "delta_sha256": "<actual SHA256>",
  "portable_patch_sha256": "<actual SHA256>",
  "source_commit": "<actual private recipe commit>",
  "toolchain": "<actual rustc -vV output>",
  "target": "x86_64-pc-windows-msvc",
  "features": ["portable", "raytrace-cpu", "bundled-render-library"],
  "exe_sha256": "<actual SHA256>"
}
```

This example is a schema, **not evidence of passing gates**. The workflow must
write PASS only after the associated command exits 0 and parse/log actual test
counts. Include those counts, exit codes, commands and log hashes in the receipt.
The package script also requires four matching PASS smoke cases and identical EXE
hashes across build, smoke and package.

## Coverage and limits

- Normal renderer with a synthetic sample, safe mode with that sample, and a copy
  of normal-mode application/data moved to a folder with spaces and Unicode.
- A real first-presented-frame marker, native window screenshot with a nonblank
  sample check, clean exit and no crash reports.
- Native UI Automation opens File > Lift study and checks its title and
  NOT_VALIDATED warning in normal and moved cases. No fake screenshot or control
  token. Missing accessibility/desktop support fails rather than claiming PASS.
- Application-scoped process environment redirects profile and temp to new QA
  folders. Existing runner SolidCraft profile paths are inventoried read-only and
  compared, never emptied. The app must ignore deliberately hostile storage env
  overrides and keep its own state in `data` beside the EXE.
- Bounded TCP/UDP/child-process samples, token-file absence, and profile-write
  checks. This is **not** continuous network tracing, a global registry audit or
  a claim Windows leaves no traces.
- A plain file named `data` must be preserved while startup fails closed. No ACL
  or permission changes are made to simulate failure.
- Picker, import, persistence and repeated/cancel flows are not claimed by this
  native smoke; they need their separate tests/acceptance evidence.
- The packager checks x64 GUI PE headers, embedded icons, static/delay imports,
  no dynamic CRT imports, system DLL presence on the tested runner, unsigned
  state, per-member ZIP SHA256 and maximum ZIP size 250 MiB. Dynamic LoadLibrary
  dependencies and all Windows/driver versions are not exhaustively certified.

## Artifact safety and cost

Only upload the ZIP, `package-result.json`, `dumpbin-dependents.txt`, test/build
logs, smoke `*.json`/`*.txt`/`*.png`. **Never upload the entire smoke directory**:
it contains multiple test copies of the EXE and data. Never upload target/cache,
SDK/toolchain, PDB, real CAD, tokens or arbitrary profile files. The final ZIP
contains only the app, licenses/attribution, readme and compact receipts.

Use one Windows standard runner/job, concurrency serialization, a bounded timeout,
manual workflow dispatch only and retention 1 day. No Actions cache upload, MSI,
release, Pages/deployment, signing, certificates, credentials, account/ACL changes,
or paid runner. Preserve prior outputs by choosing new output/evidence directories.

Safety state remains **NO OPERATIVO / NOT_VALIDATED; RT750 NOT_VALIDATED**.
