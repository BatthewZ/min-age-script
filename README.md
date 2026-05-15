# set-minimum-release-age

A pair of cross-platform scripts that turn on **"minimum release age"** (a.k.a. install cooldown) globally across the package managers you probably already use: **npm, pnpm, bun, yarn, uv (Python), composer (PHP)** and **cargo (Rust, via cargo-cooldown)**.

- [`set-minimum-release-age.sh`](set-minimum-release-age.sh) — Bash, for **macOS and Linux**.
- [`set-minimum-release-age.ps1`](set-minimum-release-age.ps1) — PowerShell, for **Windows** (Windows PowerShell 5.1+ or PowerShell 7+).

Both scripts do the same thing and accept the same options, with platform-idiomatic flag spellings (`--days=7` on the shell side, `-Days 7` on the PowerShell side).

## Why

The JS, PHP, Python and Rust ecosystems have all been hit by supply-chain attacks where an attacker publishes a malicious version of a popular package (via a stolen maintainer token, a compromised CI pipeline, a typosquat that gets aliased, etc.).

The pattern is almost always the same:

1. Bad version is published.
2. Someone notices within hours — usually because builds break, telemetry looks weird, or the malware itself is loud.
3. The version is yanked / deprecated / the maintainer rotates credentials.
4. Anyone who ran `npm install` (or pnpm / pip / composer / cargo …) during that window is compromised.

A **minimum release age** is the cheapest, highest-leverage defence against this: tell your package manager to ignore versions newer than N days. By the time you'd install `evil-package@2.4.1`, it's already been pulled. You get the fix for free, by doing nothing.

This script applies that setting in every place it can, all at once, so you don't have to remember seven different config keys and seven different duration units.

## What it does

- Writes a `min-release-age` / `minimumReleaseAge` / `exclude-newer` / `npmMinimalAgeGate` / `minimum-release-age` / `cooldown_minutes` setting into the appropriate global config file for each ecosystem.
- Converts your chosen number of days into whatever unit that ecosystem expects (npm wants days, pnpm wants minutes, bun wants seconds, yarn/uv/composer want duration strings, cargo-cooldown wants minutes).
- Prefers each tool's own CLI (`pnpm config set -g`, `yarn config set -H`, `composer global config`) when available, and falls back to direct file edits when not.
- Backs up every file it touches to `<path>.bak.<timestamp>` before editing — including Composer's global `config.json`, which the script reaches through `composer config --global home`.
- Is **idempotent** — re-running it just rewrites the same values, it won't duplicate lines.
- Knows the OS-specific config paths for pnpm and uv across macOS, Linux, and Windows.
- By default, **only configures ecosystems whose package manager is actually installed** — it won't litter your home dir with configs for tools you don't use. Pass `--include-absent` to also pre-seed configs for absent tools so they're protected the moment you install them.
- Refuses to proceed if stdin isn't a terminal (e.g. `curl … | bash`) unless you pass `--yes`. A security-themed script shouldn't apply changes without explicit consent.

The files it may create or modify:

**macOS / Linux:**

```
~/.npmrc
~/.config/pnpm/rc          (macOS: ~/Library/Preferences/pnpm/rc)
~/.bunfig.toml
~/.yarnrc.yml
~/.config/uv/uv.toml       (macOS: ~/Library/Application Support/uv/uv.toml)
Composer global config.json (via `composer global config`)
~/.cargo/cooldown.toml
```

**Windows:**

```
%USERPROFILE%\.npmrc
%LOCALAPPDATA%\pnpm\config\rc
%USERPROFILE%\.bunfig.toml
%USERPROFILE%\.yarnrc.yml
%APPDATA%\uv\uv.toml
Composer global config.json (via `composer global config`)
%USERPROFILE%\.cargo\cooldown.toml
```

## What it does *not* do

- **It is not a silver bullet.** A cooldown only buys you the window between a bad version being published and being yanked. It does nothing about:
  - **Typosquats** — `requestz` instead of `requests` is still malicious on day 8.
  - **Long-running compromises** — if a backdoor sits undiscovered for weeks, your cooldown will happily install it.
  - **Already-locked transitive dependencies** — anything pinned in your existing lockfile is unaffected.
  - **Local / private registries** that don't honour the upstream publish date.
