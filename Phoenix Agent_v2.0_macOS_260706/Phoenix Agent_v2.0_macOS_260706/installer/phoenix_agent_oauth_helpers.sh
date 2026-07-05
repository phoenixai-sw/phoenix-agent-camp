#!/usr/bin/env bash
# Phoenix package release: v2.0_260706
set -euo pipefail

ensure_command() {
  local cmd="$1" pkg="${2:-}" label="${3:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  OK: $label"
    return 0
  fi
  if [[ -n "$pkg" ]]; then
    echo "  Installing $label..."
    npm install -g "$pkg"
  fi
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $label is not available after install attempt." >&2
    return 1
  }
  echo "  OK: $label"
}

ensure_codex_cli_safe() {
  local pkg="$1"
  if command -v codex >/dev/null 2>&1; then
    echo "  OK: OpenAI Codex CLI found. Skipping Codex CLI npm update to avoid replacing a running Codex process."
    return 0
  fi
  echo "  Installing OpenAI Codex CLI because codex command is missing..."
  npm install -g "$pkg"
  ensure_command codex "" "OpenAI Codex CLI"
}

ensure_base_tools() {
  echo "Phoenix Agent v2.0 macOS base tool check (latest runtime with verification)"
  ensure_command node "" "Node.js"
  ensure_command npm "" "npm"
  ensure_command git "" "Git"
  echo "  Installing matched Phoenix runtime packages..."
  npm install -g openclaw@latest @openclaw/codex@latest clawhub@latest pm2@latest
  patch_openclaw_mac_telegram_plain_text || true
  ensure_codex_cli_safe "@openai/codex@latest"
  ensure_command openclaw "" "OpenClaw"
  ensure_command clawhub "" "clawhub"
  ensure_command pm2 "" "PM2"
}

patch_openclaw_mac_telegram_plain_text() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  command -v npm >/dev/null 2>&1 || return 0

  local npm_root target
  npm_root="$(npm root -g 2>/dev/null || true)"
  [[ -n "$npm_root" ]] || return 0
  target="$npm_root/openclaw/dist/send-DsQJjhVA.js"
  if [[ ! -f "$target" ]]; then
    target="$(find "$npm_root/openclaw/dist" -maxdepth 1 -type f -name '*.js' -print 2>/dev/null | while IFS= read -r f; do
      if grep -q 'sendRichMessage' "$f" && grep -q 'chunk.text' "$f"; then
        printf '%s\n' "$f"
        break
      fi
    done)"
  fi
  if [[ -z "$target" || ! -f "$target" ]]; then
    echo "  WARNING: OpenClaw Telegram text delivery file was not found; Mac Telegram plain-text patch skipped." >&2
    return 0
  fi

  PHX_OPENCLAW_SEND_FILE="$target" node <<'NODE'
const fs = require("fs");
const file = process.env.PHX_OPENCLAW_SEND_FILE;
let text = fs.readFileSync(file, "utf8");
if (text.includes("api.sendMessage(chatId, chunk.text, richParams)")) {
  console.log("  OK: Mac Telegram plain-text compatibility patch already present.");
  process.exit(0);
}
const before = text;
text = text.replace(
  /result:\s*await requestWithChatNotFound\(\(\)\s*=>\s*richRawApi\.sendRichMessage\(\{\s*chat_id:\s*chatId,\s*[\s\S]*?text:\s*chunk\.text[\s\S]*?\}\)\s*,\s*"message"\s*\)/m,
  'result: await requestWithChatNotFound(() => api.sendMessage(chatId, chunk.text, richParams), "message")'
);
if (text === before) {
  console.error("  WARNING: Mac Telegram plain-text patch pattern was not found; OpenClaw may have changed its delivery bundle.");
  process.exit(0);
}
const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
fs.copyFileSync(file, `${file}.phoenix_plain_backup_${stamp}`);
fs.writeFileSync(file, text, "utf8");
console.log("  OK: Mac Telegram plain-text compatibility patch applied. Token values were not printed.");
NODE
  node --check "$target" >/dev/null
}

valid_telegram_token() {
  [[ "${1:-}" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]]
}

