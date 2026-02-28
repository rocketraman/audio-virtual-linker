#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Import common helpers
source "${ROOT_DIR}/lib/watch-common.sh"

# Earfun headset (HFP only, lower priority than XM5)
HEADSET_NAME="Earfun"
DEVICE_PATH="$(get_bluez_device_path "${EARFUN_BT_MAC}")"

if [[ -z "${DEVICE_PATH}" ]]; then
  log "❌ Could not find BlueZ device path for ${EARFUN_BT_MAC}. Is it paired?"
  # Fallback to a guess if discovery fails, using active HCI if possible
  HCI_PATH="$(get_active_hci_path)"
  DEVICE_PATH="${HCI_PATH:-/org/bluez/hci0}/dev_${EARFUN_ADDR_UNDERSCORED}"
fi

TRANSPORT_NAMESPACE="${DEVICE_PATH}"        # watch device + all its children
LAST_STATE="unknown"   # last MediaTransport1 state: active / idle

log "🔭 Watching BlueZ for ${HEADSET_NAME} under ${TRANSPORT_NAMESPACE} ..."
log "   Device path: ${DEVICE_PATH}"
log "   Card name : ${EARFUN_CARD}"

current_path=""
in_device1=0
expecting_connected_value=0
in_media=0
expecting_state_value=0
last_profile=

while read -r line; do
  # New signal block: capture path, reset per-signal state
  if [[ "$line" == signal* ]]; then
    current_path=""
    if [[ "$line" =~ path=([^[:space:]]+) ]]; then
      current_path="${BASH_REMATCH[1]}"
    fi
    in_device1=0
    expecting_connected_value=0
    in_media=0
    expecting_state_value=0
    continue
  fi

  # ---------------------------------------------------------------------------
  # 1) Device Connected true/false (org.bluez.Device1)
  # ---------------------------------------------------------------------------

  if [[ "$line" == *"org.bluez.Device1"* ]]; then
    in_device1=1
    continue
  fi

  if [[ $in_device1 -eq 1 && "$line" == *'string "Connected"'* ]]; then
    expecting_connected_value=1
    continue
  fi

  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean true"* ]]; then
    log "🔌 Bluetooth device CONNECTED"

    in_device1=0
    expecting_connected_value=0

    # Give BlueZ/PipeWire some time to create nodes & card
    sleep 3

    # Priority: if XM5 is active, do NOT override it
    if card_has_active_profile "${XM5_CARD}"; then
      log "ℹ XM5 card (${XM5_CARD}) has an active profile; not wiring Earfun"
      continue
    fi

    # On connect, favour HFP (mic available) as a safe default
    ensure_profile_and_wire "${EARFUN_CARD}" "headset-head-unit" "earfun-hfp" || true
    LAST_STATE="idle"  # treat as idle until we see MediaTransport1 signal
    continue
  fi

  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean false"* ]]; then
    log "🔌 Bluetooth device DISCONNECTED"
    in_device1=0
    expecting_connected_value=0

    # On Earfun disconnect, maybe fall back to USB unless some BT profile is active
    wire_default_if_no_bt
    continue
  fi

  # ---------------------------------------------------------------------------
  # 2) MediaTransport1 State active/idle (per-profile transport)
  # ---------------------------------------------------------------------------
  # Paths like: /org/bluez/hci0/dev_.../fdXX
  if [[ "$current_path" == "$DEVICE_PATH"/* ]]; then
    # Check we’re in a MediaTransport1 interface block
    if [[ "$line" == *"org.bluez.MediaTransport1"* ]]; then
      in_media=1
      expecting_state_value=0
      continue
    fi

    # Inside that, look for "State"
    if [[ $in_media -eq 1 && "$line" == *'string "State"'* ]]; then
      expecting_state_value=1
      continue
    fi

    # Next variant line has "active" / "idle"
    if [[ $expecting_state_value -eq 1 && "$line" =~ variant[[:space:]]+string[[:space:]]+\"(active|idle)\" ]]; then
      log "🔄 Transport state changed path=${current_path}"

      expecting_state_value=0
      in_media=0

      # Let PipeWire settle a bit
      sleep 0.

      current_profile="$(get_card_profile "${EARFUN_CARD}" || echo "")"

      if [[ "$last_profile" == "$current_profile" ]]; then
        continue
      fi

      log "🎧 Earfun card profile change: '${last_profile}' -> '${current_profile}'"

      case "$current_profile" in
        "headset-head-unit")
          wire_mode "earfun-hfp" || true
          ;;
        "a2dp-sink")
          wire_mode "earfun-stereo" || true
          ;;
        *)
          log "⚠️ Unknown profile: $current_profile"
          ;;
      esac
      
      last_profile="$current_profile"
    fi
  fi
done < <(dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='${TRANSPORT_NAMESPACE}'")
