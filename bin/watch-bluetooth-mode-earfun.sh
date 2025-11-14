#!/usr/bin/env bash

set -euo pipefail

EARFUN_BT_MAC="A1:51:8D:B9:80:6A"
EARFUN_BT_UNDERSCORED="${EARFUN_BT_MAC//:/_}"
EARFUN_DEVICE_PATH="/org/bluez/hci0/dev_${EARFUN_BT_UNDERSCORED}"
TRANSPORT_NAMESPACE="${EARFUN_DEVICE_PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

log() {
  echo -e "[$(date +'%H:%M:%S')] $*"
}

wire_mode() {
  local mode="$1"

  if [[ "$mode" == "earfun-hfp" ]]; then
    log "🎙 Wiring Earfun HFP (Mic + Mono)..."
    if ! "${ROOT_DIR}/lib/wire-mode.sh" "earfun-hfp"; then
      log "❌ Earfun HFP wiring failed"
    fi

  elif [[ "$mode" == "usb" ]]; then
    log "🔌 Wiring USB fallback (no Bluetooth active)..."
    if ! "${ROOT_DIR}/lib/wire-mode.sh" "usb"; then
      log "❌ USB fallback wiring failed"
    fi
  fi
}

# --- pactl helpers for earfun card --------------------------------------------

get_earfun_profile() {
  pactl list cards 2>/dev/null \
    | awk -v RS='' "/bluez_card.${EARFUN_BT_UNDERSCORED}/ {
         for (i=1; i<=NF; i++)
           if (\$i ~ /^Active[[:space:]]Profile:/) {
             sub(/Active[[:space:]]Profile:[[:space:]]*/, \"\", \$0);
             print \$0;
             exit
           }
       }" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

ensure_earfun_hfp_and_wire() {
  local CURRENT_PROFILE
  CURRENT_PROFILE="$(pactl list cards | awk -v RS='' '/A1_51_8D_B9_80_6A/ { for (i=1; i<=NF; i++) if ($i ~ /Active[[:space:]]+Profile:/) { sub(/.*Active[[:space:]]+Profile:[[:space:]]*/, "", $0); print $0; exit } }' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [[ "$CURRENT_PROFILE" == "headset-head-unit" ]]; then
    log "🎙 Earfun is already headset-head-unit; wiring HFP virtual devices"
    if ! "${ROOT_DIR}/lib/wire-mode-earfun-hfp.sh"; then
      log "❌ Earfun wiring failed"
    fi
  else
    echo "🔧 🎧 Updating Earfun card profile to headset-head-unit"
    pactl set-card-profile bluez_card.A1_51_8D_B9_80_6A headset-head-unit
  fi
}


wire_default_if_no_bt() {
  if has_any_bt_profile; then
    log "ℹ Some Bluetooth profile still active; not wiring USB fallback"
  else
    log "🔁 No Bluetooth profiles active; wiring USB fallback"
    wire_mode usb
  fi
}

log "🔭 Watching earfun’s headset under ${TRANSPORT_NAMESPACE} ..."
log "   Device path: ${EARFUN_DEVICE_PATH}"

current_path=""
in_device1=0
expecting_connected_value=0

dbus-monitor --system \
  "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='${TRANSPORT_NAMESPACE}'" |
while read -r line; do
  if [[ "$line" == signal* ]]; then
    current_path=""
    if [[ "$line" =~ path=([^[:space:]]+) ]]; then
      current_path="${BASHREMATCH[1]}"
    fi
    in_device1=0
    expecting_connected_value=0
    continue
  fi

  # org.bluez.Device1 Connected
  if [[ "$line" == *"org.bluez.Device1"* ]]; then
    in_device1=1
    continue
  fi

  if [[ $in_device1 -eq 1 && "$line" == *'string "Connected"'* ]]; then
    expecting_connected_value=1
    continue
  fi

  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean true"* ]]; then
    log "🔌 Earfun Bluetooth headset CONNECTED"
    in_device1=0
    expecting_connected_value=0

    sleep 2
    ensure_earfun_hfp_and_wire
    continue
  fi

  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean false"* ]]; then
    log "🔌 Earfun Bluetooth headset DISCONNECTED"
    in_device1=0
    expecting_connected_value=0

    wire_default_if_no_bt
    continue
  fi
done
