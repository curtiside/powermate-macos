#!/bin/sh
# karabiner-block-volume.sh — make Karabiner-Elements swallow a device's HID
# volume up/down/mute events.
#
# Why you'd want this: some devices (notably Bluetooth headset dongles — Jabra,
# Poly, etc.) send HID volume-down/up events when they enter "call mode." macOS
# applies those to your CURRENT DEFAULT OUTPUT device — not the headset — so your
# desk speakers jump in volume (and their DAC often clicks) every time you join or
# leave a call. Their physical volume buttons hit the wrong device for the same
# reason. This blocks that device's volume events so they stop moving your output.
#
# It (1) writes a Karabiner complex-modification rule, (2) enables it in your
# active profile, and (3) sets the device to be "modified" by Karabiner.
#
# Find your device's vendor/product IDs (decimal) with:
#   ./build/powermate --list          # shows hex and decimal
#   or Karabiner-Elements > EventViewer (Devices tab)
#
# Usage:  karabiner-block-volume.sh <VENDOR_ID> <PRODUCT_ID> ["Label"]
# Example (Jabra Link 390):  karabiner-block-volume.sh 2830 11856 "Jabra Link 390"
#
# Note: this does NOT affect a PowerMate/knob volume tool — that drives the audio
# API directly, not HID volume keys. Your keyboard volume keys also keep working
# (Apple keyboards use vendor-specific HID codes, not the consumer ones blocked here).
set -e

VID="$1"; PID="$2"; LABEL="${3:-device $1/$2}"
[ -n "$VID" ] && [ -n "$PID" ] || {
  echo "usage: $0 <vendor_id> <product_id> [\"label\"]   (decimal IDs; see 'powermate --list')" >&2
  exit 2
}

KDIR="$HOME/.config/karabiner"
KJSON="$KDIR/karabiner.json"
ASSETS="$KDIR/assets/complex_modifications"
DESC="Ignore volume keys from $LABEL ($VID/$PID)"

command -v jq >/dev/null 2>&1 || { echo "This needs jq:  brew install jq" >&2; exit 1; }
[ -f "$KJSON" ] || { echo "Karabiner-Elements not set up yet ($KJSON missing). Install & launch it first." >&2; exit 1; }
mkdir -p "$ASSETS"

RULE=$(jq -n --argjson vid "$VID" --argjson pid "$PID" --arg desc "$DESC" '
{
  description: $desc,
  manipulators: (["volume_decrement","volume_increment","mute"] | map({
    type: "basic",
    from: { consumer_key_code: ., modifiers: { optional: ["any"] } },
    to: [ { key_code: "vk_none" } ],
    conditions: [ { type: "device_if", identifiers: [ { vendor_id: $vid, product_id: $pid } ] } ]
  }))
}')

jq -n --arg desc "$DESC" --argjson rule "$RULE" '{ title: $desc, rules: [ $rule ] }' \
  > "$ASSETS/block-volume-$VID-$PID.json"
echo "Wrote rule: $ASSETS/block-volume-$VID-$PID.json"

cp "$KJSON" "$KJSON.bak.$$"
tmp="$(mktemp)"
jq --argjson rule "$RULE" --argjson vid "$VID" --argjson pid "$PID" '
  . as $root
  | (($root.profiles | map(.selected) | index(true)) // 0) as $pi
  | .profiles[$pi].complex_modifications.rules =
      (((.profiles[$pi].complex_modifications.rules) // [])
       | if (map(.description) | index($rule.description)) == null then . + [ $rule ] else . end)
  | .profiles[$pi].devices =
      (((.profiles[$pi].devices) // [])
       | if any(.identifiers.vendor_id == $vid and .identifiers.product_id == $pid)
         then map(if (.identifiers.vendor_id == $vid and .identifiers.product_id == $pid) then (.ignore = false) else . end)
         else . + [ { identifiers: { vendor_id: $vid, product_id: $pid }, ignore: false } ]
         end)
' "$KJSON" > "$tmp"

if jq empty "$tmp" >/dev/null 2>&1; then
  mv "$tmp" "$KJSON"
  echo "Enabled the rule and set \"$LABEL\" to be modified (backup: $KJSON.bak.$$)."
else
  rm -f "$tmp"
  echo "Could not safely patch $KJSON — left unchanged; enable the rule via Karabiner > Complex Modifications > Add rule." >&2
fi

echo
echo "If the volume changes persist, open Karabiner > Settings > Devices and make"
echo "sure \"$LABEL\" has 'Modify events' checked — Karabiner won't seize some"
echo "non-keyboard devices without that toggle."
