#!/usr/bin/env bash
# Phoenix package release: v2.0_260706
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOT=""
AUTH_MODE_ARG="${PHOENIX_MODEL_AUTH_MODE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bot)
      BOT="${2:-}"
      shift 2
      ;;
    --auth|--auth-mode)
      shift
      AUTH_MODE_ARG="${1:-}"
      shift
      ;;
    --gemini)
      AUTH_MODE_ARG="gemini"
      shift
      ;;
    --openai)
      AUTH_MODE_ARG="openai"
      shift
      ;;
    genesis|power|design|video|writer)
      BOT="$1"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

bot_label() {
  case "$1" in
    genesis) echo "Genesis Bot - command center, service design, coding prompts" ;;
    power)   echo "Power Bot   - reports, research, market/trend analysis" ;;
    design)  echo "Design Bot  - images, landing pages, thumbnails, PPT visuals" ;;
    video)   echo "Video Bot   - video concepts, short-form, fal.ai generation" ;;
    writer)  echo "Writer Bot  - manuscripts, publishing, copywriting, editing" ;;
    *)       echo "" ;;
  esac
}

if [[ -z "$BOT" ]]; then
  echo ""
  echo "Phoenix Agent v2.0 Installer"
  echo "Choose one bot to install. Run this installer once per bot."
  echo ""
  echo "Before install:"
  echo "  - Put this bot's Telegram BotFather token in telegram_access_token.txt before running."
  echo "  - Put the numeric Telegram chat id in telegram_chat_id.txt before running."
  echo "  - If either required file is missing, the installer stops and names the missing file."
  echo "  - Optional: the installer asks whether to add image/video API keys only for bots that use them."
  echo "  - Default conversation auth is OpenAI/Codex. To choose Gemini API, run this installer with --auth gemini."
  echo "  - Secret values are never printed."
  echo ""
  echo "Install options:"
  echo "  [1] $(bot_label genesis)"
  echo "  [2] $(bot_label power)"
  echo "  [3] $(bot_label design)"
  echo "  [4] $(bot_label video)"
  echo "  [5] $(bot_label writer)"
  echo "  [Q] Cancel"
  read -r -p "Type 1, 2, 3, 4, 5, or Q, then press Enter: " choice
  case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
    1|genesis) BOT="genesis" ;;
    2|power) BOT="power" ;;
    3|design) BOT="design" ;;
    4|video) BOT="video" ;;
    5|writer) BOT="writer" ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

TARGET="$SCRIPT_DIR/install_${BOT}_bot.command"
if [[ ! -f "$TARGET" ]]; then
  echo "Bot installer not found: $TARGET" >&2
  exit 1
fi

echo ""
echo "Starting Phoenix Agent v2.0 installer: $(bot_label "$BOT")"
chmod +x "$TARGET" 2>/dev/null || true
if [[ -n "$AUTH_MODE_ARG" ]]; then
  exec bash "$TARGET" --auth "$AUTH_MODE_ARG"
else
  exec bash "$TARGET"
fi
