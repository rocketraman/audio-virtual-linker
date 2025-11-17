#!/usr/bin/env bash

# Unified wiring script for virtual sink/mic ↔ Bluetooth/USB
#
# Modes:
#   xm5-hfp      – Sony XM5, HFP (mono + mic)
#   xm5-stereo   – Sony XM5, A2DP stereo (AAC)
#   earfun-hfp   – EarFun style headset, HFP only
#   usb          – USB speakers + USB webcam mic (fallback/default)
#
# This script:
#   * Unlinks ALL physical links that involve virtual-sink / virtual-mic
#   * Applies a single consistent wiring for the chosen mode
#   * Enforces XM5 priority over EarFun when requested

set -euo pipefail

log() {
  echo -e "[wire-mode] $*" >&2
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Import shared helpers (ensure_virtual_devices, wire_mode, get_card_profile, etc.)
source "${LIB_DIR}/watch-common.sh"

# --- Virtual devices ---
VIRTUAL_SINK_FL="virtual-sink:monitor_FL"
VIRTUAL_SINK_FR="virtual-sink:monitor_FR"
VIRTUAL_MIC_FL="virtual-mic:input_FL"
VIRTUAL_MIC_FR="virtual-mic:input_FR"

# --- USB speakers & webcam mic ---
USB_SPK_FL="alsa_output.usb-Generic_USB_Audio-00.HiFi__Speaker__sink:playback_FL"
USB_SPK_FR="alsa_output.usb-Generic_USB_Audio-00.HiFi__Speaker__sink:playback_FR"
USB_CAM_MIC_FL="alsa_input.usb-046d_HD_Pro_Webcam_C920_B570B5EF-02.analog-stereo:capture_FL"
USB_CAM_MIC_FR="alsa_input.usb-046d_HD_Pro_Webcam_C920_B570B5EF-02.analog-stereo:capture_FR"

# --- Sony WH-1000XM5 ---
XM5_SINK_FL="bluez_output.80_99_E7_43_87_E0.1:playback_FL"
XM5_SINK_FR="bluez_output.80_99_E7_43_87_E0.1:playback_FR"
XM5_SINK_MONO="bluez_output.80_99_E7_43_87_E0.1:playback_MONO"
XM5_MIC_MONO="bluez_input.80:99:E7:43:87:E0:capture_MONO"

# --- EarFun-style 2nd headset ---
EARFUN_SINK_MONO="bluez_output.A1_51_8D_B9_80_6A.1:playback_MONO"
EARFUN_MIC_MONO="bluez_input.A1:51:8D:B9:80:6A:capture_MONO"

current_xm5_profile() {
  pactl list cards 2>/dev/null | awk -v RS='' '/Name: '"$XM5_CARD"'/ { if (match($0, /Active Profile: (.*)/, m)) print m[1]; }'
}

# Reusable regex for physical ports we care about
PHYSICAL_REGEX="($USB_SPK_FL|$USB_SPK_FR|$USB_CAM_MIC_FL|$USB_CAM_MIC_FR|$XM5_SINK_FL|$XM5_SINK_FR|$XM5_SINK_MONO|$XM5_MIC_MONO|$EARFUN_SINK_MONO|$EARFUN_MIC_MONO)"

# List existing links between virtual-(sink|mic) and the supported physical ports
# Output format per line: "FROM|TO"
list_virtual_physical_links() {
  local current_dst=""
  pw-link -il 2>/dev/null | while IFS= read -r line; do
    # Destination header line
    if [[ "$line" =~ ^[^\ ].* ]]; then
      current_dst="$(echo "$line" | sed 's/^[[:space:]]*//')"
      continue
    fi

    # Linked source line
    if [[ "$line" =~ ^[[:space:]]*\|[-\<\>]*[[:space:]](.*) ]]; then
      local src="${BASH_REMATCH[1]}"
      src="$(echo "$src" | sed 's/^[[:space:]]*//')"

      # Consider only links where exactly one side is virtual-(sink|mic) and the other is in PHYSICAL_REGEX
      if { [[ "$current_dst" =~ virtual-(sink|mic) && "$src" =~ $PHYSICAL_REGEX ]] || [[ "$src" =~ virtual-(sink|mic) && "$current_dst" =~ $PHYSICAL_REGEX ]]; }; then
        echo "${src}|${current_dst}"
      fi
    fi
  done | awk '!seen[$0]++'
}

# Apply desired links with minimal disruption:
# 1) Compute existing links (old)
# 2) Link missing ones (desired − old)
# 3) Unlink obsolete ones (old − desired)
apply_links() {
  # desired pairs passed as arguments: "FROM|TO"
  local -a desired_pairs=("$@")

  # Build sets
  declare -A old_set=()
  declare -A desired_set=()

  # Fill desired_set
  local p
  for p in "${desired_pairs[@]}"; do
    # guard against empty entries
    [[ -n "$p" ]] && desired_set["$p"]=1
  done

  # Fill old_set from current graph
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && old_set["$line"]=1
  done < <(list_virtual_physical_links)

  # To add: in desired but not in old
  local -a to_add=()
  for p in "${!desired_set[@]}"; do
    if [[ -z "${old_set[$p]:-}" ]]; then
      to_add+=("$p")
    fi
  done

  # To remove: in old but not in desired
  local -a to_remove=()
  for p in "${!old_set[@]}"; do
    if [[ -z "${desired_set[$p]:-}" ]]; then
      to_remove+=("$p")
    fi
  done

  # 1) Add new links first
  local from to
  for p in "${to_add[@]}"; do
    from="${p%%|*}"
    to="${p#*|}"
    safe_link "$from" "$to" || true
  done

  # 2) Then remove obsolete links
  for p in "${to_remove[@]}"; do
    from="${p%%|*}"
    to="${p#*|}"
    safe_unlink "$from" "$to" || true
  done
}


safe_link() {
  local from="$1" to="$2"
  if [[ -z "$from" || -z "$to" ]]; then
    log "⚠️  safe_link with empty from/to: '$from' → '$to'"
    return 1
  fi
  log "  🔗 Linking $from → $to"
  if ! pw-link "$from" "$to"; then
    log "  ⚠️ link failed: $from → $to"
    return 1
  fi
}

safe_unlink() {
  local from="$1" to="$2"
  if [[ -z "$from" || -z "$to" ]]; then
    return 1
  fi
  log "  ❌ Unlink: $from -> $to"
  pw-link -d "$from" "$to" 2> /dev/null || true
}

wire_usb() {
  log "🎧 Wiring VIRTUAL → USB speakers + USB webcam mic"
  local desired=()
  # Sink: everything through USB speakers
  desired+=("$VIRTUAL_SINK_FL|$USB_SPK_FL")
  desired+=("$VIRTUAL_SINK_FR|$USB_SPK_FR")
  # Mic: always-available webcam
  desired+=("$USB_CAM_MIC_FL|$VIRTUAL_MIC_FL")
  desired+=("$USB_CAM_MIC_FR|$VIRTUAL_MIC_FR")
  apply_links "${desired[@]}"
}

wire_xm5_stereo() {
  log "🎧 Wiring VIRTUAL → XM5 Stereo (AAC) + USB webcam mic"
  local desired=()
  # Sink: stereo to XM5
  desired+=("$VIRTUAL_SINK_FL|$XM5_SINK_FL")
  desired+=("$VIRTUAL_SINK_FR|$XM5_SINK_FR")
  # Mic: keep using webcam in stereo mode
  desired+=("$USB_CAM_MIC_FL|$VIRTUAL_MIC_FL")
  desired+=("$USB_CAM_MIC_FR|$VIRTUAL_MIC_FR")
  apply_links "${desired[@]}"
}

wire_xm5_hfp() {
  log "🎙 Wiring VIRTUAL ↔ XM5 HFP (mono + mic)"
  local desired=()
  # Mic: bluetooth mono to both L/R virtual mic channels
  desired+=("$XM5_MIC_MONO|$VIRTUAL_MIC_FL")
  desired+=("$XM5_MIC_MONO|$VIRTUAL_MIC_FR")
  # Sink: virtual sink → XM5 mono playback
  desired+=("$VIRTUAL_SINK_FL|$XM5_SINK_MONO")
  desired+=("$VIRTUAL_SINK_FR|$XM5_SINK_MONO")
  apply_links "${desired[@]}"
}

wire_earfun_hfp() {
  # XM5 priority: if XM5 card is present and not "off", skip EarFun wiring
  local xm5_profile
  xm5_profile="$(current_xm5_profile || true)"
  if [[ -n "$xm5_profile" && "$xm5_profile" != "off" ]]; then
    log "🔀 XM5 active (profile=$xm5_profile); skipping EarFun wiring to preserve XM5 priority"
    return 0
  fi

  log "🎧🎙 Wiring VIRTUAL ↔ EarFun HFP (mono + mic)"
  local desired=()
  # Mic: mono into both virtual mic channels
  desired+=("$EARFUN_MIC_MONO|$VIRTUAL_MIC_FL")
  desired+=("$EARFUN_MIC_MONO|$VIRTUAL_MIC_FR")
  # Sink: mirror the existing working EarFun wiring
  desired+=("$VIRTUAL_SINK_FL|$EARFUN_SINK_MONO")
  desired+=("$VIRTUAL_SINK_FR|$EARFUN_SINK_MONO")
  apply_links "${desired[@]}"
}

mode="${1-}" || mode=""
if [[ -z "$mode" ]]; then
  log "Usage: $0 {xm5-hfp|xm5-stereo|earfun-hfp|usb}"
  exit 1
fi

case "$mode" in
  usb)
    wire_usb
    ;;
  xm5-hfp)
    wire_xm5_hfp
    ;;
  xm5-stereo)
    wire_xm5_stereo
    ;;
  earfun-hfp)
    wire_earfun_hfp
    ;;
  *)
    log "Unknown mode: $mode (expected xm5-hfp|xm5-stereo|earfun-hfp|usb)"
    exit 1
    ;;
esac