- It doesn't touch **project-level** config (e.g. an in-repo `.npmrc`). It configures your user/global settings only.
- It doesn't install any package managers — if `cargo` isn't installed, the cargo section is skipped (pass `--include-absent` if you'd rather leave a config file ready for when you do install it).
- It doesn't install `cargo-cooldown` itself (the third-party runner that consumes `~/.cargo/cooldown.toml`). Native cargo support is still RFC-stage.
- It doesn't configure **pip** — pip has no equivalent setting. Use `uv pip` (which this script configures) or pin with hashes.
- It doesn't affect existing lockfiles. Things you've already installed stay installed.

## Flags

| Bash flag | PowerShell flag | What it does |
| --- | --- | --- |
| `--days=N` | `-Days N` | Cooldown length in days. Default: `7`. |
| `--dry-run` | `-DryRun` | Show exactly what would change — files, lines, CLI calls — without writing anything. |
| `--revert` | `-Revert` | Remove the settings this script previously wrote, in every ecosystem. Safe to run even if some tools have been uninstalled since (revert ignores `--include-absent` and always checks every ecosystem). |
| `--include-absent` | `-IncludeAbsent` | Also configure ecosystems whose package manager *isn't* installed yet, so they're protected once it is. Default is to skip absent tools. |
| `--no-backup` | `-NoBackup` | Skip the `.bak.<timestamp>` copies. Not recommended unless you know what you're doing. |
| `--keep-backups=N` | `-KeepBackups N` | Keep only the N most recent `.bak.<timestamp>` files per managed config; older ones are pruned at the end of the run. Default: keep all. Use `0` to delete every backup once the apply/revert completes. |
| `-y`, `--yes` | `-Yes` (`-y`) | Skip the "Proceed? [y/N]" prompt. **Required** when stdin isn't a terminal (e.g. piping into bash, or running headlessly) — the script refuses to auto-apply silently. |
| `--quiet` | `-Quiet` | Suppress the informational output. Errors still print. |
| `-h`, `--help` | `-Help` (`-h`) | Show usage and exit. |

A non-zero exit from one ecosystem will not stop the others — every tool is configured best-effort.

## Examples

### macOS / Linux

**Preview first** (always a good idea):

```bash
./set-minimum-release-age.sh --dry-run
```

**Just do it** with the default 7-day cooldown:

```bash
./set-minimum-release-age.sh
```

**Skip the prompt** — for use in dotfiles, Ansible, a fresh-machine setup script:

```bash
./set-minimum-release-age.sh --yes --quiet
```

**A more conservative 14-day cooldown:**

```bash
./set-minimum-release-age.sh --days=14
```

**Pre-seed configs for tools you haven't installed yet** (so they're protected the moment you `brew install pnpm` later):

```bash
./set-minimum-release-age.sh --include-absent
```

**Roll it all back:**

```bash
./set-minimum-release-age.sh --revert
```

**Keep only the 3 most recent backups per file** (handy if you re-run regularly and don't want `.bak.*` files piling up):

```bash
./set-minimum-release-age.sh --keep-backups=3
```

### Windows (PowerShell)

The same operations on Windows. Run from any PowerShell prompt (Windows PowerShell 5.1 or PowerShell 7+):

```powershell
# Preview
.\set-minimum-release-age.ps1 -DryRun

# Apply with the default 7-day cooldown
.\set-minimum-release-age.ps1

# Headless / unattended (skips the prompt)
.\set-minimum-release-age.ps1 -Yes -Quiet

# 14-day cooldown
.\set-minimum-release-age.ps1 -Days 14

# Pre-seed configs for tools you haven't installed yet
.\set-minimum-release-age.ps1 -IncludeAbsent

# Roll it all back
.\set-minimum-release-age.ps1 -Revert

# Keep only the 3 most recent .bak.* files per managed config
.\set-minimum-release-age.ps1 -KeepBackups 3
```

If PowerShell refuses to run the script with *"… cannot be loaded because running scripts is disabled on this system"*, either set the policy for your user once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

…or invoke it ad-hoc without changing any policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\set-minimum-release-age.ps1
```

### Bypassing the cooldown for one urgent install

(These are per-tool flags, not options of this script.)

```bash
npm install some-pkg --ignore-min-release-age
pnpm add some-pkg --config.minimumReleaseAge=0
uv add some-pkg --exclude-newer=now
```

## Requirements

**macOS / Linux (`set-minimum-release-age.sh`):**

- Bash.
- `awk`, `grep`, `cp`, `mv`, `mkdir`, `date` — standard on macOS and Linux.
- `python3` is used for the bun TOML edit if present; the script falls back to `awk` if not.

**Windows (`set-minimum-release-age.ps1`):**

- Windows PowerShell 5.1 (ships with Windows 10/11) or PowerShell 7+.
- No external dependencies — the script does the bun TOML edit in pure PowerShell, so Python is not required.

## A note on versions

Each ecosystem's cooldown key landed in a specific release:

- npm `min-release-age` — npm ≥ **11.10.0**
- pnpm `minimumReleaseAge` — pnpm ≥ **10.16**
- bun `minimumReleaseAge` — recent bun
- yarn `npmMinimalAgeGate` — Yarn Berry ≥ **4.10**
- uv `exclude-newer` — current uv
- composer `minimum-release-age` — Composer ≥ **2.9**
- cargo — no native support yet (RFC #3923); uses third-party `cargo-cooldown`

The script writes the config regardless of the installed version. Older tools will silently ignore an unknown key, and the protection will kick in the moment you upgrade.
