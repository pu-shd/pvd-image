# Troubleshooting

Every failure mode below was hit for real while building this. Each one now has a
regression test, and each is worth knowing before you write your own guest
script — several are PowerShell or run-command traps that are invisible until
they bite.

The overarching lesson first: **a mocked CLI proves the driver's logic and
nothing about the guest.** How PowerShell parses a script, streams its output, or
quotes process arguments can only be established by a parser-level test or a real
run. Six real bugs got past a fully green mocked test suite. Two of them cost a
40-minute install cycle each to discover, which is why every driver has
`--dry-run` and why read-only guest probes are worth doing first.

## Reading a failure

Every run saves the raw instance view under `logs/`. Extract the parts that
matter:

```zsh
python3 -c "
import json
d=json.load(open('logs/<file>.log'))
iv=d['instanceView']
for k in ('executionState','exitCode','startTime','endTime'): print(k,'=',iv.get(k))
print('--- OUTPUT ---'); print(iv.get('output') or '(empty)')
print('--- ERROR ---');  print(iv.get('error') or '(empty)')
"
```

Two shapes tell you a lot before you read anything else:

- **Failed in under ~5 seconds** — the script did not run. Almost always a
  parse error or a rejected argument. Look at `error`.
- **`Succeeded` with `exitCode: 0` and empty `output`** — the script ran and
  produced nothing, which this tooling treats as failure. Usually a stream
  problem (see below), not an install problem.

## Guest script fails to parse in under a second

```
Unexpected attribute 'CmdletBinding'.
Unexpected token 'param' in expression or statement.
```

`param()` must be the **first statement** in a PowerShell script. Anything
prepended to the file — even a single variable assignment — makes the whole
script fail to parse.

Pass parameters through run-command's `--parameters` instead, which binds them to
`param()` by name:

```zsh
az vm run-command create ... --script "$(cat script.ps1)" \
  --parameters "ExpectedVersion=18.10.0" "InstallPath=C:\Program Files\..."
```

Values containing spaces survive this intact. Verified with a probe that echoed
the received parameter back.

## Exit code 0, no output at all

The classic PowerShell stream mistake. If a logging helper uses `Write-Output`,
its lines land on the **success stream** — which is a function's return value.
Consequences, all real:

- A function that returns an object instead returns *log strings*, so
  `$result.Version` throws `The property 'Version' cannot be found on this
  object` under `Set-StrictMode`
- `exit (Invoke-Main)` consumes the entire transcript as the argument to `exit`,
  so the run reports exit 0 with completely empty output

Fix: funnel all human-readable output through one helper that uses `Write-Host`,
which run-command captures as stdout while keeping it out of the pipeline.

```powershell
function Out-Line {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Host $Text     # captured by run-command; NOT part of any return value
}
```

Also assign before exiting, so nothing is swallowed:

```powershell
$exitCode = Invoke-Main
exit $exitCode
```

Confirmed on a live guest: a function calling `Out-Line` internally still
returned a clean `PSCustomObject`.

## Driver reports a nonsense reason like `AVD_REASON=$Reason`

`az vm run-command show --instance-view` returns the whole resource, which
includes `source.script` — **the script you uploaded.** Its literal marker lines
match any grep for those markers, so a driver scanning the full JSON matches its
own source code and thinks the guest reported something.

Read only the output field:

```zsh
az vm run-command show ... --instance-view --query "instanceView.output" -o tsv
```

The mock `az` in `tests/mocks/az` deliberately embeds decoy markers in
`source.script` so this cannot regress.

## A correct install reported as version drift

`vswhere`'s `installationVersion` is `major.minor.BUILD.revision` — e.g.
`18.10.12201.205`, where `12201` is the **build number**, not a patch level.
Comparing its first three components against a release version like `18.10.0`
fails on a perfectly good install.

