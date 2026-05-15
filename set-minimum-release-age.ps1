<#
.SYNOPSIS
  Configures global "minimum release age" / "cooldown" settings across common
  package managers on Windows.

.DESCRIPTION
  Newly published versions are ignored for N days (default 7). This is one of
  the cheapest, highest-leverage defences against the recent wave of
  supply-chain attacks in the JS / PHP / Python / Rust ecosystems: malicious
  releases are usually identified and yanked within hours, so a 7-day cooldown
  means you almost never install a known-bad version.

  Each ecosystem expresses the duration differently:

    npm       min-release-age            DAYS               (npm >= 11.10.0)
    pnpm      minimumReleaseAge          MINUTES            (pnpm >= 10.16)
    bun       minimumReleaseAge          SECONDS            (bunfig.toml)
    yarn      npmMinimalAgeGate          DURATION STRING    (yarn >= 4.10)
    uv        exclude-newer              DURATION STRING    (uv.toml)
    composer  minimum-release-age        DURATION STRING    (composer 2.9+)
    cargo     cooldown_minutes           MINUTES            (cargo-cooldown, 3rd-party)

  The script is idempotent: re-running it just rewrites the same values.

  By default, only ecosystems whose package manager is installed are
  configured -- we don't litter the user profile with configs for tools you
  don't use. Pass -IncludeAbsent to write configs for absent tools too
  (useful if you plan to install them later and want them pre-protected).

.PARAMETER Days
  Cooldown length in days. Default: 7.

.PARAMETER DryRun
  Show what would change without writing anything.

.PARAMETER Revert
  Remove the settings this script previously wrote.

.PARAMETER IncludeAbsent
  Also write configs for ecosystems whose package manager is NOT installed,
  so they're protected once installed. Default is to skip absent tools.

.PARAMETER NoBackup
  Don't create .bak.<timestamp> copies before editing.

.PARAMETER KeepBackups
  Keep only the N most recent .bak.<timestamp> files per managed config.
  Default: -1 (keep all). Pruning runs at the end of an apply or revert.

.PARAMETER Yes
  Skip the confirmation prompt. Required when stdin is not a terminal
  (e.g. piping from another command).

.PARAMETER Quiet
  Suppress informational output (errors still printed).

.PARAMETER Help
  Show help and exit.

.EXAMPLE
  .\set-minimum-release-age.ps1 -DryRun

.EXAMPLE
  .\set-minimum-release-age.ps1 -Days 14

.EXAMPLE
  .\set-minimum-release-age.ps1 -Revert
#>

[CmdletBinding()]
param(
  [int]$Days = 7,
  [switch]$DryRun,
  [switch]$Revert,
  [switch]$IncludeAbsent,
  [switch]$NoBackup,
  [int]$KeepBackups = -1,
  [Alias('y')][switch]$Yes,
  [switch]$Quiet,
  [Alias('h')][switch]$Help
)

# Best-effort across many package managers: a failure in one (e.g. an older
# npm that doesn't know the option yet) must not stop the others from being
# configured. So we keep ErrorActionPreference at its default (Continue) and
# guard individual commands ourselves.
$ErrorActionPreference = 'Continue'

