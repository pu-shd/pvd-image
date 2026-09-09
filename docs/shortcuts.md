# All-users desktop shortcuts

`shortcuts.sh` places shortcuts on the **Public Desktop** of the image VM, so
every user of a multi-session host sees them.

```zsh
./shortcuts.sh                  # apply AVD_SHORTCUTS from config.env
./shortcuts.sh --dry-run        # show what would be dispatched
./shortcuts.sh --remove         # take those same shortcuts away
./shortcuts.sh --spec 'Excel=C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE'
```

Runs in seconds, not minutes.

## Why Public Desktop

Shortcuts go in `C:\Users\Public\Desktop` (resolved at runtime via
`[Environment]::GetFolderPath('CommonDesktopDirectory')`, not hardcoded).

That location is the right one for a golden image because:

- Every user of a multi-session host sees it, including users created after the
  image was sealed
- It is **independent of FSLogix profiles**, so it survives a profile reset or a
  first-time logon on a new host
- It needs no per-user logon script or GPO

Writing to an individual user's desktop instead would only affect whichever
account happened to exist while you were building the image — usually the local
administrator, i.e. nobody who will actually use the desktop.

## Specifying shortcuts

`AVD_SHORTCUTS` (or `--spec`) takes `Name=Target` pairs separated by `;`:

```sh
AVD_SHORTCUTS="Excel=C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE;Word=C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"
```

- `Name` becomes the shortcut's filename (`Excel.lnk`) **and** is used to look
  for the application's own Start Menu shortcut — see below
- `Target` is the full path to the executable, and may contain spaces
- Only the **first** `=` separates the pair, so a target containing `=` (a
  command-line switch, say) survives intact
- A malformed pair — `Excel=` with no target, or a missing `=` — **throws**
  rather than being skipped, so a typo cannot quietly produce zero shortcuts

## Vendor icons come free

If `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<Name>.lnk` exists, that
file is **copied** rather than a new shortcut being synthesised. This preserves
whatever the vendor's installer set up — the real icon, any arguments, and any
Click-to-Run shim.

For Excel that means the shortcut gets Office's own icon resource:

```
LNK=Excel.lnk
   TARGET=C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE
   ICON=C:\Program Files\Microsoft Office\Root\VFS\Windows\Installer\{90160000-...}\xlicons.exe,0
```

rather than the generic executable icon a hand-built shortcut would show. Where
no Start Menu shortcut exists, one is created via `WScript.Shell` pointing at
`Target`, with the working directory set to the target's folder.

## Finding the right target path

Microsoft 365 Apps (Click-to-Run) x64 installs to
`C:\Program Files\Microsoft Office\root\Office16\`. Confirm on your own image:

```powershell
Get-ChildItem 'C:\Program Files\Microsoft Office' -Recurse -Filter 'EXCEL.EXE' |
    Select-Object -First 1 -ExpandProperty FullName

# Which Office products are installed
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' |
    Select-Object Platform, ProductReleaseIds, VersionToReport
```

Common Office executables in that folder: `EXCEL.EXE`, `WINWORD.EXE`,
`POWERPNT.EXE`, `OUTLOOK.EXE`, `ONENOTE.EXE`, `MSACCESS.EXE`.

## How success is decided

A shortcut counts as done only when it **resolves to a file that exists**. The
guest script reads the `.lnk` back through `WScript.Shell` after writing it and
fails if the target is empty or missing. A `.lnk` that exists but points at
nothing is exactly the kind of thing that looks fine in a directory listing and
is broken on the desktop.

It is also idempotent: a shortcut already pointing at the requested target is
left alone. One pointing somewhere else is replaced, with a warning naming the
old target.

The driver additionally checks the count:

```
asked for 3 shortcut(s) but the guest reported 1
```

A guest that creates one of three is a failure, not a partial success.

Markers on stdout:

```
AVD_SHORTCUT_OK=Excel
AVD_STATUS=success
AVD_SHORTCUT_COUNT=1
AVD_REASON=create completed for 1 shortcut(s)
```

## Verifying by hand

```powershell
$desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' | ForEach-Object {
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($_.FullName)
    "$($_.Name) -> $($sc.TargetPath)  exists=$(Test-Path -LiteralPath $sc.TargetPath)"
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}
```

## Adding other kinds of image step

This script is the smaller of the two worked examples and the better one to copy
when adding a new image step. The shape is:

1. A guest PowerShell script under `scripts/` that takes parameters, is
   idempotent, verifies its own work, and prints `AVD_STATUS=` /
   `AVD_REASON=` markers on **every** exit path
2. A zsh driver that loads config, dispatches via `az vm run-command create`,
   polls, then refuses to report success without explicit positive evidence
3. Both covered by tests — Pester for the guest logic, a zsh suite driving the
   entry point against the mock `az`

See [troubleshooting.md](troubleshooting.md) for the specific PowerShell and
run-command traps worth knowing before writing the guest script.
