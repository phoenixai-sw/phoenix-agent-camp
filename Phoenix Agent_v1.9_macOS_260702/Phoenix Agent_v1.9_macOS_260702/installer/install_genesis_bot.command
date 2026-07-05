#!/usr/bin/env bash
# Phoenix package release: v1.9
set -euo pipefail
AUTH_MODE_ARG="${PHOENIX_MODEL_AUTH_MODE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth|--auth-mode)
      shift
      AUTH_MODE_ARG="${1:-}"
      ;;
    --gemini)
      AUTH_MODE_ARG="gemini"
      ;;
    --openai)
      AUTH_MODE_ARG="openai"
      ;;
  esac
  shift || true
done
if [[ -n "$AUTH_MODE_ARG" ]]; then
  export PHOENIX_MODEL_AUTH_MODE="$AUTH_MODE_ARG"
fi
PHOENIX_BOT_NAME="genesis" PHOENIX_DISPLAY_NAME="Genesis Bot" bash "$(dirname "$0")/phoenix_agent_install_core.command"