function Show-Usage {
  @"
Usage: .\set-minimum-release-age.ps1 [options]

Configures a "minimum release age" cooldown across npm, pnpm, bun, yarn,
uv (Python), composer (PHP), and cargo (Rust, via cargo-cooldown).

Options:
  -Days N             Cooldown length in days (default: 7).
  -DryRun             Show what would change without writing anything.
  -Revert             Remove the settings this script previously wrote.
  -IncludeAbsent      Also write configs for ecosystems whose package manager
                      is NOT installed, so they're protected once installed.
                      Default is to skip absent tools.
  -NoBackup           Don't create .bak.<timestamp> copies before editing.
  -KeepBackups N      Keep only the N most recent .bak.<timestamp> files per
                      managed config (default: -1 = keep all).
  -Yes  (-y)          Skip the confirmation prompt. Required when stdin is
                      not a terminal.
  -Quiet              Suppress informational output (errors still printed).
  -Help (-h, -?)      Show this help.
"@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

if ($Days -lt 0) {
  Write-Error "-Days must be a non-negative integer (got: $Days)"
  exit 2
}

# ---- N days expressed in every flavour -----------------------------------
$Minutes        = $Days * 24 * 60          # 10080 when Days=7
$SecondsTotal   = $Days * 24 * 60 * 60     # 604800 when Days=7
$Duration       = "${Days}d"               # "7d"
$DurationHuman  = "$Days days"             # "7 days"
$TS             = (Get-Date).ToString('yyyyMMdd-HHmmss')

# ---- pretty output --------------------------------------------------------
# Route normal output through Write-Host so it integrates with whatever
# PowerShell host the user is in (the regular console, ISE, the VSCode
# integrated terminal, a remoting session, etc.) and so colour downgrade
# happens automatically when the host doesn't support ANSI/console colours.
# Warnings still go to stderr via [Console]::Error so they survive a plain
# `>` redirection of stdout, matching the bash script's behaviour. We
# deliberately don't use Write-Warning here: it would add a "WARNING: "
# prefix and could be suppressed by $WarningPreference, which isn't what
# users expect from a setup script.
function Write-Coloured([string]$Symbol, [ConsoleColor]$Colour, [string]$Text, [switch]$ToErr) {
  if ($Quiet -and -not $ToErr) { return }
  if ($ToErr) {
    [Console]::Error.WriteLine("  $Symbol $Text")
  } else {
    Write-Host "  $Symbol " -ForegroundColor $Colour -NoNewline
    Write-Host $Text
  }
}

function Ok   ([string]$m) { Write-Coloured 'OK  ' Green   $m }
function Skip ([string]$m) { Write-Coloured '..  ' Yellow  $m }
function Note ([string]$m) { Write-Coloured 'i   ' Cyan    $m }
function Warn ([string]$m) { Write-Coloured '!   ' Red     $m -ToErr }
function Hdr  ([string]$m) {
  if ($Quiet) { return }
  Write-Host ''
  Write-Host '==> ' -ForegroundColor Cyan -NoNewline
  Write-Host $m
}

function Have([string]$Cmd) {
  return [bool](Get-Command -Name $Cmd -ErrorAction SilentlyContinue)
}

# Should we touch the given ecosystem this run? Always yes on revert (we may
# need to clean up after a tool that's since been uninstalled). On apply,
# yes if the tool is installed OR -IncludeAbsent was passed.
function Should-Configure([string]$Tool) {
  if ($Revert)        { return $true }
  if ($IncludeAbsent) { return $true }
  return (Have $Tool)
}

# ---- Windows-specific config locations -----------------------------------
# npm, bun, yarn, cargo all put their config under the user profile.
# pnpm on Windows uses %LOCALAPPDATA%\pnpm\config\rc.
# uv on Windows uses %APPDATA%\uv\uv.toml.
$Home_         = $env:USERPROFILE
$LocalAppData  = $env:LOCALAPPDATA
$AppData       = $env:APPDATA

if (-not $Home_)        { $Home_        = [Environment]::GetFolderPath('UserProfile') }
if (-not $LocalAppData) { $LocalAppData = [Environment]::GetFolderPath('LocalApplicationData') }
if (-not $AppData)      { $AppData      = [Environment]::GetFolderPath('ApplicationData') }

$NpmRc           = Join-Path $Home_        '.npmrc'
$PnpmRcDefault   = Join-Path $LocalAppData 'pnpm\config\rc'
$BunFig          = Join-Path $Home_        '.bunfig.toml'
$YarnRc          = Join-Path $Home_        '.yarnrc.yml'
$UvConfigDir     = Join-Path $AppData      'uv'
$UvToml          = Join-Path $UvConfigDir  'uv.toml'
$CargoCooldown   = Join-Path $Home_        '.cargo\cooldown.toml'

# Files this script may create, edit, or back up. Used by the end-of-run
# -KeepBackups pruner. Composer's config.json is appended later, once we've
# asked composer where its global home lives.
$script:ManagedFiles = New-Object System.Collections.Generic.List[string]
$script:ManagedFiles.Add($NpmRc)         | Out-Null
$script:ManagedFiles.Add($PnpmRcDefault) | Out-Null
$script:ManagedFiles.Add($BunFig)        | Out-Null
$script:ManagedFiles.Add($YarnRc)        | Out-Null
$script:ManagedFiles.Add($UvToml)        | Out-Null
$script:ManagedFiles.Add($CargoCooldown) | Out-Null

# Files already backed up this run, so we only ever create one timestamped
# backup per file even if it's touched in multiple sections.
$script:BackedUp = New-Object 'System.Collections.Generic.HashSet[string]' (
  [System.StringComparer]::OrdinalIgnoreCase
)

function Backup-File([string]$Path) {
  if ($NoBackup) { return }
  if ($DryRun)   { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  if ($script:BackedUp.Contains($Path)) { return }
  $bak = "$Path.bak.$TS"
  try {
    Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop
    [void]$script:BackedUp.Add($Path)
    Note "backed up $Path -> $bak"
  } catch {
    Warn "could not back up $Path -- continuing without backup ($($_.Exception.Message))"
  }
}

# Read a file's lines, preserving content exactly. Returns @() for missing.
function Read-Lines([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  # -Raw + split avoids PowerShell's habit of returning a single string when
  # the file has only one line.
  $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  if ($null -eq $text -or $text.Length -eq 0) { return @() }
  # Normalise CRLF/LF; we'll write back with the platform default later.
  return ($text -split "`r?`n")
}

# Write lines back to a file using LF line endings. Most of the package
# manager configs we touch are read by tools that originated on Unix; LF
# is the safer default and avoids spurious "modified" diffs in dotfile repos.
function Write-Lines([string]$Path, [string[]]$Lines) {
  $dir = Split-Path -LiteralPath $Path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if ($null -eq $Lines -or $Lines.Count -eq 0) {
    # No content left (e.g. -Revert removed the only line in the file).
    # Write a truly empty file rather than a stray "\n", to match the bash
    # script, which produces an empty file via `awk '...' > tmp && mv tmp f`.
    $body = ''
  } else {
    # Trim trailing empty entries from a -split, then ensure a single
    # trailing newline.
    $body = ($Lines -join "`n").TrimEnd("`n") + "`n"
  }
  # Write as UTF-8 *without* BOM. .NET's UTF8Encoding($false) does this; the
  # built-in -Encoding UTF8 in Windows PowerShell 5.1 emits a BOM that some
  # of these config readers dislike.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $body, $utf8NoBom)
}

# Replace the first line matching <Regex> in <Path>, or append <Line>.
# Mirrors the bash upsert_line: works for npmrc-style (key=value) and
# yarnrc.yml-style (key: value) by letting the caller pass the literal line.
function Upsert-Line([string]$Path, [string]$Regex, [string]$Line) {
  if ($DryRun) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and ((Read-Lines $Path) -match $Regex)) {
      Note "[dry-run] would replace matching line in $Path with: $Line"
    } else {
      Note "[dry-run] would append to ${Path}: $Line"
    }
    return
  }
  $existed = Test-Path -LiteralPath $Path -PathType Leaf
  if ($existed) { Backup-File $Path }
  $lines = Read-Lines $Path
  $rx    = [regex]$Regex
  $found = $false
  $new   = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) {
    if (-not $found -and $rx.IsMatch($l)) {
      $new.Add($Line) | Out-Null
      $found = $true
    } else {
      $new.Add($l) | Out-Null
    }
  }
  if (-not $found) { $new.Add($Line) | Out-Null }
  Write-Lines $Path $new.ToArray()
}

