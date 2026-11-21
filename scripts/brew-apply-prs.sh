#!/bin/bash
# brew-apply-prs.sh — apply open oMLX pull requests to a Homebrew oMLX install.
#
# Downloads each PR's diff from GitHub, keeps only the runtime files (omlx/*,
# not tests or docs) and applies them to Homebrew's site-packages. Every change
# is checked first and backed up, so it can be reverted.
#
# Usage:
#   brew-apply-prs.sh 5437 5455        # apply these PRs (stop the server first)
#   brew-apply-prs.sh --check 5437     # only check that they apply; change nothing
#   brew-apply-prs.sh --status         # what is applied, and whether an upgrade wiped it
#   brew-apply-prs.sh --revert         # restore the backed-up files
#
# Options: --repo OWNER/NAME (default jundot/omlx). Set GITHUB_TOKEN to avoid the
# GitHub API rate limit (60 requests/hour without it).
#
# Stacked PRs: a PR whose commits are all contained in another listed PR is
# skipped, because the other PR's diff already includes it.
#
# `brew upgrade omlx` and `brew reinstall omlx` replace the patched files.
# Run --status after either; rerun this script to patch the new version.
# `brew pin omlx` keeps upgrades under your control.

set -euo pipefail

REPO="jundot/omlx"
MODE="apply"
PRS=()

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs OWNER/NAME}"; shift 2 ;;
        --check) MODE="check"; shift ;;
        --status) MODE="status"; shift ;;
        --revert) MODE="revert"; shift ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        [0-9]*) PRS+=("$1"); shift ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

command -v brew >/dev/null || die "Homebrew not found"
command -v git >/dev/null || die "git not found (install the Xcode Command Line Tools)"
command -v curl >/dev/null || die "curl not found"

PREFIX="$(brew --prefix omlx 2>/dev/null)" || die "oMLX is not installed with Homebrew"
LIBEXEC="$(cd "$PREFIX/libexec" 2>/dev/null && pwd -P)" || die "no libexec in $PREFIX"
PY="$LIBEXEC/bin/python3"
SITE="$(echo "$LIBEXEC"/lib/python3.*/site-packages)"
[ -d "$SITE/omlx" ] || die "omlx package not found under $LIBEXEC"
VERSION="$("$PY" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from omlx._version import __version__; print(__version__)' "$SITE")"

# Per-install state lives inside the Cellar, so an upgrade or reinstall removes it
# together with the patched files. The user-level record survives, so --status can
# tell when an upgrade wiped the patches.
STATE="$LIBEXEC/.omlx-prs"
RECORD="${XDG_CONFIG_HOME:-$HOME/.config}/omlx-prs/last-applied"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/omlx-prs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

api() {
    local auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/$1"
}

json() {  # json FILE EXPR — evaluate EXPR with `d` bound to the parsed file
    "$PY" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

status() {
    echo "oMLX $VERSION (Homebrew) at $SITE"
    if [ -f "$STATE/applied" ]; then
        echo "Applied: $(cat "$STATE/applied")"
        echo "         on $(cat "$STATE/version"), $(cat "$STATE/date")"
    else
        echo "Applied: none"
        if [ -f "$RECORD" ]; then
            echo "Last applied: $(sed -n 1p "$RECORD") on oMLX $(sed -n 2p "$RECORD")"
            echo "warning: this install is unpatched. An upgrade or reinstall probably replaced the files."
            echo "         Rerun: $0 $(sed -n 1p "$RECORD")"
        fi
    fi
    if pgrep -f 'omlx(\.cli)? serve|bin/omlx serve' >/dev/null 2>&1; then
        echo "note: an oMLX server is running; restart it to load changed files."
    fi
}

revert() {
    [ -f "$STATE/applied" ] || die "nothing to revert: no PRs recorded for this install"
    while IFS= read -r rel; do
        if [ -f "$STATE/backup/$rel" ]; then
            cp -p "$STATE/backup/$rel" "$SITE/$rel"
        else
            rm -f "$SITE/$rel"   # the PR added this file
        fi
    done < "$STATE/files"
    find "$SITE/omlx" -name __pycache__ -type d -prune -exec rm -rf {} +
    # Remove folders that only held files the PRs added.
    while IFS= read -r rel; do
        dir="$(dirname "$rel")"
        while [ "$dir" != "omlx" ] && [ "$dir" != "." ] && rmdir "$SITE/$dir" 2>/dev/null; do
            dir="$(dirname "$dir")"
        done
    done < "$STATE/files"
    echo "Reverted PRs $(cat "$STATE/applied") on oMLX $VERSION."
    rm -rf "$STATE"
    rm -f "$RECORD"
}

case "$MODE" in
    status) status; exit 0 ;;
    revert) revert; exit 0 ;;
esac

