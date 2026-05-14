#!/usr/bin/env bash
#
# set-minimum-release-age.sh
#
# Configures global "minimum release age" / "cooldown" settings across common
# package managers so that newly published versions are ignored for N days
# (default 7). This is one of the cheapest, highest-leverage defences against
# the recent wave of supply-chain attacks in the JS / PHP / Python / Rust
# ecosystems: malicious releases are usually identified and yanked within
# hours, so a 7-day cooldown means you almost never install a known-bad
# version.
#
# Each ecosystem expresses the duration differently:
#
#   npm       min-release-age            DAYS               (npm >= 11.10.0)
#   pnpm      minimumReleaseAge          MINUTES            (pnpm >= 10.16)
#   bun       minimumReleaseAge          SECONDS            (bunfig.toml)
#   yarn      npmMinimalAgeGate          DURATION STRING    (yarn >= 4.10)
#   uv        exclude-newer              DURATION STRING    (uv.toml)
#   composer  minimum-release-age        DURATION STRING    (composer 2.9+)
#   cargo     cooldown_minutes           MINUTES            (cargo-cooldown, 3rd-party)
#
# The script is idempotent: re-running it just rewrites the same values.
#
# Usage:
#   set-minimum-release-age.sh [--days=N] [--dry-run] [--revert]
#                              [--include-absent] [--no-backup]
#                              [--keep-backups=N] [--yes] [--quiet] [--help]
#
# By default, only ecosystems whose package manager is installed are
# configured — we don't litter the home dir with configs for tools you
# don't use. Pass --include-absent to write configs for absent tools too
# (useful if you plan to install them later and want them pre-protected).

# Best-effort across many package managers: a failure in one (e.g. an older
# npm that doesn't know the option yet) must not stop the others from being
# configured. So we deliberately do NOT `set -e`.
set -uo pipefail

# ---- defaults & argument parsing -----------------------------------------
DAYS=7
DRY_RUN=0
REVERT=0
NO_BACKUP=0
ASSUME_YES=0
QUIET=0
INCLUDE_ABSENT=0
KEEP_BACKUPS=-1   # -1 means unlimited (keep all)

usage() {
  cat <<EOF
Usage: $0 [options]

Configures a "minimum release age" cooldown across npm, pnpm, bun, yarn,
uv (Python), composer (PHP), and cargo (Rust, via cargo-cooldown).

Options:
  --days=N         Cooldown length in days (default: 7).
  --dry-run        Show what would change without writing anything.
  --revert         Remove the settings this script previously wrote.
  --include-absent Also write configs for ecosystems whose package manager
                   is NOT installed, so they're protected once installed.
                   Default is to skip absent tools and not litter your
                   home directory with configs for things you don't use.
  --no-backup      Don't create .bak.<timestamp> copies before editing.
  --keep-backups=N Keep only the N most recent .bak.<timestamp> files per
                   managed config (default: keep all). Pruning runs at the
                   end of an apply or revert.
  -y, --yes        Skip the confirmation prompt. Required when stdin is
                   not a terminal (e.g. piping into bash).
  --quiet          Suppress informational output (errors still printed).
  -h, --help       Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --days=*)     DAYS="${1#--days=}" ;;
    --days)       shift; DAYS="${1:-}" ;;
    --dry-run)    DRY_RUN=1 ;;
    --revert)     REVERT=1 ;;
    --include-absent) INCLUDE_ABSENT=1 ;;
    --no-backup)  NO_BACKUP=1 ;;
    --keep-backups=*) KEEP_BACKUPS="${1#--keep-backups=}" ;;
    --keep-backups)   shift; KEEP_BACKUPS="${1:-}" ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --quiet)      QUIET=1 ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; break ;;
    *)
      printf "unknown option: %s\n" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  printf -- "--days must be a non-negative integer (got: %s)\n" "$DAYS" >&2
  exit 2
fi
if ! [[ "$KEEP_BACKUPS" =~ ^-?[0-9]+$ ]]; then
  printf -- "--keep-backups must be an integer (got: %s)\n" "$KEEP_BACKUPS" >&2
  exit 2
fi

# ---- N days expressed in every flavour -----------------------------------
MINUTES=$((DAYS * 24 * 60))          # 10080 when DAYS=7
SECONDS_7D=$((DAYS * 24 * 60 * 60))  # 604800 when DAYS=7
DURATION="${DAYS}d"                  # "7d"
DURATION_HUMAN="${DAYS} days"        # "7 days"
TS="$(date +%Y%m%d-%H%M%S)"

