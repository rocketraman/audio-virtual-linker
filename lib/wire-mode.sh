### lib/wire-mode.sh
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
#   * Unlinks ALL links that involve virtual-sink / virtual-mic
#   * Applies a single consistent wiring for the chosen mode
#   * Enforces XM5 priority over EarFun when requested

set -euo pipefail

log() {
  echo -e "[wire-mode] $*" >&2
}

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
XM5_CARD="bluez_card.80_99_E7_43_87_E0"
XM5_SINK_FL="bluez_output.80_99_E7_43_87_E0.1:playback_FL"
XM5_SINK_FR="bluez_output.80_99_E7_43_87_E0.1:playback_FR"
XM5_SINK_MONO="bluez_output.80_99_E7_43_87_E0.1:playback_MONO"
XM5_MIC_MONO="bluez_input.80:99:E7:43:87:E0:capture_MONO"

# --- EarFun-style 2nd headset ---
EARFUN_CARD="bluez_card.A1_51_8D_B9_80_6A"
EARFUN_OUT_FL="bluez_output.A1_51_8D_B9_80_6A.1:monitor_FL"
EARFUN_OUT_FR="bluez_output.A1_51_8D_B9_80_6A.1:monitor_FR"
EARFUN_IN_MONO="bluez_input.A1:51:8D:B9:80:6A:capture_MONO"

current_xm5_profile() {
  pactl list cards 2>/dev/null | awk -v RS='' '/Name: '"$XM5_CARD"'/ { if (match($0, /Active Profile: (.*)/, m)) print m[1]; }'
}

# Unlink any link whose from/to contains virtual-sink or virtual-mic
unlink_virtual_links() {
  log "🔌 Unlinking any existing virtual-sink / virtual-mic links..."
  pw-link -l 2>/dev/null \
    | grep -E 'virtual-(sink|mic)' || return 0

  pw-link -l 2>/dev/null \
    | grep -E 'virtual-(sink|mic)' \
    | sed -E 's/^[[:space:]]*[0-9]+\. //' \
    | while read -r from arrow to _; do
        [[ "$arrow" != "->" ]] && continue
        if [[ -n "$from" && -n "$to" ]]; then
          log "  ❌ unlink: $from -> $to"
          pw-link -d "$from" "$to" >/dev/null 2>&1 || true
        fi
      done
}

safe_link() {
  local from="$1" to="$2"
  if [[ -z "$from" || -z "$to" ]]; then
    log "⚠️  safe_link with empty from/to: '$from' → '$to'"
    return 1
  fi
  log "  🔗 $from → $to"
  if ! pw-link "$from" "$to" 2>/dev/null; then
    log "  ⚠️ link failed: $from → $to"
    return 1
  fi
}

wire_usb() {
  log "🎧 Wiring VIRTUAL → USB speakers + USB webcam mic"
  unlink_virtual_links

  # Sink: everything through USB speakers
  safe_link "$VIRTUAL_SINK_FL" "$USB_SPK_FL" || true
  safe_link "$VIRTUAL_SINK_FR" "$USB_SPK_FR" || true

  # Mic: always-available webcam
  safe_link "$USB_CAM_MIC_FL" "$VIRTUAL_MIC_FL" || true
  safe_link "$USB_CAM_MIC_FR" "$VIRTUAL_MIC_FR" || true
}

wire_xm5_stereo() {
  log "🎧 Wiring VIRTUAL → XM5 Stereo (AAC) + webcam mic"
  unlink_virtual_links

  # Sink: stereo to XM5
  safe_link "$VIRTUAL_SINK_FL" "$XM5_SINK_FL" || true
  safe_link "$VIRTUAL_SINK_FR" "$XM5_SINK_FR" || true

  # Mic: keep using webcam in stereo mode
  safe_link "$USB_CAM_MIC_FL" "$VIRTUAL_MIC_FL" || true
  safe_link "$USB_CAM_MIC_FR" "$VIRTUAL_MIC_FR" || true
}

wire_xm5_hfp() {
  log "🎙 Wiring VIRTUAL ↔ XM5 HFP (mono + mic)"
  unlink_virtual_links

  # Mic: bluetooth mono to both L/R virtual mic channels
  safe_link "$XM5_MIC_MONO" "$VIRTUAL_MIC_FL" || true
  safe_link "$XM5_MIC_MONO" "$VIRTUAL_MIC_FR" || true

  # Sink: virtual sink → XM5 mono playback
  safe_link "$VIRTUAL_SINK_FL" "$XM5_SINK_MONO" || true
  safe_link "$VIRTUAL_SINK_FR" "$XM5_SINK_MONO" || true
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
  unlink_virtual_links

  # Mic: mono into both virtual mic channels
  safe_link "$EARFUN_IN_MONO" "$VIRTUAL_MIC_FL" || true
  safe_link "$EARFUN_IN_MONO" "$VIRTUAL_MIC_FR" || true

  # Sink: mirror the existing working EarFun wiring
  safe_link "$VIRTUAL_SINK_FL" "$EARFUN_OUT_FL" || true
  safe_link "$VIRTUAL_SINK_FR" "$EARFUN_OUT_FR" || true
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


### lib/wire-mode-hfp.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
exec "${ROOT_DIR}/lib/wire-mode.sh" xm5-hfp


### lib/wire-mode-stereo.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
exec "${ROOT_DIR}/lib/wire-mode.sh" xm5-stereo


### lib/wire-mode-usb.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
exec "${ROOT_DIR}/lib/wire-mode.sh" usb


### lib/wire-mode-earfun-hfp.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
exec "${ROOT_DIR}/lib/wire-mode.sh" earfun-hfp