# Remove every line matching <Regex> from <Path>. Used by -Revert.
# Returns $true if a matching line was found (and removed, or would be in
# dry-run mode), $false if there was nothing to do.
function Remove-Line([string]$Path, [string]$Regex) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $lines = Read-Lines $Path
  $rx    = [regex]$Regex
  if (-not ($lines | Where-Object { $rx.IsMatch($_) })) { return $false }
  if ($DryRun) {
    Note "[dry-run] would remove lines matching '$Regex' from $Path"
    return $true
  }
  Backup-File $Path
  $kept = $lines | Where-Object { -not $rx.IsMatch($_) }
  Write-Lines $Path @($kept)
  return $true
}

# Delete all but the N most recent .bak.<TS> files for each managed config.
# Honours -DryRun. No-op when KeepBackups is negative (the default).
#
# We sort by the YYYYMMDD-HHMMSS suffix in the filename rather than by file
# mtime: Copy-Item preserves the source's timestamps in some cases and not
# in others, while filename suffixes are guaranteed unique per run and sort
# lexicographically == chronologically.
function Prune-Backups {
  if ($KeepBackups -lt 0) { return }
  foreach ($f in $script:ManagedFiles) {
    $dir  = Split-Path -LiteralPath $f -Parent
    $base = Split-Path -LiteralPath $f -Leaf
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $pattern = "$base.bak.*"
    $baks = Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending
    if (-not $baks -or $baks.Count -le $KeepBackups) { continue }
    $toDelete = $baks | Select-Object -Skip $KeepBackups
    foreach ($b in $toDelete) {
      if ($DryRun) {
        Note "[dry-run] would prune old backup: $($b.FullName)"
      } else {
        try {
          Remove-Item -LiteralPath $b.FullName -Force -ErrorAction Stop
          Note "pruned old backup: $($b.FullName)"
        } catch {
          Warn "could not prune $($b.FullName): $($_.Exception.Message)"
        }
      }
    }
  }
}

