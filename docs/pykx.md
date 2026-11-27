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
| `bin\<prefix>-python.cmd` | Runs that environment's Python. `bin` goes on the machine `PATH` |
| `bin\<prefix>-test.cmd` | Queries `PYKX_CHECK_HOST:PYKX_CHECK_PORT` and prints `tables[]`. Only written when a check host is set |

Machine-wide settings:

- `PYKX_UNLICENSED=true`. PyKX runs in unlicensed mode, which sends queries to
  a q server over IPC. It cannot run q locally, and it needs no kdb licence.
  **Never put a kdb licence file on an image.**
- The Visual C++ 2010 x64 runtime (`msvcr100.dll`), which PyKX loads on
  Windows. It is installed only if missing, from Microsoft's download, checked
  against a SHA-256 in the script. Microsoft's AVD marketplace images already
  have it.

uv puts the downloaded Python in the install folder, not in SYSTEM's profile,
and uses a temporary cache that is deleted afterwards. The environment is built
with `uv venv --python X.Y --python-preference only-managed`, which downloads a
Python on demand. That avoids `uv python install`, which also adds `PATH` shims
and registry entries.

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
