#!/usr/bin/env bash
# Phoenix package release: v1.9
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOT_NAME="${1:-}"

case "$BOT_NAME" in
  genesis|power|design|video|writer) ;;
  *)
    echo "Usage: bash ./approve_pairing_code.command <genesis|power|design|video|writer>" >&2
    exit 1
    ;;
esac

pairing_file="$SCRIPT_DIR/telegram_pairing_code.txt"
if [[ ! -f "$pairing_file" ]]; then
  echo "ERROR: telegram_pairing_code.txt was not found in the installer folder. Put only the Telegram pairing code in that file." >&2
  exit 1
fi

pairing_code="$(tr -d '\r\n ' < "$pairing_file")"
if [[ ! "$pairing_code" =~ ^[A-Za-z0-9_-]{4,32}$ ]]; then
  echo "ERROR: telegram_pairing_code.txt format looks invalid. Put only the pairing code on one line, with no label or extra text." >&2
  exit 1
fi

profile="pw_${BOT_NAME}_bot"
echo "Approving Telegram pairing from telegram_pairing_code.txt for $profile. The code value will not be printed."
openclaw --profile "$profile" pairing approve telegram "$pairing_code"

if [[ "${PHOENIX_AUTO_DELETE_PAIRING_FILE:-}" == "1" ]]; then
  rm -f "$pairing_file"
  echo "  OK: telegram_pairing_code.txt deleted from installer folder."
  exit 0
fi

read -r -p "Action: delete telegram_pairing_code.txt from installer folder now for security? [Y/n]: " answer
if [[ ! "$answer" =~ ^[Nn]$ ]]; then
  rm -f "$pairing_file"
  echo "  OK: telegram_pairing_code.txt deleted from installer folder."
else
  echo "  SECURITY WARNING: telegram_pairing_code.txt remains in the installer folder."
fi