# Ask composer where its global config dir lives and back up config.json
# before the CLI mutates it. Also adds the path to ManagedFiles so
# -KeepBackups picks it up.
function Backup-ComposerConfig {
  if (-not (Have 'composer')) { return }
  $cc_home = $null
  try {
    $cc_home = (& composer config --global home 2>$null | Out-String).Trim()
  } catch {}
  if (-not $cc_home) { return }
  $cc_config = Join-Path $cc_home 'config.json'
  if (-not ($script:ManagedFiles -contains $cc_config)) {
    $script:ManagedFiles.Add($cc_config) | Out-Null
  }
  Backup-File $cc_config
}

# ---- preamble & confirmation ---------------------------------------------
if     ($Revert) { $ActionLabel = 'REVERT (remove) the' }
elseif ($DryRun) { $ActionLabel = 'PREVIEW a' }
else             { $ActionLabel = 'APPLY a' }

if (-not $Quiet) {
@"

This script will $ActionLabel $Days-day "minimum release age" cooldown across:
  npm, pnpm, bun, yarn, uv (Python), composer (PHP), and cargo (via cargo-cooldown).

What this means in practice:
  * Installs will refuse versions younger than $Days days from upstream.
  * Lockfile updates and CI matrices that resolve "latest" may pick older versions.
  * For genuine hot-fixes you may need a per-project override (e.g. npm's
    --ignore-min-release-age, or temporarily setting the value to 0).
  * This is ONE defensive layer. Typosquats, long-lived compromises, and
    already-locked transitive dependencies are NOT mitigated by a cooldown.

Files that may be created or edited:
  $NpmRc
  $PnpmRcDefault
  $BunFig
  $YarnRc
  $UvToml
  Composer global config.json (via ``composer global config``)
  $CargoCooldown

"@ | Write-Host

  if (-not $Revert) {
    if ($IncludeAbsent) {
      Write-Host "-IncludeAbsent: configs will be written for ecosystems even if their package manager isn't installed."
    } else {
      Write-Host "Note: ecosystems whose package manager isn't installed will be skipped. Pass -IncludeAbsent to write their configs anyway."
    }
  }
  if (-not $DryRun -and -not $NoBackup) {
    Write-Host "Existing files will be copied to '<path>.bak.$TS' before being edited."
    Write-Host ''
  } elseif (-not $DryRun -and $NoBackup) {
    Write-Host "-NoBackup is set: existing files will be edited in place."
    Write-Host ''
  }
}

