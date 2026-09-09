# Visual Studio Community on an AVD image

`deploy.sh` installs Visual Studio Community with the C++ desktop workload onto
the image VM named in `config.env`, then verifies the result before reporting
success.

```zsh
./deploy.sh --dry-run       # show what would be dispatched
./deploy.sh --start         # start the VM if deallocated, then install
./deploy.sh                 # VM already running
```

## The version pinning problem — read this first

`config.env` asks for a specific version and build, but that version is
**asserted, not pinned**, and with Community it *cannot* be pinned:

- Microsoft publishes fixed-version bootstrappers for Enterprise, Professional
  and Build Tools only. **There is no fixed-version Community bootstrapper.**
- The [release history](https://learn.microsoft.com/en-us/visualstudio/releases/2026/release-history)
  states plainly: *"The Visual Studio Community edition is only supported on the
  Stable channel using the latest version of Visual Studio."*

So `https://aka.ms/vs/18/Stable/vs_community.exe` always installs whatever Stable
is current. The tooling's job is therefore to make drift **loud** rather than
silent. When a newer Stable ships, the run fails with:

```
guest installed 18.11.0 but config expects 18.10.0
```

At which point you choose deliberately:

```zsh
./update.sh --to 18.11.0     # record the new version in config.env and install
./deploy.sh --allow-drift    # one-off acceptance without editing config
```

`update.sh` backs up `config.env` to `config.env.bak` before editing it.

**If a genuinely frozen toolchain matters more than the IDE**, use **Build
Tools** instead: it has fixed-version bootstrappers and can be pinned exactly.
That trade — a pinnable compiler versus the Community IDE — is worth making
consciously rather than discovering later.

### Two version numbers, and which one to compare

`vswhere` reports both, and they are not the same shape:

| Field | Example | Meaning |
|---|---|---|
| `installationVersion` | `18.10.12201.205` | `major.minor.BUILD.revision` — the third component is the **build number**, not a patch level |
| `catalog.productDisplayVersion` | `18.10.0` | The advertised release version |
| `catalog.buildVersion` | `18.10.12201.205` | Build, same as installationVersion |

`VS_EXPECTED_VERSION` is compared against `productDisplayVersion`. You cannot
derive `18.10.0` from `18.10.12201.205` — an earlier version of this tooling
tried, and rejected a perfectly correct install as drift after a full 40-minute
run.

`VS_EXPECTED_BUILD` optionally pins the build too. Both the full
`18.10.12201.205` and the published tail `12201.205` are accepted, because the
release-history table publishes the latter. Leave it empty to accept any build
of the display version.

## What gets installed

Workload `Microsoft.VisualStudio.Workload.NativeDesktop` (*Desktop development
with C++*) with `--includeRecommended`, plus:

| Component ID | What it is |
|---|---|
| `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` | MSVC x64/x86 toolset |
| `Microsoft.VisualStudio.Component.Windows11SDK.26100` | Windows 11 SDK |
| `Microsoft.VisualStudio.Component.VC.CMake.Project` | CMake tools |
| `Microsoft.VisualStudio.Component.VC.ATL` | ATL |
| `Microsoft.VisualStudio.Component.VC.ASAN` | AddressSanitizer |
| `Microsoft.VisualStudio.Component.VC.DiagnosticTools` | C++ profiling tools |
| `Microsoft.VisualStudio.Component.Vcpkg` | vcpkg package manager |

Change these in the `$Workloads` / `$Components` defaults at the top of
`scripts/Install-VisualStudio.ps1`. IDs are listed in
[Visual Studio workload and component IDs](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-community?view=visualstudio).

To install a different edition, point `VS_BOOTSTRAPPER_URL` at
`vs_professional.exe` / `vs_enterprise.exe` / `vs_buildtools.exe`. The major
version in the URL path must match your target (`18` → Visual Studio 2026), and
note the channel segment is `Stable`, not `release` — `aka.ms/vs/18/release/...`
does not exist and silently redirects to a search page.

## Install path, and a trap worth knowing

`VS_INSTALL_PATH` is passed to the installer and then **verified** afterwards. If
Visual Studio lands anywhere else, the run fails:

```
Post-install verification failed: Visual Studio landed at 'C:\Program'
but 'C:\Program Files\Microsoft Visual Studio\2026\Community' was requested.
```

That check exists because of a real failure. PowerShell's
`Start-Process -ArgumentList` joins its array with spaces and **does not quote
the elements**, so an unquoted path with spaces reaches the installer as several
arguments and Visual Studio installs to `C:\Program`. Verified on a live guest:

```
unquoted:  ARG1=[--installPath] ARG2=[C:\Program] ARG3=[Files\Microsoft] ...
quoted:    ARG1=[--installPath] ARG2=[C:\Program Files\Microsoft Visual Studio\2026\Community]
```

Leave `VS_INSTALL_PATH` empty to accept the installer's default; the location
check is then skipped.

## How success is decided

The guest script does not trust the installer's exit code. After setup it:

1. Re-queries `vswhere` for the installed instance
2. Requires the install path to match what was requested
3. Requires a real `VC\Tools\MSVC\<ver>\bin\Hostx64\x64\cl.exe` on disk
4. Requires `productDisplayVersion` (and optionally `buildVersion`) to match

Exit codes are interpreted as: `0` success, `3010` success but a reboot is
required, `1602` cancelled, `1618` another install in progress, `5007` blocked by
a prerequisite check — anything else is a failure naming the code.

It also validates the downloaded bootstrapper is a real PE file over 1 MB, which
is how blocked or intercepted egress presents itself rather than as a clean
network error.

The run is **idempotent**: if the requested version, build, path and toolchain
are all already present, it reports success without touching anything. A partial
or mismatched install triggers the installer in `modify` mode against the
existing instance.

Markers on stdout, which the driver parses:

```
AVD_STATUS=success
AVD_VERSION=18.10.0
AVD_BUILD=18.10.12201.205
AVD_REBOOT_REQUIRED=false
AVD_REASON=installed and verified
```

## Timing

A first install takes **30–45 minutes** on 8 vCPUs. A reinstall shortly after is
much faster (~7 minutes observed) because the package payloads are still cached.

The dispatch is asynchronous, so **interrupting the driver does not stop the
install.** If you Ctrl-C, do not immediately re-run `deploy.sh` — it would delete
and recreate the run-command mid-install. Check on it instead:

```zsh
az vm run-command show -g <rg> --vm-name <vm> --subscription <sub> \
  --name install-vs-cpp --instance-view -o json
```

The managed run-command ceiling is 90 minutes; `AVD_RUNCMD_TIMEOUT_SECONDS`
defaults to 5400.

## Recovery: an install in the wrong place

```zsh
./repair.sh --path 'C:\Program'     # uninstall that instance
./deploy.sh                         # clean install, verified in place
```

`--path` is required — the uninstaller never guesses a target. It verifies via
`vswhere` that the instance is gone rather than trusting the exit code, and
removes the leftover directory only when it is empty (`--keep-dir` to leave it).

Note that `setup.exe uninstall` does **not** accept `--wait` (that is a
bootstrapper option; passing it fails immediately with exit code 87). Because
there is no `--wait`, the uninstaller process can return before the work is done,
so the script polls `vswhere` until the instance actually disappears.

## Verifying by hand

`run-command` cannot show you a GUI. To confirm the toolchain compiles, this is
the check used during development — it writes a source file, builds it with
`cl.exe` via `vcvars64.bat`, and runs the result:

```powershell
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2026\Community\VC\Auxiliary\Build\vcvars64.bat'
$dir = Join-Path $env:TEMP 'cpptest'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$q = [char]34
@(
  '#include <iostream>',
  'int main() {',
  "    std::cout << ${q}COMPILE_AND_RUN_OK${q} << std::endl;",
  '    return 0;',
  '}'
) -join "`r`n" | Set-Content -LiteralPath (Join-Path $dir 't.cpp') -Encoding ASCII

$bat = @(
  '@echo off',
  "call ${q}$vcvars${q} >nul 2>&1",
  "cd /d ${q}$dir${q}",
  'cl /nologo /EHsc t.cpp > compile.log 2>&1',
  'echo CL_ERRORLEVEL=%errorlevel%',
  'type compile.log',
  'if exist t.exe ( t.exe ) else ( echo NO_EXE_PRODUCED )'
) -join "`r`n"
Set-Content -LiteralPath (Join-Path $dir 'b.bat') -Value $bat -Encoding ASCII

# Capture to a file rather than piping: piping cmd output back through
# run-command has been observed to hang under SYSTEM.
$out = Join-Path $dir 'run.out'
Start-Process cmd.exe -ArgumentList @('/c', (Join-Path $dir 'b.bat')) `
    -Wait -NoNewWindow -RedirectStandardOutput $out
Get-Content -LiteralPath $out
```

Expect `CL_ERRORLEVEL=0` followed by `COMPILE_AND_RUN_OK`.
