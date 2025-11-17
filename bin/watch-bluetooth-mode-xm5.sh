#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Import common helpers
source "${ROOT_DIR}/lib/watch-common.sh"

# XM5 headset
HEADSET_NAME="XM5"
DEVICE_PATH="/org/bluez/hci0/dev_${XM5_ADDR_UNDERSCORED}"
TRANSPORT_NAMESPACE="${DEVICE_PATH}"        # watch device + all its children
LAST_STATE="unknown"   # last MediaTransport1 state: active / idle

log "🔭 Watching BlueZ for ${HEADSET_NAME} under ${TRANSPORT_NAMESPACE} ..."
log "   Device path: ${DEVICE_PATH}"
log "   Card name : ${XM5_CARD}"

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

    # On connect, favour HFP (mic available) as a safe default
    ensure_profile_and_wire "${XM5_CARD}" "headset-head-unit" "xm5-hfp" || true
    LAST_STATE="idle"  # treat as idle until we see MediaTransport1 signal
    continue
  fi

  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean false"* ]]; then
    log "🔌 Bluetooth device DISCONNECTED"
    in_device1=0
    expecting_connected_value=0

    # When XM5 goes away, maybe fall back to USB unless some other BT is active
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

      current_profile="$(get_card_profile "${XM5_CARD}" || echo "")"

      if [[ "$last_profile" == "$current_profile" ]]; then
        continue
      fi

      log "🎧 XM5 card profile change: '${last_profile}' -> '${current_profile}'"

      case "$current_profile" in
        "headset-head-unit")
          wire_mode "xm5-hfp" || true
          ;;
        "a2dp-sink")
          wire_mode "xm5-stereo" || true
          ;;
        *)
          log "⚠️ Unknown profile: $current_profile"
          ;;
      esac
      
      last_profile="$current_profile"
    fi
  fi
done < <(dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='${TRANSPORT_NAMESPACE}'")