if (-not $DryRun -and -not $Yes) {
  # Decide whether there's actually a human present to answer the prompt.
  # Two distinct signals matter on Windows:
  #   * IsInputRedirected catches `something | powershell -File script.ps1`
  #     and similar — stdin is a pipe, not a TTY.
  #   * UserInteractive catches Scheduled Tasks, Windows Services, and other
  #     session-0 / non-interactive launches where stdin isn't formally
  #     redirected but there's no console attached. Without this check,
  #     Read-Host would hang forever waiting for input that never comes.
  # The bash equivalent (`[ -t 0 ]`) implicitly covers both cases on Unix.
  $stdinIsTerminal = $true
  try {
    if ([Console]::IsInputRedirected) { $stdinIsTerminal = $false }
  } catch { $stdinIsTerminal = $false }
  if (-not [Environment]::UserInteractive) { $stdinIsTerminal = $false }

  if ($stdinIsTerminal) {
    $reply = Read-Host 'Proceed? [y/N]'
    if ($reply -notmatch '^(?i:y|yes)$') {
      Write-Host 'Aborted.'
      exit 1
    }
  } else {
    # Non-interactive (piped, headless, or session-0) and no -Yes: refuse to
    # proceed silently. This is a security script; we don't want it to apply
    # changes without an explicit opt-in.
    [Console]::Error.WriteLine("Refusing to proceed: no interactive terminal available and -Yes was not given.")
    [Console]::Error.WriteLine("Re-run with -Yes to confirm, or -DryRun to preview without writing.")
    exit 1
  }
}

# ===========================================================================
# npm  --  ~\.npmrc, value in DAYS
# ===========================================================================
Hdr 'npm'
$NpmRegex = '^\s*min-release-age\s*='
# npm < 11.10.0 rejects unknown keys via `npm config set`, so we always write
# the rc file directly. npm reads unknown keys from .npmrc without error,
# which means the setting starts working the moment npm is upgraded.
if ($Revert) {
  if (Remove-Line $NpmRc $NpmRegex) {
    Ok "npm: removed min-release-age from $NpmRc"
  } else {
    Skip "npm: no min-release-age in $NpmRc; nothing to remove"
  }
} elseif (Should-Configure 'npm') {
  Upsert-Line $NpmRc $NpmRegex "min-release-age=$Days"
  if (Have 'npm') {
    $npmVer = try { (& npm --version 2>$null).Trim() } catch { '?' }
    Ok "npm ($npmVer): min-release-age=$Days (days) in $NpmRc -- active from npm 11.10.0"
  } else {
    Skip "npm not installed; wrote min-release-age=$Days to $NpmRc for later"
  }
} else {
  Skip "npm not installed; skipped. Pass -IncludeAbsent to write config anyway"
}

# ===========================================================================
# pnpm  --  global rc, value in MINUTES
# ===========================================================================
Hdr 'pnpm'
$PnpmRegex = '^\s*minimumReleaseAge\s*='
# Prefer `pnpm config set -g` when available -- pnpm knows where its own rc
# file lives on this machine, which may differ from $PnpmRcDefault. Always
# also touch the known rc path as a belt-and-braces fallback for environments
# where the CLI rejects the key.
if ($Revert) {
  if (Have 'pnpm') {
    if ($DryRun) {
      Note "[dry-run] would run: pnpm config delete -g minimumReleaseAge"
    } else {
      try { & pnpm config delete -g minimumReleaseAge *>$null } catch {}
    }
  }
  if (Remove-Line $PnpmRcDefault $PnpmRegex) {
    Ok "pnpm: removed minimumReleaseAge from $PnpmRcDefault"
  } else {
    Skip "pnpm: no minimumReleaseAge in $PnpmRcDefault; nothing to remove (CLI unset already attempted)"
  }
} elseif (-not (Should-Configure 'pnpm')) {
  Skip "pnpm not installed; skipped. Pass -IncludeAbsent to write config anyway"
} else {
  $appliedViaCli = $false
  if (Have 'pnpm') {
    if ($DryRun) {
      Note "[dry-run] would run: pnpm config set -g minimumReleaseAge $Minutes"
      $appliedViaCli = $true
    } else {
      try {
        & pnpm config set -g minimumReleaseAge $Minutes *>$null
        if ($LASTEXITCODE -eq 0) { $appliedViaCli = $true }
      } catch {}
    }
  }
  Upsert-Line $PnpmRcDefault $PnpmRegex "minimumReleaseAge=$Minutes"
  if (Have 'pnpm') {
    $pnpmVer = try { (& pnpm --version 2>$null).Trim() } catch { '?' }
    if ($appliedViaCli) {
      Ok "pnpm ($pnpmVer): minimumReleaseAge=$Minutes (minutes = ${Days}d) via ``pnpm config set`` + $PnpmRcDefault"
    } else {
      Ok "pnpm ($pnpmVer): minimumReleaseAge=$Minutes written to $PnpmRcDefault (CLI rejected the key)"
    }
  } else {
    Skip "pnpm not installed; wrote minimumReleaseAge=$Minutes to $PnpmRcDefault"
  }
}

