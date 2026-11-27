# PyKX query client

`pykx.sh` installs a client for a kdb+/q server on the image, for every user.
Users on the session hosts can then query the server from Python with no
licence, no administrator rights and nothing to install.

```zsh
./pykx.sh --start            # install, verify, query the check host
./pykx.sh --dry-run          # show the parameters, change nothing
./pykx.sh --skip-check       # install without querying the server
./pykx.sh --remove           # take it all out again
```

## What it installs

Under `PYKX_INSTALL_PATH` (default `C:\Program Files\PyKX`). Users can read and
run anything under `Program Files`, but cannot change it.

| Path | What |
|---|---|
| `tools\uv.exe` | [uv](https://github.com/astral-sh/uv), downloaded from its GitHub release and checked against `PYKX_UV_SHA256`. Used only to build the environment, and not on `PATH` |
| `python\` | The CPython build uv downloads for `PYKX_PYTHON_VERSION` |
| `venv\` | A virtual environment with `pykx==PYKX_VERSION` and any `PYKX_EXTRA_PACKAGES`, compiled to bytecode at install time, because users cannot write `__pycache__` there |
| `bin\<prefix>-python.cmd` | Runs that environment's Python, licensed or not (below). `bin` goes on the machine `PATH` |
| `bin\<prefix>-test.cmd` | Queries `PYKX_CHECK_HOST:PYKX_CHECK_PORT` and prints `tables[]`. Only written when a check host is set |
| `<Public Desktop>\<name>.txt` | `PYKX_DESKTOP_README`, if set: your notes for users |

Also on the machine:

- The Visual C++ 2010 x64 runtime (`msvcr100.dll`), which PyKX loads on
  Windows. It is installed only if missing, from Microsoft's download, checked
  against a SHA-256 in the script. Microsoft's AVD marketplace images already
  have it.

uv puts the downloaded Python in the install folder, not in SYSTEM's profile,
and uses a temporary cache that is deleted afterwards. The environment is built
with `uv venv --python X.Y --python-preference only-managed`, which downloads a
Python on demand. That avoids `uv python install`, which also adds `PATH` shims
and registry entries.

## Licensed or unlicensed, per user

Each time `<prefix>-python` (or `<prefix>-test`) starts, it looks for a kdb
licence belonging to the user, in this order:

1. `QLIC`, if the user has set it
2. `kc.lic` or `k4.lic` in `%OneDrive%\<PYKX_LICENSE_FOLDER>` (personal OneDrive)
3. the same in `%OneDriveCommercial%\<PYKX_LICENSE_FOLDER>` (work or school OneDrive)
4. the same in `%USERPROFILE%\<PYKX_LICENSE_FOLDER>`

If it finds one, it sets `QLIC` to that folder and PyKX runs licensed, with q
inside the Python process. Otherwise it sets `PYKX_UNLICENSED=true`, and PyKX
sends queries to a q server over IPC, cannot run q locally, and needs no
licence. Both settings apply to that run only (`setlocal`), and nothing is set
machine-wide. A machine-wide `PYKX_UNLICENSED`, which earlier versions of this
step set, would stop a user's own licence from working, so the step removes it.

OneDrive is the suggested place on pooled hosts, which may not keep profiles
between sessions. Whether a user may use a given licence on shared
infrastructure is a question for its terms, not for this tooling. **Never put
a kdb licence on an image.** The step checks both cases on the image VM:

- With no licence present, `<prefix>-python` must start PyKX unlicensed. If
  it starts licensed, a licence file is reachable from the VM and the run fails.
- With an empty stand-in `kc.lic` in a temporary `%USERPROFILE%\<folder>`,
  `<prefix>-python` must set `QLIC` to that folder and leave unlicensed mode
  off. The check imports only `os`, so the empty file is never read.

## Pinning

As with Visual Studio, the template ships no versions: pin what you have tested.
`PYKX_VERSION` must match exactly. The run fails if the guest reads back any
other version from the environment. `PYKX_PYTHON_VERSION` is a minor version,
such as `3.12`, and any patch release of it passes.

The uv SHA-256 is published beside each release asset:

```zsh
curl -sL https://github.com/astral-sh/uv/releases/download/0.8.0/uv-x86_64-pc-windows-msvc.zip.sha256
```

Rerunning is safe. The environment is rebuilt only when the requested packages
or Python version differ from those recorded in `venv\avd-requirements.txt`,
or when PyKX no longer imports.

## The check

With `PYKX_CHECK_HOST` set, the guest runs `<prefix>-test` after installing,
and **a failed query fails the run**. An image whose users cannot reach their
server is not finished, and the usual cause is a firewall on the server side
that does not allow the image VM's outbound address. Fix that, or run with
`--skip-check` and test from a session host later.

## A desktop file for users

`PYKX_DESKTOP_README` names a text file in your config repo. `pykx.sh` sends it
base64-encoded, so quotes and backticks in example queries survive run-command
parameter passing. The guest writes it to the Public Desktop with Windows line
endings, reads it back, and reports its name; the driver fails if that name is
missing. `--remove` deletes it. The file holds whatever suits the course:
the commands, an example query, where a licence goes.

## What users run

From Command Prompt or PowerShell in a session on a host built from the image:

```
pykx-test                       # prints the server's tables
pykx-python my_query.py         # Python with PyKX
pykx-python -m jupyter lab      # if jupyterlab is in PYKX_EXTRA_PACKAGES
```

```python
import pykx as kx
q = kx.SyncQConnection('q.example.invalid', 5000, timeout=10)
print(q('tables[]'))
q.close()
```

Users cannot add packages to the shared environment. Add them to
`PYKX_EXTRA_PACKAGES` and rebuild the image.

## Why not WSL and q

Native q on Windows needs a licence on every host. Without a native build, q
runs under WSL, which a multi-session host handles badly: WSL2 needs nested
virtualization, each user installs their own Linux distribution, and WSL's NAT
networking can route around a VPN. Querying a remote server needs none of that.
