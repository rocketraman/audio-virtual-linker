#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Import common helpers
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/watch-common.sh"

# Earfun headset (HFP only, lower priority than XM5)
HEADSET_NAME="Earfun"
DEVICE_PATH="/org/bluez/hci0/dev_${EARFUN_ADDR_UNDERSCORED}"
TRANSPORT_NAMESPACE="${DEVICE_PATH}"


log "🔭 Watching BlueZ for ${HEADSET_NAME} under ${TRANSPORT_NAMESPACE} ..."
log "   Device path: ${DEVICE_PATH}"
log "   Card name : ${EARFUN_CARD}"

current_path=""
in_device1=0
expecting_connected_value=0

while read -r line; do
  # New signal block: capture path, reset per-signal state
  if [[ "$line" == signal* ]]; then
    current_path=""
    if [[ "$line" =~ path=([^[:space:]]+) ]]; then
      current_path="${BASH_REMATCH[1]}"
    fi
    in_device1=0
    expecting_connected_value=0
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
    sleep 1

    # Priority: if XM5 is active, do NOT override it
    if card_has_active_profile "${XM5_CARD}"; then
      log "ℹ XM5 card (${XM5_CARD}) has an active profile; not wiring Earfun"
      continue
    fi

    # Earfun is HFP-only; ensure headset-head-unit + earfun wiring
    ensure_profile_and_wire "${EARFUN_CARD}" "headset-head-unit" "earfun-hfp" || true
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
done < <(dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='${TRANSPORT_NAMESPACE}'")