# ===========================================================================
# bun  --  ~\.bunfig.toml, value in SECONDS, under [install]
# bunfig is TOML-ish; the value must sit inside an [install] section, so we
# can't reuse Upsert-Line. We do a careful in-PowerShell TOML edit.
# ===========================================================================
Hdr 'bun'
$BunRegex = '^\s*minimumReleaseAge\s*='

function Edit-BunFig([string]$Path, [int]$Seconds) {
  $lines = Read-Lines $Path
  if ($null -eq $lines) { $lines = @() }
  $list  = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) { $list.Add($l) | Out-Null }

  $secStart = -1
  $secEnd   = $list.Count
  for ($i = 0; $i -lt $list.Count; $i++) {
    if ($list[$i] -match '^\s*\[install\]\s*$') {
      $secStart = $i
      for ($j = $i + 1; $j -lt $list.Count; $j++) {
        if ($list[$j] -match '^\s*\[.+\]\s*$') { $secEnd = $j; break }
      }
      break
    }
  }

  $newLine = "minimumReleaseAge = $Seconds"
  if ($secStart -lt 0) {
    if ($list.Count -gt 0 -and $list[$list.Count - 1].Trim() -ne '') {
      $list.Add('') | Out-Null
    }
    $list.Add('[install]') | Out-Null
    $list.Add($newLine)    | Out-Null
  } else {
    $replaced = $false
    for ($k = $secStart + 1; $k -lt $secEnd; $k++) {
      if ($list[$k] -match '^\s*minimumReleaseAge\s*=') {
        $list[$k] = $newLine
        $replaced = $true
        break
      }
    }
    if (-not $replaced) {
      # Insert right after the last non-blank line within the section so
      # the new key joins its siblings rather than landing after a blank.
      $insertAt = $secStart + 1
      for ($k = $secEnd - 1; $k -gt $secStart; $k--) {
        if ($list[$k].Trim() -ne '') { $insertAt = $k + 1; break }
      }
      $list.Insert($insertAt, $newLine)
    }
  }
  Write-Lines $Path $list.ToArray()
}

if ($Revert) {
  if (Remove-Line $BunFig $BunRegex) {
    Ok "bun: removed minimumReleaseAge from $BunFig"
  } else {
    Skip "bun: no minimumReleaseAge in $BunFig; nothing to remove"
  }
} elseif (-not (Should-Configure 'bun')) {
  Skip "bun not installed; skipped. Pass -IncludeAbsent to write config anyway"
} else {
  if ($DryRun) {
    if ((Test-Path -LiteralPath $BunFig -PathType Leaf) -and ((Read-Lines $BunFig) -match $BunRegex)) {
      Note "[dry-run] would update minimumReleaseAge in $BunFig to $SecondsTotal"
    } else {
      Note "[dry-run] would add an [install] section with minimumReleaseAge = $SecondsTotal to $BunFig"
    }
  } else {
    if (Test-Path -LiteralPath $BunFig -PathType Leaf) {
      Backup-File $BunFig
    }
    Edit-BunFig $BunFig $SecondsTotal
  }
  if (Have 'bun') {
    Ok "bun: minimumReleaseAge=$SecondsTotal (seconds = ${Days}d) in $BunFig"
  } else {
    Skip "bun not installed; wrote minimumReleaseAge=$SecondsTotal to $BunFig anyway"
  }
}

