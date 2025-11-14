#!/usr/bin/env bash

set -euo pipefail

DEVICE_MAC="80_99_E7_43_87_E0"  # Replace with your device MAC (underscores not colons)
DEVICE_ID="bluez_output.${DEVICE_MAC}.1"

echo "🔍 Checking Bluetooth output mode via pw-link..."

# Detect active profile based on output port pattern
if pw-link -o | grep -q "${DEVICE_ID}:monitor_MONO"; then
  MODE="hfp"
  echo "🎙 Detected: HFP (Mono + Mic)"
elif pw-link -o | grep -q "${DEVICE_ID}:monitor_FL"; then
  MODE="a2dp"
  echo "🎧 Detected: A2DP (Stereo Audio)"
else
  MODE="unknown"
  echo "⚠ Could not detect known Bluetooth mode for ${DEVICE_ID}"
fi

# Trigger mode if known
if [[ "$MODE" == "hfp" || "$MODE" == "a2dp" ]]; then
  echo "⚙ Switching to mode: $MODE"
  "$(dirname "$0")/set-mode.sh" "$MODE"
else
  echo "🚫 Not switching mode due to unknown state"
fi
