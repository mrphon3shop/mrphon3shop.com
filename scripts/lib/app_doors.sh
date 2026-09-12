# shellcheck shell=bash
# ============================================================================
#  app_doors.sh — put the application doors back in place.
#
#  Why this is a separate, callable step: the doors are Tailscale `serve`
#  statements, and on a fresh runner the service stage (40-apply-services.sh)
#  runs BEFORE tailscaled is up and authenticated — the statements then fail and
#  the panels stay loopback-only.  50-tailscale-funnel.sh is the stage that
#  brings Tailscale up, so it calls this again at the end.  Idempotent.
# ============================================================================
apply_app_doors() { # [$1 = services.json path]
  local manifest="${1:-$REPO_DIR/manifest/services.json}"
  local svc name port path sport tport ttarget
  [ -s "$manifest" ] || { warn "app_doors: $manifest missing — no doors applied"; return 0; }
  command -v tailscale >/dev/null 2>&1 || { warn "app_doors: tailscale not installed"; return 0; }
  while IFS= read -r svc; do
    name="$(jq -r '.name' <<<"$svc")"
    [ "$(jq -r '.enabled // false' <<<"$svc")" = "true" ] || continue
    port="$(jq -r '.port // 0' <<<"$svc")"
    if jq -e '.tailnet_tcp.port' <<<"$svc" >/dev/null 2>&1; then
      tport="$(jq -r '.tailnet_tcp.port' <<<"$svc")"
      ttarget="$(jq -r '.tailnet_tcp.target_port // 0' <<<"$svc")"
      [ "$ttarget" = 0 ] && ttarget="$port"
      if sudo tailscale serve --bg "--tcp=${tport}" "tcp://127.0.0.1:${ttarget}" >/dev/null 2>&1; then
        log "door: $name on tcp/$tport (tailnet only)"
      else
        warn "door: $name on tcp/$tport could not be applied"
      fi
    fi
    if jq -e '.tailnet_serve' <<<"$svc" >/dev/null 2>&1; then
      path="$(jq -r '.tailnet_serve.path // ("/" + .name)' <<<"$svc")"
      sport="$(jq -r '.tailnet_serve.port // 443' <<<"$svc")"
      sudo tailscale serve --bg "--https=${sport}" "--set-path=${path}" "http://127.0.0.1:${port}" >/dev/null 2>&1 \
        || sudo tailscale serve --bg "--https=${sport}" "http://127.0.0.1:${port}" >/dev/null 2>&1 \
        || warn "door: $name on https/$sport$path could not be applied"
    fi
  done < <(jq -c '.services[]?' "$manifest")
  return 0
}