valid_telegram_chat_id() {
  [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

read_installer_text_file() {
  local file="$1"
  local path="$SCRIPT_DIR/$file"
  [[ -f "$path" ]] || return 0
  tr -d '\r\n' < "$path"
}

confirm_delete_installer_file() {
  local file="$1"
  local path="$SCRIPT_DIR/$file"
  local answer
  [[ -f "$path" ]] || return 0
  read -r -p "Action: delete $file from installer folder now for security? [Y/n]: " answer
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    rm -f "$path"
    echo "  OK: $file deleted from installer folder."
  else
    echo "  SECURITY WARNING: $file remains in the installer folder."
    echo "  Delete $path manually after installation if you do not need to keep it."
  fi
}

show_secret_file_instructions() {
  echo
  echo "Installer input rules"
  echo "  Run the installer once. If a required value file is missing, the installer stops and tells you which one-line file is missing."
  echo "  Sensitive values are received through one-line text files. Token/API key/OAuth credential values are never printed."
  echo "  Fill Telegram/image/video one-line files in the package root input template folder, then copy/move only filled files into the installer folder before running:"
  echo "    telegram_access_token.txt : Telegram BotFather token for this bot."
  echo "    telegram_chat_id.txt          : Telegram numeric chat id for ready/proactive messages."
  echo "    openai_api_key_image.txt   : optional image-generation key for Design/Writer."
  echo "    falai_api_key_video.txt      : optional fal.ai key for Video."
  echo "  Put Gemini/local LLM fallback files only in the package root 2. 인증키_에이전트 모델 인증 키 모음 folder:"
  echo "    gemini_api_key.txt, gemini_model.txt, local_llm_base_url.txt, local_llm_model.txt, local_llm_api_key.txt"
  echo "    Telegram pairing code: after Telegram shows a pairing code, fill telegram_pairing_code.txt in the input folder, move it into installer, and approve it with the helper."
  echo "  If a source file is used successfully, the installer asks whether to delete it for security."
}

next_port() {
  local port=18790
  while lsof -PiTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; do
    port=$((port + 1))
  done
  printf "%s" "$port"
}

preferred_openai_profile_id() {
  local profile="$1"
  openclaw --profile "$profile" models status --json 2>/dev/null | node -e '
let s=""; process.stdin.on("data", d => s += d);
process.stdin.on("end", () => {
  try {
    const j = JSON.parse(s);
    for (const p of (((j.auth || {}).oauth || {}).profiles || [])) {
      if (p && p.provider === "openai" && String(p.profileId || "").startsWith("openai:")) {
        console.log(p.profileId);
        return;
      }
    }
  } catch {}
});
' || true
}

set_openai_auth_order() {
  local profile="$1" profile_id="$2"
  [[ -n "$profile_id" ]] || return 1
  openclaw --profile "$profile" models auth order set --provider openai "$profile_id" >/dev/null 2>&1 || true
  echo "  OK: OpenAI OAuth auth order pinned for $profile"
}

codex_cli_logged_in() {
  command -v codex >/dev/null 2>&1 || return 1
  local out
  out="$(codex login status 2>&1 || true)"
  printf '%s\n' "$out" | grep -Eiq 'logged in|authenticated|chatgpt' || return 1
  printf '%s\n' "$out" | grep -Eiq 'not logged|not authenticated' && return 1
  return 0
}

sync_chatgpt_oauth() {
  local profile="$1" model="$2"
  mkdir -p "$HOME/.openclaw-$profile"
  cat > "$HOME/.openclaw-$profile/openclaw.json" <<JSON
{
  "gateway": { "mode": "local" },
  "agents": {
    "defaults": {
      "model": { "primary": "$model" },
      "models": { "openai/gpt-5.5": {} }
    }
  },
  "models": {
    "providers": {
      "openai": {
        "auth": "oauth",
        "models": [
          { "id": "gpt-5.5", "name": "gpt-5.5", "api": "openai-chatgpt-responses" }
        ]
      }
    }
  },
  "auth": {
    "profiles": {},
    "order": {}
  }
}
JSON
  if ! codex_cli_logged_in; then
    echo "Action: complete ChatGPT login in the browser when prompted."
    codex login || true
  fi
  openclaw --profile "$profile" plugins registry --refresh --json >/dev/null 2>&1 || true
  openclaw --profile "$profile" plugins install clawhub:@openclaw/codex --force >/dev/null 2>&1 || openclaw --profile "$profile" plugins install clawhub:@openclaw/codex >/dev/null 2>&1 || true
  openclaw --profile "$profile" migrate codex --from "$HOME/.codex" --include-secrets --yes --no-backup --force --json >/dev/null 2>&1 || openclaw --profile "$profile" migrate codex --from "$HOME/.codex" --include-secrets --yes --json >/dev/null 2>&1 || true
  if ! codex_cli_logged_in; then
    echo "ERROR: Codex CLI ChatGPT login is not confirmed yet. Run: codex login" >&2
    return 1
  fi
  local profile_id
  profile_id="$(preferred_openai_profile_id "$profile")"
  set_openai_auth_order "$profile" "$profile_id" || true
}
