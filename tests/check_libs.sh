#!/usr/bin/env bash
# A function that lives in scripts/lib/*.sh but whose caller never sources the
# file fails only at runtime ("command not found") — after the node has already
# been changed. This turns that into a static check.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
fail=0
say() { printf '%s\n' "$*"; }

for lib in "$REPO_DIR"/scripts/lib/*.sh; do
  [ -s "$lib" ] || continue
  libname="$(basename "$lib")"
  # functions the library defines
  mapfile -t funcs < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$lib" | tr -d '()' | sort -u)
  [ "${#funcs[@]}" -gt 0 ] || continue
  # scripts that call one of them
  for f in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/apps/*/*.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$libname" ] && continue
    called=""
    for fn in "${funcs[@]}"; do
      # a call looks like a command: start of line, after a separator, or after
      # a shell keyword — never as a word inside prose or a comment
      grep -vE '^\s*#' "$f" | grep -qE "(^|[;&|(]\s*|&&\s*|\|\|\s*|then\s+|do\s+|!\s*)${fn}([^a-zA-Z0-9_]|$)" || continue
      grep -qE "^\s*${fn}\(\)" "$f" && continue          # it defines its own
      called="$fn"; break
    done
    [ -n "$called" ] || continue
    if grep -qF "lib/$libname" "$f"; then
      say "ok   $(basename "$f") calls $called and sources lib/$libname"
    else
      say "FAIL $(basename "$f") calls $called but never sources lib/$libname"; fail=1
    fi
  done
done

[ "$fail" = 0 ] && say "libraries: every caller sources what it uses"
exit "$fail"
