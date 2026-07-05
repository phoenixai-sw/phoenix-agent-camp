#!/usr/bin/env bash
set -euo pipefail

echo
echo "Phoenix Agent v2.0 macOS laptop awake-mode helper"
echo "Purpose: help keep local Phoenix Agent bots running while the Mac is awake."
echo
echo "Important:"
echo "- A local bot cannot run when the Mac is asleep or powered off."
echo "- Closing a MacBook lid usually triggers sleep unless macOS clamshell/power conditions allow it."
echo "- For closed-lid operation, keep the power adapter connected. External display/keyboard/mouse may be required depending on the Mac."
echo "- This helper only checks settings or applies power-adapter sleep prevention after you choose a menu."
echo

show_settings() {
  echo "== pmset custom settings =="
  pmset -g custom || true
  echo
  echo "== current sleep assertions =="
  pmset -g assertions || true
  echo
}

apply_ac_power_mode() {
  echo "Applying power-adapter awake settings."
  echo "You may be asked for your macOS password because pmset can require administrator permission."
  sudo pmset -c sleep 0 disksleep 0 displaysleep 10 powernap 1 womp 1
  echo "Applied. Current settings:"
  show_settings
}

start_temporary_keepawake() {
  echo "Starting temporary keep-awake session."
  echo "Keep this Terminal window open while you want the Mac to stay awake."
  echo "Press Ctrl+C to stop."
  caffeinate -dimsu
}

echo "Choose a menu:"
echo "1. Check current macOS sleep/power settings only"
echo "2. Apply recommended power-adapter awake mode"
echo "3. Start temporary keep-awake session with caffeinate"
echo "4. Exit"
echo
read -r -p "Enter 1, 2, 3, or 4: " choice

case "$choice" in
  1) show_settings ;;
  2) apply_ac_power_mode ;;
  3) start_temporary_keepawake ;;
  *) echo "No change applied." ;;
esac