# ===========================================================================
# yarn (Berry, >=4.10)  --  ~\.yarnrc.yml, duration string
# ===========================================================================
Hdr 'yarn'
$YarnRegex = '^\s*npmMinimalAgeGate:'

# Tight version check: npmMinimalAgeGate lands in Yarn 4.10, not 4.0.
$yarnSupportsGate = $false
$yarnVer = ''
if (Have 'yarn') {
  try { $yarnVer = (& yarn --version 2>$null).Trim() } catch { $yarnVer = '' }
  if ($yarnVer -match '^(\d+)\.(\d+)\.') {
    $yMajor = [int]$Matches[1]
    $yMinor = [int]$Matches[2]
    if ($yMajor -gt 4 -or ($yMajor -eq 4 -and $yMinor -ge 10)) {
      $yarnSupportsGate = $true
    }
  }
}

if ($Revert) {
  if ($yarnSupportsGate) {
    if ($DryRun) {
      Note "[dry-run] would run: yarn config unset -H npmMinimalAgeGate"
    } else {
      try { & yarn config unset -H npmMinimalAgeGate *>$null } catch {}
    }
  }
  if (Remove-Line $YarnRc $YarnRegex) {
    Ok "yarn: removed npmMinimalAgeGate from $YarnRc"
  } else {
    Skip "yarn: no npmMinimalAgeGate in $YarnRc; nothing to remove"
  }
} elseif (-not (Should-Configure 'yarn')) {
  Skip "yarn not installed; skipped. Pass -IncludeAbsent to write config anyway"
} else {
  if ($yarnSupportsGate) {
    if ($DryRun) {
      Note "[dry-run] would run: yarn config set -H npmMinimalAgeGate `"$Duration`""
      Ok "yarn ($yarnVer): would set npmMinimalAgeGate=$Duration"
    } else {
      $applied = $false
      try {
        & yarn config set -H npmMinimalAgeGate $Duration *>$null
        if ($LASTEXITCODE -eq 0) { $applied = $true }
      } catch {}
      if ($applied) {
        Ok "yarn ($yarnVer): npmMinimalAgeGate=$Duration in $YarnRc"
      } else {
        Skip "yarn ($yarnVer) rejected npmMinimalAgeGate -- falling back to direct yarnrc write"
        Upsert-Line $YarnRc $YarnRegex "npmMinimalAgeGate: `"$Duration`""
      }
    }
  } else {
    # Either yarn not installed, or it's classic 1.x / Berry < 4.10. Drop a
    # yml line so a future supporting Berry install picks it up.
    Upsert-Line $YarnRc $YarnRegex "npmMinimalAgeGate: `"$Duration`""
    if (Have 'yarn') {
      Skip "yarn $yarnVer doesn't support npmMinimalAgeGate (need Berry >= 4.10); wrote $YarnRc for future use"
    } else {
      Skip "yarn not installed; wrote npmMinimalAgeGate: `"$Duration`" to $YarnRc"
    }
  }
}