# ---- pretty output --------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_SKIP=$'\033[33m'; C_INFO=$'\033[36m'; C_WARN=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_SKIP=''; C_INFO=''; C_WARN=''; C_OFF=''
fi
ok()   { [ "$QUIET" -eq 1 ] && return 0; printf "  %s✓%s %s\n"   "$C_OK"   "$C_OFF" "$*"; }
skip() { [ "$QUIET" -eq 1 ] && return 0; printf "  %s·%s %s\n"   "$C_SKIP" "$C_OFF" "$*"; }
note() { [ "$QUIET" -eq 1 ] && return 0; printf "  %s…%s %s\n"   "$C_INFO" "$C_OFF" "$*"; }
warn() {                                  printf "  %s!%s %s\n"  "$C_WARN" "$C_OFF" "$*" >&2; }
hdr()  { [ "$QUIET" -eq 1 ] && return 0; printf "\n%s==>%s %s\n" "$C_INFO" "$C_OFF" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Should we touch the given ecosystem this run? Always yes on revert (we may
# need to clean up after a tool that's since been uninstalled). On apply,
# yes if the tool is installed OR --include-absent was passed.
should_configure() {
  local tool="$1"
  [ "$REVERT" -eq 1 ] && return 0
  [ "$INCLUDE_ABSENT" -eq 1 ] && return 0
  have "$tool"
}

# OS-aware config dirs (matters for pnpm + uv on macOS)
case "$(uname -s)" in
  Darwin)
    UV_CONFIG_DIR_DEFAULT="$HOME/Library/Application Support/uv"
    PNPM_RC_DEFAULT="$HOME/Library/Preferences/pnpm/rc"
    ;;
  *)
    UV_CONFIG_DIR_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/uv"
    PNPM_RC_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/pnpm/rc"
    ;;
esac

# Files that have already been backed up this run, so we only ever create
# one timestamped backup per file even if it's touched in multiple sections.
BACKED_UP_FILES=" "

# Copy a file to <path>.bak.<TS> before we mutate it. No-op for non-existent
# files, dry-runs, --no-backup, or files we've already backed up this run.
backup_file() {
  local f="$1"
  [ "$NO_BACKUP" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -f "$f" ] || return 0
  case "$BACKED_UP_FILES" in
    *" $f "*) return 0 ;;
  esac
  if cp -p -- "$f" "$f.bak.$TS" 2>/dev/null; then
    BACKED_UP_FILES="$BACKED_UP_FILES$f "
    note "backed up $f → $f.bak.$TS"
  else
    warn "could not back up $f — continuing without backup"
  fi
}

# Replace a single `key = value` line in a flat config file, or append it.
# Works for npmrc-style (key=value) and yarnrc.yml-style (key: value) by
# letting the caller pass the literal replacement line.
# Usage: upsert_line <file> <match_regex> <replacement_line>
upsert_line() {
  local file="$1" regex="$2" line="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$file" ] && grep -qE "$regex" "$file"; then
      note "[dry-run] would replace matching line in $file with: $line"
    else
      note "[dry-run] would append to $file: $line"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ]; then
    touch "$file"
  else
    backup_file "$file"
  fi
  if grep -qE "$regex" "$file"; then
    awk -v re="$regex" -v repl="$line" '
      $0 ~ re { print repl; next }
      { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    if [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l)" -eq 0 ]; then
      printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
  fi
}

# Files that this script may create, edit, or back up. Used by the
# end-of-run --keep-backups pruner. Composer's config.json is appended
# later, once we've asked composer where its global home lives.
MANAGED_FILES=(
  "$HOME/.npmrc"
  "$PNPM_RC_DEFAULT"
  "$HOME/.bunfig.toml"
  "$HOME/.yarnrc.yml"
  "$UV_CONFIG_DIR_DEFAULT/uv.toml"
  "$HOME/.cargo/cooldown.toml"
)

