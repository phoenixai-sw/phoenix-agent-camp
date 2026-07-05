#!/usr/bin/env bash
# Phoenix package release: v1.9
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$HOME/antigravity/openclaw"

upsert_env() {
  local env_file="$1" key="$2" value="$3"
  PHOENIX_ENV_FILE="$env_file" PHOENIX_ENV_KEY="$key" PHOENIX_ENV_VALUE="$value" node <<'NODE'
const fs = require('fs');
const file = process.env.PHOENIX_ENV_FILE;
const key = process.env.PHOENIX_ENV_KEY;
const value = process.env.PHOENIX_ENV_VALUE || '';
let lines = [];
try {
  lines = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/);
} catch {}
let found = false;
lines = lines.filter((line, index) => !(index === lines.length - 1 && line === '')).map((line) => {
  if (line === key || line.startsWith(`${key}=`) || line.startsWith(`# ${key}=`) || line.startsWith(`#${key}=`)) {
    found = true;
    return `${key}=${value}`;
  }
  return line;
});
if (!found) lines.push(`${key}=${value}`);
fs.writeFileSync(file, lines.join('\n') + '\n', 'utf8');
NODE
}

confirm_delete() {
  local file="$1" answer
  [[ -f "$file" ]] || return 0
  read -r -p "Action: delete $(basename "$file") from installer folder now for security? [Y/n]: " answer
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    rm -f "$file"
    echo "  OK: $(basename "$file") deleted from installer folder."
  else
    echo "  SECURITY WARNING: $(basename "$file") remains in the installer folder."
  fi
}

restart_bot() {
  local pm2_name="$1"
  if command -v pm2 >/dev/null 2>&1; then
    pm2 restart "$pm2_name" --update-env >/dev/null 2>&1 || true
  fi
}

changed=0
image_file=""
if [[ -f "$SCRIPT_DIR/openai_api_key_image.txt" ]]; then
  image_file="$SCRIPT_DIR/openai_api_key_image.txt"
fi
if [[ -f "$image_file" ]]; then
  image_key="$(tr -d '\r\n' < "$image_file")"
  [[ "$image_key" == sk-* ]] || { echo "ERROR: $(basename "$image_file") does not look like an OpenAI API key." >&2; exit 1; }
  for bot in design writer; do
    env_file="$WORKSPACE/${bot}_bot/.env"
    [[ -f "$env_file" ]] || continue
    upsert_env "$env_file" OPENAI_API_KEY_IMAGE "$image_key"
    upsert_env "$env_file" GPT_IMAGE_PRIMARY gpt-image-2-high
    upsert_env "$env_file" GPT_IMAGE_FALLBACK gpt-image-2-medium
    upsert_env "$env_file" GPT_IMAGE_EMERGENCY gpt-image-2-low
    restart_bot "pw_${bot}_bot"
    echo "  OK: $(basename "$image_file") applied to ${bot}_bot .env. Value was not printed."
    changed=1
  done
  confirm_delete "$image_file"
fi

video_file=""
if [[ -f "$SCRIPT_DIR/falai_api_key_video.txt" ]]; then
  video_file="$SCRIPT_DIR/falai_api_key_video.txt"
fi
if [[ -n "$video_file" ]]; then
  video_key="$(tr -d '\r\n' < "$video_file")"
  [[ -n "$video_key" ]] || { echo "ERROR: $(basename "$video_file") is empty." >&2; exit 1; }
  env_file="$WORKSPACE/video_bot/.env"
  if [[ -f "$env_file" ]]; then
    upsert_env "$env_file" FALAI_API_KEY_VIDEO "$video_key"
    restart_bot pw_video_bot
    echo "  OK: $(basename "$video_file") applied to video_bot .env as FALAI_API_KEY_VIDEO. Value was not printed."
    changed=1
  fi
  confirm_delete "$video_file"
fi

if ((changed)); then
  pm2 save >/dev/null 2>&1 || true
  echo "Optional API key apply complete. Check PM2/gateway health after OpenClaw finishes prewarm."
else
  echo "No installed target bot found, or no openai_api_key_image.txt / falai_api_key_video.txt was present."
fi
