#!/usr/bin/env bash

set -euo pipefail

BT_MAC="80:99:E7:43:87:E0"
BT_ADDR_UNDERSCORED="${BT_MAC//:/_}"
DEVICE_PATH="/org/bluez/hci0/dev_${BT_ADDR_UNDERSCORED}"
TRANSPORT_NAMESPACE="${DEVICE_PATH}"  # watch device + all its children

LAST_STATE="unknown"      # last MediaTransport1 state: active / idle
LAST_PROFILE=""           # last *audio* profile we actually used: a2dp-sink / headset-head-unit / ""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

log() {
  echo -e "[$(date +'%H:%M:%S')] $*"
}

# Wire virtual devices according to *profile*, not transport state
wire_mode() {
  local mode="$1"

  if [[ "$mode" == "hfp" ]]; then
    log "🎙 Wiring XM5 HFP (Mic + Mono)..."
    if ! "${ROOT_DIR}/lib/wire-mode.sh" "hfp"; then
      log "❌ HFP wiring failed"
    else
      LAST_PROFILE="headset-head-unit"
    fi

  elif [[ "$mode" == "stereo" ]]; then
    log "🎧 Wiring XM5 Stereo (AAC)..."
    if ! "${ROOT_DIR}/lib/wire-mode.sh" "stereo"; then
      log "❌ Stereo wiring failed"
    else
      LAST_PROFILE="a2dp-sink"
    fi
  fi
}

# Helper: read current BT card profile via pactl
get_current_profile() {
  pactl list cards 2>/dev/null \
    | awk -v RS='' '/bluez/ { for (i=1; i<=NF; i++) if ($i ~ /^Active[[:space:]]Profile:/) { sub(/Active[[:space:]]Profile:[[:space:]]*/, "", $0); print $0; exit } }' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Make sure card profile matches what we want, then wire
ensure_profile_and_wire() {
  local desired_profile="$1"   # a2dp-sink | headset-head-unit
  local mode="$2"             # stereo | hfp

  local current_profile
  current_profile="$(get_current_profile || true)"

  log "🔍 Current BT card profile: ${current_profile:-<none>} (want: $desired_profile)"

  if [[ "$current_profile" != "$desired_profile" ]]; then
    log "🔧 Updating card profile → $desired_profile"
    pactl set-card-profile "bluez_card.${BT_ADDR_UNDERSCORED}" "$desired_profile" || {
      log "❌ Failed to set card profile to $desired_profile"
      return 1
    }
    # Small delay to let PipeWire reconfigure ports
    sleep 0.5
  fi

  wire_mode "$mode"
}

# Is there any Bluetooth card with a non-off profile?
has_any_bt_profile() {
  pactl list cards 2>/dev/null | awk -v RS='' '
    /bluez_card/ && /Active Profile:/ {
      if ($0 !~ /Active Profile: off/) {
        found=1
      }
    }
    END { exit found ? 0 : 1 }'
}

# Only fall back to USB when *no* BT profiles are active
wire_default_if_no_bt() {
  if has_any_bt_profile; then
    log "ℹ Some Bluetooth profile still active; not wiring USB fallback"
  else
    log "🔁 No Bluetooth profiles active; wiring USB fallback (USB speakers + webcam mic)..."
    if ! "${ROOT_DIR}/lib/wire-mode.sh" "usb"; then
      log "❌ USB fallback wiring failed"
    fi
  fi
}

log "🔭 Watching BlueZ under ${TRANSPORT_NAMESPACE} ..."
log "   Device path: ${DEVICE_PATH}"

current_path=""
in_device1=0
expecting_connected_value=0
in_media=0
expecting_state_value=0

# Single watcher: one dbus-monitor, one loop, no background processes
dbus-monitor --system \
  "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='${TRANSPORT_NAMESPACE}'" |
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

  # ----------------------------
  # 1) Device Connected true/false (org.bluez.Device1)
  # ----------------------------

  # Look for org.bluez.Device1 in this signal
  if [[ "$line" == *"org.bluez.Device1"* ]]; then
    in_device1=1
    continue
  fi

  # Inside that block, look for the "Connected" property
  if [[ $in_device1 -eq 1 && "$line" == *'string "Connected"'* ]]; then
    expecting_connected_value=1
    continue
  fi

  # Next line after "Connected" is the boolean value
  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean true"* ]]; then
    log "🔌 Bluetooth device CONNECTED"
    in_device1=0
    expecting_connected_value=0

    # Give PipeWire a chance to create the nodes
    sleep 2

    # Decide what to do based on LAST_PROFILE (the last *audio* mode we used)
    current_profile="$(get_current_profile || true)"
    log "🔁 Re-applying based on LAST_PROFILE='${LAST_PROFILE:-<none>}' (current=${current_profile:-<none>})"

    case "$LAST_PROFILE" in
      a2dp-sink)
        ensure_profile_and_wire "a2dp-sink" "stereo"
        ;;
      headset-head-unit)
        ensure_profile_and_wire "headset-head-unit" "hfp"
        ;;
      *)
        # No previous knowledge: default to HFP to preserve mic
        log "ℹ No previous profile; defaulting to HFP (headset-head-unit)"
        ensure_profile_and_wire "headset-head-unit" "hfp"
        ;;
    esac

    continue
  fi

  if [[ $expecting_connected_value -eq 1 && "$line" == *"boolean false"* ]]; then
    log "🔌 Bluetooth device DISCONNECTED"
    in_device1=0
    expecting_connected_value=0

    # If no Bluetooth headsets are active anymore, fall back to USB
    wire_default_if_no_bt
    continue
  fi

  # ----------------------------
  # 2) MediaTransport1 State active/idle (profile / transport triggers)
  # ----------------------------
  # Paths like: /org/bluez/hci0/dev_.../sepN/fdXX
  if [[ "$current_path" == "$DEVICE_PATH"/sep* ]]; then
    # Check we’re in the MediaTransport1 interface block
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
      NEW_STATE="${BASH_REMATCH[1]}"
      log "🔄 Transport state changed: $NEW_STATE (path=${current_path})"

      expecting_state_value=0
      in_media=0

      if [[ "$NEW_STATE" == "$LAST_STATE" ]]; then
        LAST_STATE="$NEW_STATE"
        continue
      fi

      sleep 0.3

      # 🔑 IMPORTANT: use current profile to decide what to wire,
      #               NOT the active/idle symbol itself.
      current_profile="$(get_current_profile || true)"
      log "🔍 Transport-triggered check: Active Profile is '${current_profile:-<none>}'"

      if [[ "$current_profile" == "a2dp-sink" ]]; then
        ensure_profile_and_wire "a2dp-sink" "stereo"
      elif [[ "$current_profile" == "headset-head-unit" ]]; then
        ensure_profile_and_wire "headset-head-unit" "hfp"
      else
        # Fallback heuristic: active → stereo, idle → HFP, and set profile accordingly
        if [[ "$NEW_STATE" == "active" ]]; then
          log "⚠ Unknown profile; NEW_STATE=active → forcing a2dp-sink + stereo"
          ensure_profile_and_wire "a2dp-sink" "stereo"
        else
          log "⚠ Unknown profile; NEW_STATE=idle → forcing headset-head-unit + HFP"
          ensure_profile_and_wire "headset-head-unit" "hfp"
        fi
      fi

      LAST_STATE="$NEW_STATE"
      continue
    fi
  fi
done
