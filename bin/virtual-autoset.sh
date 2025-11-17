#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Import shared helpers (ensure_virtual_devices, wire_mode, get_card_profile, etc.)
source "${ROOT_DIR}/lib/watch-common.sh"

# Give this script its own log prefix
HEADSET_NAME="Virtual-Autoset"

# --- Initial wiring ----------------------------------------------------------

initial_wiring() {
  log "🚀 Performing initial wiring..."

  ensure_virtual_devices

  # 1) Prefer XM5 if it has an active profile
  local xm5_profile=""
  xm5_profile="$(get_card_profile "${XM5_CARD}" || true)"

  if [[ -n "${xm5_profile}" && "${xm5_profile}" != "off" ]]; then
    log "🎧 XM5 card found (${XM5_CARD}), active profile: ${xm5_profile}"

    case "${xm5_profile}" in
      a2dp-sink)
        log "🔧 Wiring XM5 stereo (existing A2DP profile)..."
        wire_mode xm5-stereo || log "❌ Failed to wire XM5 stereo"
        return
        ;;
      headset-head-unit)
        log "🔧 Wiring XM5 HFP (existing headset profile)..."
        wire_mode xm5-hfp || log "❌ Failed to wire XM5 HFP"
        return
        ;;
      *)
        log "ℹ XM5 profile '${xm5_profile}' is not handled explicitly; leaving wiring to watcher"
        # fallthrough: maybe Earfun or USB can be used
        ;;
    esac
  else
    log "ℹ XM5 card not present or profile 'off'"
  fi

  # 2) If XM5 is not effectively active, consider Earfun
  local earfun_profile=""
  earfun_profile="$(get_card_profile "${EARFUN_CARD}" || true)"

  if [[ -n "${earfun_profile}" && "${earfun_profile}" != "off" ]]; then
    log "🎧 Earfun card found (${EARFUN_CARD}), active profile: ${earfun_profile}"

    if [[ "${earfun_profile}" == "headset-head-unit" ]]; then
      log "🔧 Wiring Earfun HFP (existing headset profile)..."
      wire_mode earfun-hfp || log "❌ Failed to wire Earfun HFP"
      return
    else
      log "ℹ Earfun profile '${earfun_profile}' is not handled explicitly; leaving wiring to watcher"
    fi
  else
    log "ℹ Earfun card not present or profile 'off'"
  fi

  # 3) If no BT profile is active, fall back to USB
  if has_any_bt_profile; then
    log "ℹ Some Bluetooth profile is active but not clearly XM5/Earfun; leaving wiring to watchers"
  else
    log "🔁 No active Bluetooth profiles; wiring USB fallback (USB speakers + webcam mic)..."
    wire_mode usb || log "❌ Failed to wire USB fallback"
  fi
}

# --- Watcher management -------------------------------------------------------

start_watchers() {
  log "👀 Starting XM5 watcher..."
  "${ROOT_DIR}/bin/watch-bluetooth-mode-xm5.sh" &
  XM5_PID=$!

  log "👀 Starting Earfun watcher..."
  "${ROOT_DIR}/bin/watch-bluetooth-mode-earfun.sh" &
  EARFUN_PID=$!

  log "✅ Watchers started: XM5=${XM5_PID}, Earfun=${EARFUN_PID}"
}

cleanup() {
  log "🧹 Cleaning up watcher processes..."

  # Send SIGTERM to both, ignore if already gone
  if [[ -n "${XM5_PID:-}" ]]; then
    kill "${XM5_PID}" 2>/dev/null || true
  fi
  if [[ -n "${EARFUN_PID:-}" ]]; then
    kill "${EARFUN_PID}" 2>/dev/null || true
  fi

  # Wait for them to exit
  wait "${XM5_PID:-}" 2>/dev/null || true
  wait "${EARFUN_PID:-}" 2>/dev/null || true

  log "🧹 Cleanup complete"
}

main() {
  # Trap signals so systemd stop / Ctrl-C kills the watchers too
  trap cleanup INT TERM EXIT

  initial_wiring
  start_watchers

  # Wait for *either* watcher to exit; if that happens, we exit too and systemd
  # can restart this script if desired.
  wait -n "${XM5_PID}" "${EARFUN_PID}" || true
  log "⚠ One of the watchers exited; main script will exit now"
}

main "$@"