[ ${#PRS[@]} -gt 0 ] || die "no PR numbers given (see --help)"
if [ "$MODE" = "apply" ] && [ -f "$STATE/applied" ]; then
    die "PRs $(cat "$STATE/applied") are already applied; run --revert first"
fi

# Fetch metadata, commits and diffs.
echo "oMLX $VERSION (Homebrew), repo $REPO"
for pr in "${PRS[@]}"; do
    api "pulls/$pr" > "$TMP/$pr.json" || die "PR #$pr not found in $REPO"
    api "pulls/$pr/commits?per_page=100" > "$TMP/$pr.commits.json"
    json "$TMP/$pr.commits.json" '"\n".join(c["sha"] for c in d)' > "$TMP/$pr.shas"
    curl -fsSL "https://github.com/$REPO/pull/$pr.diff" -o "$TMP/$pr.diff" || die "cannot download the diff of PR #$pr"
    state="$(json "$TMP/$pr.json" '"merged" if d.get("merged") else d["state"] + (" draft" if d.get("draft") else "")')"
    title="$(json "$TMP/$pr.json" 'd["title"]')"
    echo "  #$pr [$state] $title"
done

# Drop PRs contained in another listed PR (stacked branches).
SELECTED=()
for pr in "${PRS[@]}"; do
    inner=""
    for other in "${PRS[@]}"; do
        [ "$other" = "$pr" ] && continue
        if [ -z "$(comm -23 <(sort "$TMP/$pr.shas") <(sort "$TMP/$other.shas"))" ] \
           && [ "$(wc -l < "$TMP/$other.shas")" -gt "$(wc -l < "$TMP/$pr.shas")" ]; then
            inner="$other"; break
        fi
    done
    if [ -n "$inner" ]; then
        echo "  skip #$pr: its commits are part of #$inner"
    else
        SELECTED+=("$pr")
    fi
done

# Check each diff, in order, against a scratch copy of the package.
mkdir -p "$TMP/tree"
cp -R "$SITE/omlx" "$TMP/tree/omlx"
find "$TMP/tree" -name __pycache__ -type d -prune -exec rm -rf {} +
TO_APPLY=()
for pr in ${SELECTED[@]+"${SELECTED[@]}"}; do
    if (cd "$TMP/tree" && git apply --check --include='omlx/*' "$TMP/$pr.diff" 2>"$TMP/$pr.err"); then
        (cd "$TMP/tree" && git apply --include='omlx/*' "$TMP/$pr.diff")
        TO_APPLY+=("$pr")
        echo "  ok   #$pr applies"
    elif (cd "$TMP/tree" && git apply -R --check --include='omlx/*' "$TMP/$pr.diff" 2>/dev/null); then
        echo "  skip #$pr: already in oMLX $VERSION"
    else
        echo "  FAIL #$pr does not apply to oMLX $VERSION:" >&2
        sed 's/^/       /' "$TMP/$pr.err" >&2
        die "nothing was changed. The PR needs a rebase onto this release."
    fi
done

[ ${#TO_APPLY[@]} -gt 0 ] || { echo "Nothing to apply."; exit 0; }
if [ "$MODE" = "check" ]; then
    echo "Check passed; nothing was changed. Apply with: $0 ${TO_APPLY[*]}"
    exit 0
fi

# Back up every file the diffs touch, then install the checked tree's versions.
mkdir -p "$STATE/backup"
for pr in "${TO_APPLY[@]}"; do
    grep -E '^\+\+\+ b/omlx/' "$TMP/$pr.diff" | sed 's|^+++ b/||'
    grep -E '^--- a/omlx/' "$TMP/$pr.diff" | sed 's|^--- a/||'
done | sort -u > "$STATE/files"
while IFS= read -r rel; do
    if [ -f "$SITE/$rel" ]; then
        mkdir -p "$STATE/backup/$(dirname "$rel")"
        cp -p "$SITE/$rel" "$STATE/backup/$rel"
    fi
done < "$STATE/files"
while IFS= read -r rel; do
    if [ -f "$TMP/tree/$rel" ]; then
        mkdir -p "$SITE/$(dirname "$rel")"
        cp "$TMP/tree/$rel" "$SITE/$rel"
    else
        rm -f "$SITE/$rel"   # the PR deleted this file
    fi
done < "$STATE/files"
find "$SITE/omlx" -name __pycache__ -type d -prune -exec rm -rf {} +

echo "${TO_APPLY[*]}" > "$STATE/applied"
echo "$VERSION" > "$STATE/version"
date '+%Y-%m-%d %H:%M' > "$STATE/date"
mkdir -p "$(dirname "$RECORD")"
printf '%s\n%s\n' "${PRS[*]}" "$VERSION" > "$RECORD"

"$PY" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import omlx.cli' "$SITE" \
    || echo "warning: 'import omlx.cli' failed after patching; consider --revert" >&2
echo "Applied PRs ${TO_APPLY[*]} to oMLX $VERSION ($(wc -l < "$STATE/files" | tr -d ' ') files, backups in $STATE)."
echo "Restart the oMLX server to load them."