# ===========================================================================
# uv (Python)  --  user uv.toml, duration string
# pip itself has no equivalent setting; use uv (or `uv pip`) for the gate.
# ===========================================================================
Hdr 'uv (Python)'
$UvRegex = '^\s*exclude-newer\s*='
if ($Revert) {
  if (Remove-Line $UvToml $UvRegex) {
    Ok "uv: removed exclude-newer from $UvToml"
  } else {
    Skip "uv: no exclude-newer in $UvToml; nothing to remove"
  }
} elseif (Should-Configure 'uv') {
  Upsert-Line $UvToml $UvRegex "exclude-newer = `"$Duration`""
  if (Have 'uv') {
    Ok "uv: exclude-newer=`"$Duration`" in $UvToml"
  } else {
    Skip "uv not installed; wrote exclude-newer=`"$Duration`" to $UvToml anyway"
  }
} else {
  Skip "uv not installed; skipped. Pass -IncludeAbsent to write config anyway"
}

Hdr 'pip (Python)'
Skip "pip has no native cooldown setting -- use ``uv pip`` (configured above)"
Skip "or pin with hashes / use a mirror that delays publication."

# ===========================================================================
# composer (PHP)  --  global config.json, duration string
# ===========================================================================
Hdr 'composer'
# Composer doesn't read unknown keys gracefully if hand-written, and its
# config.json wants real JSON, so we *must* go through the CLI when present.
if ($Revert) {
  if (Have 'composer') {
    Backup-ComposerConfig
    if ($DryRun) {
      Note "[dry-run] would run: composer global config --unset minimum-release-age.minimum-age"
    } else {
      try { & composer global config --unset minimum-release-age.minimum-age *>$null } catch {}
    }
    Ok "composer: removed minimum-release-age.minimum-age (if it was set)"
  } else {
    Skip "composer not installed; nothing to revert"
  }
} elseif (-not (Should-Configure 'composer')) {
  Skip "composer not installed; skipped. Pass -IncludeAbsent to write config anyway"
} else {
  if (Have 'composer') {
    $composerVer = try {
      ((& composer --version 2>$null) | Select-Object -First 1).Trim()
    } catch { 'composer' }
    Backup-ComposerConfig
    if ($DryRun) {
      Note "[dry-run] would run: composer global config minimum-release-age.minimum-age `"$DurationHuman`""
      Ok "${composerVer}: would set minimum-release-age.minimum-age=`"$DurationHuman`""
    } else {
      $applied = $false
      try {
        & composer global config minimum-release-age.minimum-age $DurationHuman *>$null
        if ($LASTEXITCODE -eq 0) { $applied = $true }
      } catch {}
      if ($applied) {
        Ok "composer: minimum-release-age.minimum-age=`"$DurationHuman`" (global config.json)"
      } else {
        Skip "$composerVer rejected the key -- upgrade to a Composer that supports minimum-release-age"
        Skip "fallback for now: set the COMPOSER_MINIMUM_RELEASE_AGE environment variable to `"$DurationHuman`""
      }
    }
  } else {
    Skip "composer not installed; set COMPOSER_MINIMUM_RELEASE_AGE=`"$DurationHuman`" when you do"
  }
}

# ===========================================================================
# cargo (Rust)  --  no native setting yet (RFC #3923 in progress).
# cargo-cooldown is a third-party tool that uses ~\.cargo\cooldown.toml.
# ===========================================================================
Hdr 'cargo (Rust)'
$CargoRegex = '^\s*cooldown_minutes\s*='
if ($Revert) {
  if (Remove-Line $CargoCooldown $CargoRegex) {
    Ok "cargo: removed cooldown_minutes from $CargoCooldown"
  } else {
    Skip "cargo: no cooldown_minutes in $CargoCooldown; nothing to remove"
  }
} elseif (Should-Configure 'cargo') {
  Upsert-Line $CargoCooldown $CargoRegex "cooldown_minutes = $Minutes"
  if (Have 'cargo') {
    Ok "cargo: cooldown_minutes=$Minutes in $CargoCooldown"
    Skip "requires the third-party ``cargo install cargo-cooldown`` runner until native support lands"
  } else {
    Skip "cargo not installed; wrote cooldown_minutes=$Minutes to $CargoCooldown anyway"
  }
} else {
  Skip "cargo not installed; skipped. Pass -IncludeAbsent to write config anyway"
}

# ---- backup pruning -------------------------------------------------------
if ($KeepBackups -ge 0) {
  Hdr "pruning backups (-KeepBackups $KeepBackups)"
  Prune-Backups
}

# ---- closing message ------------------------------------------------------
if (-not $Quiet) {
  Write-Host ''
  if ($DryRun) {
    Write-Host "Dry-run complete. No files were changed. Re-run without -DryRun to apply."
  } elseif ($Revert) {
    Write-Host "Revert complete. Cooldown keys removed where this script had set them."
  } else {
    Write-Host "All done. Re-run any time to re-apply; use -Revert to undo, -DryRun to preview."
  }
}
