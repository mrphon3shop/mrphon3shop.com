#!/usr/bin/env bash
# ============================================================================
#  35-programs.sh — install software that is not an apt package.
#
#  Every entry in manifest/programs.json is fetched at the PINNED version and
#  materialised under its install_dir. Nothing here holds data: the persistent
#  part of a program (databases, settings, certificates) is declared in
#  manifest/services.json (data_paths/config_paths) and travels through the
#  encrypted memory repository.
#
#  usage: 35-programs.sh [--list] [--force] [program ...]
# ============================================================================
export LOG_TAG=programs
. "$(dirname "$0")/lib/common.sh"
load_config

MANIFEST="$REPO_DIR/manifest/programs.json"
STATE="$INSTALL_ROOT/state/programs.json"
mkdir -p "$(dirname "$STATE")"
[ -s "$STATE" ] || echo '{"programs":{}}' >"$STATE"
[ -s "$MANIFEST" ] || { warn "no $MANIFEST — nothing to install"; exit 0; }

FORCE=0; ONLY=(); LIST=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --list)  LIST=1 ;;
    -*)      warn "unknown flag $a" ;;
    *)       ONLY+=("$a") ;;
  esac
done

if [ "$LIST" = 1 ]; then
  jq -r '.programs[] | "\(.name)\t\(.version)\t\(.install_dir)"' "$MANIFEST"
  exit 0
fi

_installed_version() { jq -r ".programs[\"$1\"].version // empty" "$STATE" 2>/dev/null; }
_record() { # _record <name> <version> <note>
  local n="$1" v="$2" note="${3:-}"
  jq --arg n "$n" --arg v "$v" --arg note "$note" --arg ts "$(iso)" \
     --arg run "${GITHUB_RUN_ID:-local}" \
     '.programs[$n] = {version:$v, note:$note, installed_at:$ts, run:$run}' "$STATE" >"$STATE.t" && mv "$STATE.t" "$STATE"
}

_fetch_cached() { # _fetch_cached <url> <dest>  — reuse a download within this boot
  local url="$1" dest="$2"
  local cache
  # the release tarballs are large (3x-ui is ~77 MB) and /tmp can be a small
  # tmpfs: keep them on the same filesystem as the install root
  cache="${PROGRAM_CACHE:-$WORK/program-cache}/$(basename "$dest")"
  mkdir -p "$(dirname "$cache")"
  if [ -s "$cache" ]; then cp -f "$cache" "$dest"; return 0; fi
  retry 3 3 curl -fsSL --retry 2 --connect-timeout 15 -o "$dest" "$url" || return 1
  [ -s "$dest" ] && cp -f "$dest" "$cache"
  return 0
}

install_github_release() { # <json>
  local repo asset strip version url tmp marker
  repo="$(jq -r '.source.repo' <<<"$1")"; asset="$(jq -r '.source.asset' <<<"$1")"
  strip="$(jq -r '.source.strip_components // 0' <<<"$1")"; version="$(jq -r '.version' <<<"$1")"
  marker="$2"
  url="https://github.com/${repo}/releases/download/${version}/${asset}"
  tmp="$(mktemp -d "$WORK/program-tmp.XXXXXX")"
  _fetch_cached "$url" "$tmp/asset" || { rm -rf "$tmp"; warn "download failed: $url"; return 1; }
  tar -xzf "$tmp/asset" -C "$tmp" --strip-components="$strip" || { rm -rf "$tmp"; warn "extract failed: $asset"; return 1; }
  sudo mkdir -p "$(jq -r '.install_dir' <<<"$1")"
  sudo rsync -a --delete --exclude '.mrphon3shop-program.json' "$tmp/" "$(jq -r '.install_dir' <<<"$1")/"
  rm -rf "$tmp"
  return 0
}

install_git() { # <json>
  local url ref dir
  url="$(jq -r '.source.url' <<<"$1")"; ref="$(jq -r '.source.ref // "main"' <<<"$1")"
  dir="$(jq -r '.install_dir' <<<"$1")"
  sudo mkdir -p "$(dirname "$dir")"
  if sudo test -d "$dir/.git"; then
    sudo git -C "$dir" fetch -q --depth 1 origin "$ref" && sudo git -C "$dir" reset -q --hard FETCH_HEAD || return 1
  else
    sudo rm -rf "$dir"
    retry 3 3 sudo git clone -q --depth 1 --branch "$ref" "$url" "$dir" || return 1
  fi
  sudo git -C "$dir" log -1 --format=%H >/tmp/prog-rev
  return 0
}

START="$(now)"
FAILED=0
while IFS= read -r prog; do
  name="$(jq -r '.name' <<<"$prog")"
  if [ "${#ONLY[@]}" -gt 0 ]; then
    found=0; for o in "${ONLY[@]}"; do [ "$o" = "$name" ] && found=1; done
    [ "$found" = 1 ] || continue
  fi
  version="$(jq -r '.version' <<<"$prog")"
  dir="$(jq -r '.install_dir' <<<"$prog")"
  optional="$(jq -r '.optional // false' <<<"$prog")"
  marker="$dir/.mrphon3shop-program.json"

  if [ "$FORCE" = 0 ] && sudo test -s "$marker" \
     && [ "$(sudo jq -r '.version // empty' "$marker" 2>/dev/null)" = "$version" ]; then
    log "$name $version already installed"
    _record "$name" "$version" "cached"
    continue
  fi

  step "install $name $version"
  ok=1
  case "$(jq -r '.source.type' <<<"$prog")" in
    github-release) install_github_release "$prog" "$marker" || ok=0 ;;
    git)            install_git "$prog" || ok=0 ;;
    *)              warn "unknown source type for $name"; ok=0 ;;
  esac

  if [ "$ok" = 1 ]; then
    rev="$( [ "$(jq -r '.source.type' <<<"$prog")" = git ] && sudo git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "$version" )"
    sudo jq -n --arg n "$name" --arg v "$version" --arg rev "$rev" --arg ts "$(iso)" \
       '{name:$n, version:$v, revision:$rev, installed_at:$ts}' | sudo tee "$marker" >/dev/null
    bin="$(jq -r '.binary // empty' <<<"$prog")"
    if [ -n "$bin" ]; then
      sudo chmod +x "$dir/$bin" 2>/dev/null || true
      link="$(jq -r '.link_to // empty' <<<"$prog")"
      [ -n "$link" ] && sudo ln -sf "$dir/$bin" "$link"
    fi
    log "$name installed at $dir${rev:+ (rev $rev)}"
    _record "$name" "$version" "$rev"
  elif [ "$optional" = "true" ]; then
    warn "$name is optional and failed — continuing"
    _record "$name" "$version" "failed(optional)"
  else
    FAILED=$((FAILED+1)); _record "$name" "$version" "failed"
  fi
done < <(jq -c '.programs[]' "$MANIFEST")

jq -r '"  programs: " + ([.programs | to_entries[] | "\(.key)=\(.value.version)\(if .value.note|startswith("failed") then " (FAILED)" else "" end)"] | join("  "))' "$STATE" >&2
# the tarballs are only useful within one boot
[ "${KEEP_PROGRAM_CACHE:-0}" = 1 ] || rm -rf "${PROGRAM_CACHE:-$WORK/program-cache}"
log "program stage finished in $(( $(now) - START ))s"
[ "$FAILED" -eq 0 ] || die "$FAILED required program(s) failed to install (see above)"
exit 0