# Delete all but the N most recent .bak.<TS> files for each managed config.
# Honours --dry-run. No-op when KEEP_BACKUPS is negative (the default).
#
# We sort by the YYYYMMDD-HHMMSS suffix in the filename rather than by file
# mtime: `cp -p` preserves the source's mtime, so if a config was never
# actually modified between runs (e.g. composer rejecting the key), every
# backup inherits the same mtime and `ls -t` falls back to alphabetical
# which inverts the intended order. Filename suffixes are guaranteed unique
# per run, and YYYYMMDD-HHMMSS sorts lexicographically == chronologically.
prune_backups() {
  [ "$KEEP_BACKUPS" -lt 0 ] && return 0
  local f dir base count bak
  local -a files
  # Enable nullglob so empty matches expand to nothing rather than the
  # literal pattern. Save & restore so we don't surprise callers.
  local nullglob_was_set=0
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  for f in "${MANAGED_FILES[@]}"; do
    dir=$(dirname "$f")
    base=$(basename "$f")
    [ -d "$dir" ] || continue
    files=( "$dir"/"$base".bak.* )
    [ "${#files[@]}" -eq 0 ] && continue
    count=0
    while IFS= read -r bak; do
      [ -z "$bak" ] && continue
      count=$((count + 1))
      if [ "$count" -gt "$KEEP_BACKUPS" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
          note "[dry-run] would prune old backup: $bak"
        else
          rm -f -- "$bak" && note "pruned old backup: $bak"
        fi
      fi
    done < <(printf '%s\n' "${files[@]}" | sort -r)
  done
  [ "$nullglob_was_set" -eq 0 ] && shopt -u nullglob
}

# Ask composer where its global config dir lives and back up config.json
# before the CLI mutates it. Also adds the path to MANAGED_FILES so
# --keep-backups picks it up.
backup_composer_config() {
  have composer || return 0
  local cc_home cc_config
  cc_home=$(composer config --global home 2>/dev/null | tr -d '\r' || echo "")
  [ -n "$cc_home" ] || return 0
  cc_config="$cc_home/config.json"
  MANAGED_FILES+=("$cc_config")
  backup_file "$cc_config"
}

# Remove every line matching <regex> from <file>. Used by --revert.
# Returns 0 if a matching line was found (and removed, or would be in
# dry-run mode), 1 if there was nothing to do. Lets callers print accurate
# "removed" vs "nothing to remove" messages.
# Usage: remove_line <file> <match_regex>
remove_line() {
  local file="$1" regex="$2"
  [ -f "$file" ] || return 1
  grep -qE "$regex" "$file" || return 1
  if [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] would remove lines matching '$regex' from $file"
    return 0
  fi
  backup_file "$file"
  awk -v re="$regex" '$0 !~ re { print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  return 0
}

# ---- preamble & confirmation ---------------------------------------------
if [ "$REVERT" -eq 1 ]; then
  ACTION_LABEL="REVERT (remove) the"
elif [ "$DRY_RUN" -eq 1 ]; then
  ACTION_LABEL="PREVIEW a"
else
  ACTION_LABEL="APPLY a"
fi

if [ "$QUIET" -eq 0 ]; then
  cat <<EOF

This script will ${ACTION_LABEL} ${DAYS}-day "minimum release age" cooldown across:
  npm, pnpm, bun, yarn, uv (Python), composer (PHP), and cargo (via cargo-cooldown).

What this means in practice:
  • Installs will refuse versions younger than ${DAYS} days from upstream.
  • Lockfile updates and CI matrices that resolve "latest" may pick older versions.
  • For genuine hot-fixes you may need a per-project override (e.g. npm's
    --ignore-min-release-age, or temporarily setting the value to 0).
  • This is ONE defensive layer. Typosquats, long-lived compromises, and
    already-locked transitive dependencies are NOT mitigated by a cooldown.

Files that may be created or edited:
  ~/.npmrc
  ${PNPM_RC_DEFAULT}
  ~/.bunfig.toml
  ~/.yarnrc.yml
  ${UV_CONFIG_DIR_DEFAULT}/uv.toml
  Composer global config.json (via \`composer global config\`)
  ~/.cargo/cooldown.toml

EOF
  if [ "$REVERT" -eq 0 ]; then
    if [ "$INCLUDE_ABSENT" -eq 1 ]; then
      printf "%s--include-absent:%s configs will be written for ecosystems even if their package manager isn't installed.\n" "$C_INFO" "$C_OFF"
    else
      printf "%sNote:%s ecosystems whose package manager isn't installed will be skipped. Pass --include-absent to write their configs anyway.\n" "$C_INFO" "$C_OFF"
    fi
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 0 ]; then
    printf "Existing files will be copied to '<path>.bak.%s' before being edited.\n\n" "$TS"
  elif [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 1 ]; then
    printf "%s--no-backup is set: existing files will be edited in place.%s\n\n" "$C_WARN" "$C_OFF"
  fi
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  if [ -t 0 ]; then
    printf "Proceed? [y/N] "
    read -r REPLY || REPLY=""
    case "$REPLY" in
      [yY]|[yY][eE][sS]) ;;
      *) printf "Aborted.\n"; exit 1 ;;
    esac
  else
    # Non-interactive (piped) and no --yes: refuse to proceed silently.
    # This is a security script; we don't want curl|bash to apply changes
    # without the user explicitly opting in.
    printf "%sRefusing to proceed: stdin is not a terminal and --yes was not given.%s\n" "$C_WARN" "$C_OFF" >&2
    printf "Re-run with --yes to confirm, or --dry-run to preview without writing.\n" >&2
    exit 1
  fi
fi

# ===========================================================================
# npm  --  ~/.npmrc, value in DAYS
# ===========================================================================
hdr "npm"
NPMRC="$HOME/.npmrc"
NPM_REGEX="^[[:space:]]*min-release-age[[:space:]]*="
# npm < 11.10.0 rejects unknown keys via `npm config set`, so we always write
# the rc file directly. npm reads unknown keys from .npmrc without error,
# which means the setting starts working the moment npm is upgraded.
if [ "$REVERT" -eq 1 ]; then
  if remove_line "$NPMRC" "$NPM_REGEX"; then
    ok "npm: removed min-release-age from $NPMRC"
  else
    skip "npm: no min-release-age in $NPMRC; nothing to remove"
  fi
elif should_configure npm; then
  upsert_line "$NPMRC" "$NPM_REGEX" "min-release-age=${DAYS}"
  if have npm; then
    npm_ver=$(npm --version 2>/dev/null || echo "?")
    ok "npm (${npm_ver}): min-release-age=${DAYS} (days) in $NPMRC — active from npm 11.10.0"
  else
    skip "npm not installed; wrote min-release-age=${DAYS} to $NPMRC for later"
  fi
else
  skip "npm not installed; skipped. Pass --include-absent to write config anyway"
fi

# ===========================================================================
# pnpm  --  global rc, value in MINUTES
# ===========================================================================
hdr "pnpm"
PNPM_REGEX="^[[:space:]]*minimumReleaseAge[[:space:]]*="
# Prefer `pnpm config set -g` when available — pnpm knows where its own rc
# file lives on this machine, which may differ from PNPM_RC_DEFAULT. Always
# also touch the known rc path as a belt-and-braces fallback for environments
# where the CLI rejects the key.
if [ "$REVERT" -eq 1 ]; then
  if have pnpm && [ "$DRY_RUN" -eq 0 ]; then
    pnpm config delete -g minimumReleaseAge >/dev/null 2>&1 || true
  elif have pnpm && [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] would run: pnpm config delete -g minimumReleaseAge"
  fi
  if remove_line "$PNPM_RC_DEFAULT" "$PNPM_REGEX"; then
    ok "pnpm: removed minimumReleaseAge from $PNPM_RC_DEFAULT"
  else
    skip "pnpm: no minimumReleaseAge in $PNPM_RC_DEFAULT; nothing to remove (CLI unset already attempted)"
  fi
elif ! should_configure pnpm; then
  skip "pnpm not installed; skipped. Pass --include-absent to write config anyway"
else
  applied_via_cli=0
  if have pnpm; then
    if [ "$DRY_RUN" -eq 1 ]; then
      note "[dry-run] would run: pnpm config set -g minimumReleaseAge ${MINUTES}"
      applied_via_cli=1
    elif pnpm config set -g minimumReleaseAge "$MINUTES" >/dev/null 2>&1; then
      applied_via_cli=1
    fi
  fi
  upsert_line "$PNPM_RC_DEFAULT" "$PNPM_REGEX" "minimumReleaseAge=${MINUTES}"
  if have pnpm; then
    pnpm_ver=$(pnpm --version 2>/dev/null || echo "?")
    if [ "$applied_via_cli" -eq 1 ]; then
      ok "pnpm (${pnpm_ver}): minimumReleaseAge=${MINUTES} (minutes = ${DAYS}d) via \`pnpm config set\` + $PNPM_RC_DEFAULT"
    else
      ok "pnpm (${pnpm_ver}): minimumReleaseAge=${MINUTES} written to $PNPM_RC_DEFAULT (CLI rejected the key)"
    fi
  else
    skip "pnpm not installed; wrote minimumReleaseAge=${MINUTES} to $PNPM_RC_DEFAULT"
  fi
fi

# ===========================================================================
# bun  --  ~/.bunfig.toml, value in SECONDS, under [install]
# bunfig is TOML-ish; the value must sit inside an [install] section, so we
# can't reuse upsert_line. Prefer python3 for safety; fall back to a careful
# awk path.
# ===========================================================================
hdr "bun"
BUNFIG="$HOME/.bunfig.toml"
BUN_REGEX="^[[:space:]]*minimumReleaseAge[[:space:]]*="

if [ "$REVERT" -eq 1 ]; then
  if remove_line "$BUNFIG" "$BUN_REGEX"; then
    ok "bun: removed minimumReleaseAge from $BUNFIG"
  else
    skip "bun: no minimumReleaseAge in $BUNFIG; nothing to remove"
  fi
elif ! should_configure bun; then
  skip "bun not installed; skipped. Pass --include-absent to write config anyway"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$BUNFIG" ] && grep -qE "$BUN_REGEX" "$BUNFIG"; then
      note "[dry-run] would update minimumReleaseAge in $BUNFIG to ${SECONDS_7D}"
    else
      note "[dry-run] would add an [install] section with minimumReleaseAge = ${SECONDS_7D} to $BUNFIG"
    fi
  else
    mkdir -p "$(dirname "$BUNFIG")"
    if [ -f "$BUNFIG" ]; then
      backup_file "$BUNFIG"
    else
      touch "$BUNFIG"
    fi

    if have python3; then
      python3 - "$BUNFIG" "$SECONDS_7D" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
val  = sys.argv[2]
text = path.read_text() if path.exists() else ""
lines = text.splitlines()

# Find [install] section bounds.
sec_start = None
sec_end   = len(lines)
for i, ln in enumerate(lines):
    if re.match(r'^\s*\[install\]\s*$', ln):
        sec_start = i
        for j in range(i + 1, len(lines)):
            if re.match(r'^\s*\[.+\]\s*$', lines[j]):
                sec_end = j
                break
        break

new_line = f"minimumReleaseAge = {val}"
if sec_start is None:
    if lines and lines[-1].strip() != "":
        lines.append("")
    lines += ["[install]", new_line]
else:
    replaced = False
    for k in range(sec_start + 1, sec_end):
        if re.match(r'^\s*minimumReleaseAge\s*=', lines[k]):
            lines[k] = new_line
            replaced = True
            break
    if not replaced:
        # Insert right after the last non-blank line within the section so
        # the new key joins its siblings rather than landing after a blank.
        insert_at = sec_start + 1
        for k in range(sec_end - 1, sec_start, -1):
            if lines[k].strip() != "":
                insert_at = k + 1
                break
        lines.insert(insert_at, new_line)

path.write_text("\n".join(lines).rstrip() + "\n")
PY
    else
      # Fallback without python3.
      if grep -qE '^\[install\]' "$BUNFIG"; then
        if grep -qE "$BUN_REGEX" "$BUNFIG"; then
          awk -v v="$SECONDS_7D" '
            /^[[:space:]]*minimumReleaseAge[[:space:]]*=/ { print "minimumReleaseAge = " v; next }
            { print }
          ' "$BUNFIG" > "$BUNFIG.tmp" && mv "$BUNFIG.tmp" "$BUNFIG"
        else
          # Insert under the existing [install] header.
          awk -v v="$SECONDS_7D" '
            { print }
            /^\[install\][[:space:]]*$/ && !done { print "minimumReleaseAge = " v; done=1 }
          ' "$BUNFIG" > "$BUNFIG.tmp" && mv "$BUNFIG.tmp" "$BUNFIG"
        fi
      else
        [ -s "$BUNFIG" ] && printf '\n' >> "$BUNFIG"
        printf '[install]\nminimumReleaseAge = %s\n' "$SECONDS_7D" >> "$BUNFIG"
      fi
    fi
  fi

  if have bun; then
    ok "bun: minimumReleaseAge=${SECONDS_7D} (seconds = ${DAYS}d) in $BUNFIG"
  else
    skip "bun not installed; wrote minimumReleaseAge=${SECONDS_7D} to $BUNFIG anyway"
  fi
fi

# ===========================================================================
# yarn (Berry, >=4.10)  --  ~/.yarnrc.yml, duration string
# ===========================================================================
hdr "yarn"
YARNRC="$HOME/.yarnrc.yml"
YARN_REGEX="^[[:space:]]*npmMinimalAgeGate:"

# Tight version check: npmMinimalAgeGate lands in Yarn 4.10, not 4.0.
yarn_supports_gate=0
yarn_ver=""
if have yarn; then
  yarn_ver=$(yarn --version 2>/dev/null || echo "")
  if [[ "$yarn_ver" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
    y_major="${BASH_REMATCH[1]}"
    y_minor="${BASH_REMATCH[2]}"
    if [ "$y_major" -gt 4 ] || { [ "$y_major" -eq 4 ] && [ "$y_minor" -ge 10 ]; }; then
      yarn_supports_gate=1
    fi
  fi
fi

if [ "$REVERT" -eq 1 ]; then
  if [ "$yarn_supports_gate" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    yarn config unset -H npmMinimalAgeGate >/dev/null 2>&1 || true
  elif [ "$yarn_supports_gate" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] would run: yarn config unset -H npmMinimalAgeGate"
  fi
  if remove_line "$YARNRC" "$YARN_REGEX"; then
    ok "yarn: removed npmMinimalAgeGate from $YARNRC"
  else
    skip "yarn: no npmMinimalAgeGate in $YARNRC; nothing to remove"
  fi
elif ! should_configure yarn; then
  skip "yarn not installed; skipped. Pass --include-absent to write config anyway"
else
  if [ "$yarn_supports_gate" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      note "[dry-run] would run: yarn config set -H npmMinimalAgeGate \"$DURATION\""
      ok "yarn (${yarn_ver}): would set npmMinimalAgeGate=${DURATION}"
    elif yarn config set -H npmMinimalAgeGate "$DURATION" >/dev/null 2>&1; then
      ok "yarn (${yarn_ver}): npmMinimalAgeGate=${DURATION} in $YARNRC"
    else
      skip "yarn (${yarn_ver}) rejected npmMinimalAgeGate — falling back to direct yarnrc write"
      upsert_line "$YARNRC" "$YARN_REGEX" "npmMinimalAgeGate: \"${DURATION}\""
    fi
  else
    # Either yarn not installed, or it's classic 1.x / Berry < 4.10. Drop a
    # yml line so a future supporting Berry install picks it up.
    upsert_line "$YARNRC" "$YARN_REGEX" "npmMinimalAgeGate: \"${DURATION}\""
    if have yarn; then
      skip "yarn ${yarn_ver} doesn't support npmMinimalAgeGate (need Berry >= 4.10); wrote $YARNRC for future use"
    else
      skip "yarn not installed; wrote npmMinimalAgeGate: \"${DURATION}\" to $YARNRC"
    fi
  fi
fi

# ===========================================================================
# uv (Python)  --  user uv.toml, duration string
# pip itself has no equivalent setting; use uv (or `uv pip`) for the gate.
# ===========================================================================
hdr "uv (Python)"
UV_TOML="$UV_CONFIG_DIR_DEFAULT/uv.toml"
UV_REGEX="^[[:space:]]*exclude-newer[[:space:]]*="
if [ "$REVERT" -eq 1 ]; then
  if remove_line "$UV_TOML" "$UV_REGEX"; then
    ok "uv: removed exclude-newer from $UV_TOML"
  else
    skip "uv: no exclude-newer in $UV_TOML; nothing to remove"
  fi
elif should_configure uv; then
  upsert_line "$UV_TOML" "$UV_REGEX" "exclude-newer = \"${DURATION}\""
  if have uv; then
    ok "uv: exclude-newer=\"${DURATION}\" in $UV_TOML"
  else
    skip "uv not installed; wrote exclude-newer=\"${DURATION}\" to $UV_TOML anyway"
  fi
else
  skip "uv not installed; skipped. Pass --include-absent to write config anyway"
fi

hdr "pip (Python)"
skip "pip has no native cooldown setting — use \`uv pip\` (configured above)"
skip "or pin with hashes / use a mirror that delays publication."

# ===========================================================================
# composer (PHP)  --  global config.json, duration string
# ===========================================================================
hdr "composer"
# Composer doesn't read unknown keys gracefully if hand-written, and its
# config.json wants real JSON, so we *must* go through the CLI when present.
if [ "$REVERT" -eq 1 ]; then
  if have composer; then
    backup_composer_config
    if [ "$DRY_RUN" -eq 1 ]; then
      note "[dry-run] would run: composer global config --unset minimum-release-age.minimum-age"
    else
      composer global config --unset minimum-release-age.minimum-age >/dev/null 2>&1 || true
    fi
    ok "composer: removed minimum-release-age.minimum-age (if it was set)"
  else
    skip "composer not installed; nothing to revert"
  fi
elif ! should_configure composer; then
  skip "composer not installed; skipped. Pass --include-absent to write config anyway"
else
  if have composer; then
    composer_ver=$(composer --version 2>/dev/null | head -n1 || echo "composer")
    # Back up composer's global config.json before the CLI mutates it, so
    # there's something to roll back to if anything goes wrong.
    backup_composer_config
    if [ "$DRY_RUN" -eq 1 ]; then
      note "[dry-run] would run: composer global config minimum-release-age.minimum-age \"$DURATION_HUMAN\""
      ok "${composer_ver}: would set minimum-release-age.minimum-age=\"${DURATION_HUMAN}\""
    elif composer global config minimum-release-age.minimum-age "$DURATION_HUMAN" >/dev/null 2>&1; then
      ok "composer: minimum-release-age.minimum-age=\"${DURATION_HUMAN}\" (global config.json)"
    else
      skip "${composer_ver} rejected the key — upgrade to a Composer that supports minimum-release-age"
      skip "fallback for now: export COMPOSER_MINIMUM_RELEASE_AGE=\"${DURATION_HUMAN}\" in your shell rc"
    fi
  else
    skip "composer not installed; set COMPOSER_MINIMUM_RELEASE_AGE=\"${DURATION_HUMAN}\" when you do"
  fi
fi

# ===========================================================================
# cargo (Rust)  --  no native setting yet (RFC #3923 in progress).
# cargo-cooldown is a third-party tool that uses ~/.cargo/cooldown.toml.
# ===========================================================================
hdr "cargo (Rust)"
CARGO_COOLDOWN="$HOME/.cargo/cooldown.toml"
CARGO_REGEX="^[[:space:]]*cooldown_minutes[[:space:]]*="
if [ "$REVERT" -eq 1 ]; then
  if remove_line "$CARGO_COOLDOWN" "$CARGO_REGEX"; then
    ok "cargo: removed cooldown_minutes from $CARGO_COOLDOWN"
  else
    skip "cargo: no cooldown_minutes in $CARGO_COOLDOWN; nothing to remove"
  fi
elif should_configure cargo; then
  upsert_line "$CARGO_COOLDOWN" "$CARGO_REGEX" "cooldown_minutes = ${MINUTES}"
  if have cargo; then
    ok "cargo: cooldown_minutes=${MINUTES} in $CARGO_COOLDOWN"
    skip "requires the third-party \`cargo install cargo-cooldown\` runner until native support lands"
  else
    skip "cargo not installed; wrote cooldown_minutes=${MINUTES} to $CARGO_COOLDOWN anyway"
  fi
else
  skip "cargo not installed; skipped. Pass --include-absent to write config anyway"
fi

# ---- backup pruning -------------------------------------------------------
if [ "$KEEP_BACKUPS" -ge 0 ]; then
  hdr "pruning backups (--keep-backups=$KEEP_BACKUPS)"
  prune_backups
fi

# ---- closing message ------------------------------------------------------
if [ "$QUIET" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "\n%sDry-run complete.%s No files were changed. Re-run without --dry-run to apply.\n" "$C_INFO" "$C_OFF"
  elif [ "$REVERT" -eq 1 ]; then
    printf "\n%sRevert complete.%s Cooldown keys removed where this script had set them.\n" "$C_OK" "$C_OFF"
  else
    printf "\n%sAll done.%s Re-run any time to re-apply; use --revert to undo, --dry-run to preview.\n" "$C_OK" "$C_OFF"
  fi
fi
