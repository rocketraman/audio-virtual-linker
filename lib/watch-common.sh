#!/usr/bin/env bash
# Common helpers for Bluetooth / PipeWire watchers

set -euo pipefail

# Root of the project (bin/, lib/ etc.)
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- Headset identifiers / cards ---------------------------------------------

# XM5 (high priority, stereo + HFP)
export XM5_BT_MAC="80:99:E7:43:87:E0"
export XM5_ADDR_UNDERSCORED="${XM5_BT_MAC//:/_}"
export XM5_CARD="bluez_card.${XM5_ADDR_UNDERSCORED}"

# Earfun (HFP only, lower priority than XM5)
export EARFUN_BT_MAC="A1:51:8D:B9:80_6A"
# You had literal ':' version for the bluez_input name; card name still uses '_' form:
export EARFUN_ADDR_UNDERSCORED="${EARFUN_BT_MAC//:/_}"
export EARFUN_CARD="bluez_card.${EARFUN_ADDR_UNDERSCORED}"

# For nicer logs; watcher scripts should set HEADSET_NAME before sourcing
: "${HEADSET_NAME:=Headset}"

log() {
  echo -e "[$(date +'%H:%M:%S')] [${HEADSET_NAME}] $*"
}

# --- Virtual device helpers ---------------------------------------------------

ensure_virtual_devices() {
  # virtual-sink
  if ! pactl list short sinks | awk '{print $2}' | grep -qx "virtual-sink"; then
    log "🔧 Creating virtual sink 'virtual-sink'..."
    pactl load-module module-null-sink \
      media.class=Audio/Sink \
      sink_name=virtual-sink \
      channel_map=stereo >/dev/null
  fi

  # virtual-mic
  if ! pactl list short sources | awk '{print $2}' | grep -qx "virtual-mic"; then
    log "🔧 Creating virtual source 'virtual-mic'..."
    pactl load-module module-null-sink \
      media.class=Audio/Source/Virtual \
      sink_name=virtual-mic \
      channel_map=front-left,front-right >/dev/null
  fi
}

wire_mode() {
  local mode="$1"
  ensure_virtual_devices
  log "🔧 Wiring mode '${mode}' via wire-mode.sh..."
  if ! "${ROOT_DIR}/lib/wire-mode.sh" "$mode"; then
    log "❌ Wiring mode '${mode}' failed"
    return 1
  fi
}

# --- Card / profile helpers ---------------------------------------------------

# Get Active Profile for a specific bluez card (or empty string)
get_card_profile() {
  local card_name="$1"
  pactl list cards |
    awk -v RS='' -v card="$card_name" '
      $0 ~ card {
        if (match($0, /Active Profile: *([^\n]+)/, m)) {
          p = m[1]
          sub(/^ +/, "", p)
          sub(/ +$/, "", p)
          print p
        }
      }'
}

# True (exit 0) if any bluez_card.* has a non-"off" profile
has_any_bt_profile() {
  pactl list cards |
    awk -v RS='' '
      /bluez_card\./ {
        if (match($0, /Active Profile: *([^\n]+)/, m)) {
          if (m[1] != "off") {
            exit 0
          }
        }
      }
      END { exit 1 }'
}

# True if this specific card has a non-"off" profile
card_has_active_profile() {
  local card_name="$1"
  local p
  p="$(get_card_profile "$card_name")"
  [[ -n "${p}" && "${p}" != "off" ]]
}

# Ensure card is on the desired profile, then wire the corresponding mode
#   $1 = card name (e.g. bluez_card.80_99_E7_43_87_E0)
#   $2 = desired PipeWire profile (e.g. a2dp-sink, headset-head-unit)
#   $3 = wire-mode.sh mode (e.g. xm5-stereo, xm5-hfp, earfun-hfp)
ensure_profile_and_wire() {
  local card_name="$1"
  local desired_profile="$2"
  local mode="$3"

  local current_profile
  current_profile="$(get_card_profile "$card_name" || true)"

  log "🎚 Current card profile for ${card_name}: ${current_profile:-<none>} (want: ${desired_profile})"

  if [[ "${current_profile}" != "${desired_profile}" ]]; then
    log "🔧 Updating card profile: ${current_profile:-<none>} → ${desired_profile}"
    if ! pactl set-card-profile "${card_name}" "${desired_profile}"; then
      log "❌ Failed to set card profile ${desired_profile} on ${card_name}"
      return 1
    fi
    # Give PipeWire a moment to rebuild nodes
    sleep 0.4
  fi

  wire_mode "${mode}"
}

# Wire USB fallback if no BT card has an active profile
wire_default_if_no_bt() {
  if has_any_bt_profile; then
    log "ℹ Some Bluetooth profile still active; not wiring USB fallback"
  else
    log "🔁 No Bluetooth profiles active; wiring USB fallback (USB speakers + webcam mic)..."
    if ! wire_mode usb; then
      log "❌ USB fallback wiring failed"
    fi
  fi
}