Compare `catalog.productDisplayVersion` instead, and pin the build separately
with `catalog.buildVersion`. See
[visual-studio.md](visual-studio.md#two-version-numbers-and-which-one-to-compare).

## Visual Studio installed to `C:\Program`

`Start-Process -ArgumentList` joins its array elements with spaces and **does not
quote them**. An unquoted `C:\Program Files\...` therefore arrives at the child
process as several arguments. Proven on a guest by echoing `$args` from a child
script:

```
unquoted:  ARG1=[--installPath] ARG2=[C:\Program] ARG3=[Files\Microsoft] ARG4=[Visual] ...
quoted:    ARG1=[--installPath] ARG2=[C:\Program Files\Microsoft Visual Studio\2026\Community]
```

Quote any value containing whitespace yourself:

```powershell
function Format-Argument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}
```

And verify the outcome — the install path check exists precisely because the
installer reported success while landing somewhere else. Recover with
`./repair.sh --path 'C:\Program'`.

## `setup.exe uninstall` exits 87 immediately

```
Option 'wait' is unknown. Usage: setup.exe uninstall [options]
```

`--wait` is a **bootstrapper** option; the installed `setup.exe` does not accept
it for `uninstall`, and exit code 87 is "invalid parameter". Its valid options
are `--installPath`, `--path`, `--passive`, `--quiet`, `--norestart`,
`--channelUri`, `--force`, `--theme`, `--locale` and a few others — the error
output helpfully lists them.

Because there is no `--wait`, the process can return before the work finishes, so
poll for the actual outcome rather than trusting the exit code:

```powershell
# after the uninstaller returns, wait for vswhere to stop listing the instance
Wait-ForRemoval -InstallPath $Target -TimeoutSeconds 1800
```

## `az` reports exit 0 for a failed script

Not a bug in the tooling — a shell trap:

```zsh
./repair.sh --path 'C:\Program' | tee run.log    # exit code is tee's, not the script's
```

Avoid `| tee` on these drivers, or read `${PIPESTATUS[0]}` (`${pipestatus[1]}` in
zsh). It is exactly the "silence equals success" failure the tooling is designed
to prevent, reintroduced at the command line.

## Run-command hangs, then times out

Observed when piping `cmd.exe` output back through PowerShell under SYSTEM.
Redirect the child's output to a file and read the file afterwards instead:

```powershell
Start-Process cmd.exe -ArgumentList @('/c', $batPath) `
    -Wait -NoNewWindow -RedirectStandardOutput $outPath
Get-Content -LiteralPath $outPath
```

Note that `-RedirectStandardInput 'NUL'` is **not** valid in Windows PowerShell
5.1 — `Start-Process` fails silently and returns `$null`, so a following
`$p.ExitCode` yields nothing rather than an error.

## Bootstrapper download "succeeds" but the installer fails

The guest script rejects a bootstrapper under 1 MB or lacking an `MZ` header:

```
Bootstrapper is only 412 bytes - egress is probably blocked or redirected.
Bootstrapper is not a PE executable (no MZ header) - egress is probably intercepted.
```

That is what a captive portal or filtering proxy looks like: an HTML error page
delivered with HTTP 200. Check egress from the guest before a long run:

```powershell
Invoke-WebRequest -Uri 'https://aka.ms/vs/18/Stable/vs_community.exe' `
    -Method Head -UseBasicParsing -TimeoutSec 45
```

Better, pull a byte range to prove the CDN itself is reachable and not
intercepted — answering a redirect is not the same as serving the payload:

```powershell
$req = [Net.HttpWebRequest]::Create('https://aka.ms/vs/18/Stable/vs_community.exe')
$req.AddRange(0, 4095); $resp = $req.GetResponse()
$buf = New-Object byte[] 4096; $n = $resp.GetResponseStream().Read($buf,0,4096); $resp.Close()
"bytes=$n header=$(if ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) {'MZ-ok'} else {'NOT-PE'})"
```

## Run-command sits in `Pending` forever

The VM is running but the **guest agent** is not ready. Power state alone is not
enough:

```zsh
az vm get-instance-view -g <rg> -n <vm> \
  --query "instanceView.vmAgent.statuses[0].displayStatus" -o tsv
```

Wait for `Ready`. `common.sh`'s `wait_for_agent` does this after a `--start`.

## Testing pitfalls

Two that cost real time:

**`$script:Foo` does not reach a dot-sourced script's `param()` variables.**
Pester tests that appeared to set `ExpectedVersion` were silently relying on the
default happening to match, and a test that set an install path had no effect at
all. Make functions take explicit parameters and splat them from tests:

```powershell
$script:MainArgs = @{ Version = '18.10.0'; Build = ''; TargetPath = '' }
$rc = Invoke-Main @script:MainArgs
```

Do **not** name that hashtable `$Args` — `$args` is an automatic variable and the
splat silently fails to bind.

**`Join-Path` consults PowerShell drive providers.** A Windows path like
`C:\Users\Public\Desktop` throws `Cannot find drive. A drive with the name 'C'
does not exist` in the Linux test container. Use `[System.IO.Path]::Combine`,
which is pure string work, for paths that only exist on the guest.

## Getting a diagnostic onto the guest safely

Do not inline PowerShell inside a single-quoted shell string — the shell eats the
quotes, and `''` collapses to nothing, producing subtly different code on the
guest. This bit twice, once producing a C++ file with no string literal at all.

Write the probe to a file and pass its contents:

```zsh
az vm run-command create -g <rg> --vm-name <vm> --name probe \
  --subscription <sub> --timeout-in-seconds 240 -o none \
  --script "$(cat probe.ps1)"

az vm run-command show -g <rg> --vm-name <vm> --name probe \
  --subscription <sub> --instance-view --query "instanceView.output" -o tsv

az vm run-command delete -g <rg> --vm-name <vm> --name probe \
  --subscription <sub> --yes
```

For read-only probes, `az vm run-command invoke --command-id
RunPowerShellScript --scripts @probe.ps1` leaves no resource behind at all.
