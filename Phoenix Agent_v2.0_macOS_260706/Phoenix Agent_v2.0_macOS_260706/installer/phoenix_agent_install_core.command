#!/usr/bin/env bash
# Phoenix package release: v2.0_260706
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/phoenix_agent_oauth_helpers.sh"

BOT_NAME="${PHOENIX_BOT_NAME:?PHOENIX_BOT_NAME missing}"
DISPLAY_NAME="${PHOENIX_DISPLAY_NAME:-$BOT_NAME Bot}"
PM2_NAME="pw_${BOT_NAME}_bot"
WORKDIR="$HOME/antigravity/openclaw/${BOT_NAME}_bot"
PROFILE="$PM2_NAME"
PORT="$(next_port)"
AGENT_AUTH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/2. 인증키_에이전트 모델 인증 키 모음"
AUTH_MODE_RAW="${PHOENIX_MODEL_AUTH_MODE:-${PHOENIX_AUTH_MODE:-openai}}"
AUTH_MODE="$(printf '%s' "$AUTH_MODE_RAW" | tr '[:upper:]' '[:lower:]')"
case "$AUTH_MODE" in
  gemini|google|google-gemini|gemini-selected) AUTH_MODE="gemini" ;;
  *) AUTH_MODE="openai" ;;
esac
GEMINI_MODEL="gemini-2.5-flash"
for model_file in "$SCRIPT_DIR/gemini_model.txt" "$AGENT_AUTH_DIR/gemini_model.txt"; do
  if [[ -s "$model_file" ]]; then
    GEMINI_MODEL="$(tr -d '\r\n' < "$model_file")"
    break
  fi
done
[[ -n "$GEMINI_MODEL" ]] || GEMINI_MODEL="gemini-2.5-flash"
if [[ "$AUTH_MODE" == "gemini" ]]; then
  MODEL="google/$GEMINI_MODEL"
else
  MODEL="openai/gpt-5.5"
fi

env_value() {
  for name in "$@"; do
    local value="${!name:-}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 0
}

telegram_configured() {
  local profile="$1"
  local out
  out="$(openclaw channels list --profile "$profile" 2>&1 || true)"
  [[ "$out" =~ [Tt]elegram && ! "$out" =~ no\ configured\ chat\ channels ]]
}

install_codex_harness_plugin() {
  local profile="$1"
  echo "  Installing/verifying Codex harness plugin for profile: $profile"
  openclaw --profile "$profile" plugins install "clawhub:@openclaw/codex" >/dev/null 2>&1 || true
  local out
  out="$(openclaw --profile "$profile" plugins list 2>/dev/null || true)"
  if echo "$out" | grep -Eiq '@openclaw/codex|codex'; then
    echo "  OK: Codex harness plugin present."
  else
    echo "  WARNING: Codex harness plugin was not confirmed. If Telegram replies 'Something went wrong', run: openclaw --profile $profile plugins install clawhub:@openclaw/codex" >&2
  fi
}

check_runtime_logs() {
  local logfile="$WORKDIR/logs/error.log"
  if [[ -f "$logfile" ]] && grep -Eiq 'Something went wrong|Requested agent harness|401|403|Missing API key|oauth|auth' "$logfile"; then
    echo "  WARNING: runtime log contains auth/harness/model errors. Inspect without printing secrets: $logfile" >&2
  fi
}

probe_gateway_operator_scope() {
  local profile="$1"
  local out
  out="$(openclaw --profile "$profile" gateway probe --json 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    echo "  WARNING: Gateway probe did not return JSON. If Telegram replies are invisible, approve pairing and rerun updater." >&2
    return 0
  fi
  PHX_GATEWAY_PROBE="$out" node <<'NODE'
const raw = process.env.PHX_GATEWAY_PROBE || "";
try {
  const data = JSON.parse(raw);
  const text = JSON.stringify(data);
  const hasRead = /operator\.read/.test(text);
  const hasWrite = /operator\.write/.test(text);
  const writeCapable = /write_capable/.test(text) || (hasRead && hasWrite);
  if (writeCapable) {
    console.log("  OK: Gateway probe write capability confirmed.");
  } else {
    console.log("  WARNING: Gateway probe did not confirm operator.read/operator.write yet. If Telegram replies are not visible, approve the pairing code and rerun updater.");
  }
} catch {
  console.log("  WARNING: Gateway probe JSON parse failed. Secret values were not printed.");
}
NODE
}

register_telegram_channel() {
  local profile="$1" token="$2"
  openclaw channels add --channel telegram --token "$token" --profile "$profile" >/dev/null
  sleep 1
  if ! telegram_configured "$profile"; then
    echo "  Telegram channel was not fully configured. Re-registering once..."
    openclaw channels remove --channel telegram --delete --profile "$profile" >/dev/null 2>&1 || true
    sleep 1
    openclaw channels add --channel telegram --token "$token" --profile "$profile" >/dev/null
  fi
  if ! telegram_configured "$profile"; then
    echo "ERROR: Telegram channel registration did not become configured." >&2
    echo "Rerun: openclaw channels add --channel telegram --token <TOKEN> --profile $profile" >&2
    exit 1
  fi
  openclaw channels status --profile "$profile" --deep >/dev/null 2>&1 || true
}

show_telegram_setup_flow() {
  echo
  echo "Telegram setup and pairing order"
  echo "  1. In Telegram, open BotFather, create this bot, and copy the Bot Token."
  echo "  2. Run this installer after moving the filled telegram_access_token.txt into the installer folder. The value is received from the file and never printed."
  echo "  3. Move the filled telegram_chat_id.txt into the installer folder before running. The value is received from the file and never printed."
  echo "  4. The installer registers Telegram in OpenClaw with the bot token."
  echo "  5. In Telegram, send /start to this bot first. Telegram allows proactive bot messages only after the user has messaged the bot."
  echo "  6. Send a short message to the bot. If a pairing code appears, fill telegram_pairing_code.txt with only that code and move it into the installer folder."
  echo "  7. Approve the pairing code from telegram_pairing_code.txt with: bash ./approve_pairing_code.command <bot>"
  echo "  8. After pairing, PM2 and the gateway become live; the bot wakes up."
  echo "  9. The bot sends a ready-complete message to telegram_chat_id.txt when health is live."
  echo " 10. After the ready message, send /new, wait 10-20 seconds, then send a short status-check message."
}
send_telegram_ready_notice() {
  local token="$1" chat_id="$2" bot_id="$3" display_name="$4" port="$5"
  [[ -n "$token" && -n "$chat_id" ]] || return 1
  local template_base64 template text payload
  template_base64="7KO87J2464uYLCB7MH0g7KSA67mEIOyZhOujjOyeheuLiOuLpC4KUE0yOiB7MX0KR2F0ZXdheTogaHR0cDovLzEyNy4wLjAuMTp7Mn0vaGVhbHRoCuydtOygnCBUZWxlZ3JhbeyXkOyEnCAvbmV3IO2bhCAxMH4yMOy0iCDrkqQg7IOB7YOcIO2ZleyduCDrqZTsi5zsp4Drpbwg67O064K07IWU64+EIOuQqeuLiOuLpC4="
  template="$(printf '%s' "$template_base64" | base64 --decode 2>/dev/null || printf '%s' "$template_base64" | base64 -D)"
  text="${template//\{0\}/$display_name}"
  text="${text//\{1\}/$bot_id}"
  text="${text//\{2\}/$port}"
  payload="$(node -e 'process.stdout.write(JSON.stringify({chat_id: process.argv[1], text: process.argv[2]}))' "$chat_id" "$text")"
  if curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary "$payload" >/dev/null 2>&1; then
    echo "  OK: Telegram ready notice sent."
    return 0
  else
    echo "  WARNING: Telegram ready notice failed. Make sure the user has messaged this bot at least once." >&2
    return 1
  fi
}

write_proactive_state() {
  local ready_notice_at="${1:-}"
  PHX_WORKDIR="$WORKDIR" \
  PHX_BOT_NAME="$BOT_NAME" \
  PHX_DISPLAY_NAME="$DISPLAY_NAME" \
  PHX_PM2_NAME="$PM2_NAME" \
  PHX_READY_NOTICE_AT="$ready_notice_at" \
  node <<'NODE'
const fs = require('fs');
const path = require('path');
const workdir = process.env.PHX_WORKDIR;
const stateDir = path.join(workdir, '.openclaw');
const statePath = path.join(stateDir, 'phoenix_proactive_state.json');
let existing = {};
try { existing = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch (_) {}
const now = new Date().toISOString();
const readyNoticeAt = process.env.PHX_READY_NOTICE_AT || existing.readyNoticeAt || null;
const state = {
  version: 1,
  botName: process.env.PHX_BOT_NAME,
  displayName: process.env.PHX_DISPLAY_NAME,
  pm2Profile: process.env.PHX_PM2_NAME,
  initializedAt: existing.initializedAt || now,
  readyNoticeAt,
  firstUserMessageAfterReadyAt: existing.firstUserMessageAfterReadyAt || null,
  lastUserMessageAt: existing.lastUserMessageAt || null,
  proactiveSends: Array.isArray(existing.proactiveSends) ? existing.proactiveSends : [],
  settings: {
    idleHours: 3,
    readyStartDelayMinutes: 30,
    dailyMaxProactiveMessages: 10,
    trendDigestDailyMax: 1,
    trendDigestHour: 7,
    skillLearningGuidanceDailyMax: 1,
    skillLearningGuidanceHour: 8,
    skillWorkOfferDailyMax: 1,
    skillWorkOfferDelayMinutes: 120,
    skillUpgradeRequestDailyMax: 1,
    skillUpgradeRequestHour: 17,
    heartbeatEvery: '30m',
    timezone: 'Asia/Seoul'
  }
};
fs.mkdirSync(stateDir, { recursive: true });
fs.writeFileSync(statePath, JSON.stringify(state, null, 2) + '\n');
NODE
}

install_v19_skillup_structure() {
  local bot="$1" display="$2" workdir="$3" pm2_name="$4"
  PHX_ROOT="$ROOT" PHX_BOT="$bot" PHX_DISPLAY="$display" PHX_WORKDIR="$workdir" PHX_PM2="$pm2_name" node <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.env.PHX_ROOT;
const bot = process.env.PHX_BOT;
const display = process.env.PHX_DISPLAY;
const workdir = process.env.PHX_WORKDIR;
function write(file, text) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text.replace(/\r\n/g, '\n') + (text.endsWith('\n') ? '' : '\n'), 'utf8'); }
function read(file) { try { return fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''); } catch (_) { return ''; } }
function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function upsert(file, start, end, body, title) { const block = start + '\n' + body.trim() + '\n' + end; let text = read(file) || (title + '\n'); const re = new RegExp(esc(start) + '[\\s\\S]*?' + esc(end)); text = re.test(text) ? text.replace(re, block) : text.trimEnd() + '\n\n' + block + '\n'; write(file, text); }
const common = path.join(root, 'phoenix_v20');
const bots = ['genesis','power','design','video','writer'];
for (const base of ['skill_creator_prompts','record_replay_guides','skill_candidates','approved_skills','rejected_skills']) { for (const b of bots) fs.mkdirSync(path.join(common, base, b), { recursive: true }); }
for (const d of ['.agents/skills','.phoenix_v20/skill_candidates','.phoenix_v20/approved_skills','.phoenix_v20/rejected_skills']) fs.mkdirSync(path.join(workdir, d), { recursive: true });
write(path.join(common, 'README_v19_SKILLUP.md'), "# Phoenix Agent v2.0 PCS/PTS Skill-Up\n\nPhoenix Agent v2.0 keeps the existing Phoenix runtime features and adds two approved skill-up paths.\n\n- PCS (Phoenix Copy Skill): screen-and-workflow based skill-up. Use it when the user can demonstrate an actual workflow, screen sequence, click/input order, upload/download path, folder operation, tool operation, or repeated business process. The result must be a reusable skill candidate with skills, examples, and checklist updates.\n- PTS (Phoenix Talk Skill): example-and-standard based skill-up. Use it when the user provides strong samples, manuscripts, reports, scripts, prompts, checklists, tone/style rules, or quality criteria. The result must extract reusable reasoning patterns, output structures, style rules, quality bars, prohibited patterns, and prompt examples.\n\nA good PCS/PTS candidate must include:\n- target bot and skill name\n- source material or demonstrated workflow\n- required inputs and expected output format\n- success criteria and quality checklist\n- failure cases, prohibited behavior, and sensitive-information cautions\n- exact proposed changes for skills, examples, and checklist\n\nSafety rules:\n- Bots may suggest skill candidates, but they must not self-install or self-edit approved skill files.\n- Master approval is required before anything moves into .agents/skills.\n- Secrets, Telegram tokens, API keys, OAuth files, and raw .env values must never be copied into skill files.\n");
write(path.join(common, 'skillup_policy.json'), JSON.stringify({ release:'Phoenix Agent v2.0', pcs:{name:'Phoenix Copy Skill', officialFeature:'Codex Record & Replay', primaryRecordingOs:'macOS', windowsPolicy:'PTS or reviewed import only'}, pts:{name:'Phoenix Talk Skill', officialFeature:'Codex Skill Creator', supportedOs:['Windows','macOS']}, approval:{botsCanSuggest:true, masterApprovalRequired:true, directSelfModification:false}, safety:['never copy secrets into skills','preserve outputs/logs/auth','use updater for approved shared changes'] }, null, 2));
const queue = path.join(common, 'skillup_approval_queue.json'); if (!fs.existsSync(queue)) write(queue, '[]');
write(path.join(workdir, '.phoenix_v20/skill_candidates/README.md'), '# ' + display + ' v2.0 Skill Candidates\n\nUse this folder for skill ideas proposed by the bot. A candidate is not active until the master approves it and it is installed into .agents/skills.\n\nRecommended candidate format:\n1. Skill name\n2. Problem it solves\n3. Input examples\n4. Output examples\n5. Checklist\n6. Files to update\n7. Safety notes\n');
write(path.join(workdir, '.phoenix_v20/approved_skills/README.md'), '# Approved v2.0 Skills\n\nApproved skills wait here before being installed into .agents/skills.\n');
write(path.join(workdir, '.phoenix_v20/rejected_skills/README.md'), '# Rejected v2.0 Skill Ideas\n\nRejected or deferred ideas are kept here for review history.\n');
write(path.join(common, 'skill_creator_prompts', bot, 'README.md'), '# ' + display + ' PTS prompt notes\n\nStore Skill Creator prompt drafts for this bot here. Do not store secrets.\n');
write(path.join(common, 'record_replay_guides', bot, 'README.md'), '# ' + display + ' PCS notes\n\nStore reviewed Record & Replay notes here. macOS recording is the primary official PCS path. Do not store secrets.\n');
const block = "## Phoenix Agent v2.0 PCS/PTS Skill-Up\n\nThis bot is part of Phoenix Agent v2.0.\n\nPCS (Phoenix Copy Skill): a screen-and-workflow based skill-up path. Use it when the user can demonstrate the actual workflow, screen sequence, click/input order, upload/download path, folder operation, tool operation, or repeated business process. The bot must convert the observed flow into a reusable skill candidate, not merely summarize it. A PCS candidate must include the target bot, skill name, demonstrated workflow, screen checkpoints, required inputs, expected output format, success criteria, failure/exception cases, sensitive-information cautions, and concrete skills/examples/checklist updates.\n\nPTS (Phoenix Talk Skill): an example-and-standard based skill-up path. Use it when the user provides strong samples, manuscripts, reports, scripts, prompts, checklists, tone/style rules, or quality criteria. The bot must extract the reasoning pattern, structure, style, quality bar, prohibited patterns, and reusable prompts from the sample. A PTS candidate must include the target bot, skill name, sample characteristics, desired output format, style rules, structure order, quality checklist, bad-output patterns, prohibited behaviors, and concrete skills/examples/checklist updates.\n\nHow to respond when asked for PCS/PTS consultation:\n- First explain whether PCS, PTS, or a mixed approach is more suitable.\n- Ask for missing materials before producing a final skill candidate.\n- Produce a candidate that an external AI or Codex Skill Creator can understand without prior context.\n- Separate the proposed changes into skills, examples, and checklist.\n- State exactly which files should be updated after master approval.\n\nOperating rule:\n- Propose skill candidates in .phoenix_v20/skill_candidates.\n- Keep approved candidates in .phoenix_v20/approved_skills until the master approves installation.\n- Install active Codex skills only under .agents/skills after approval.\n- Never place tokens, API keys, OAuth credentials, raw .env values, or private chat ids inside skills.";
upsert(path.join(workdir, 'IDENTITY.md'), '<!-- PHOENIX_v19_PCS_PTS_START -->', '<!-- PHOENIX_v19_PCS_PTS_END -->', block, '# ' + display + ' Identity');
upsert(path.join(workdir, 'AGENTS.md'), '<!-- PHOENIX_v19_PCS_PTS_START -->', '<!-- PHOENIX_v19_PCS_PTS_END -->', block, '# ' + display + ' Agent Guide');
upsert(path.join(workdir, 'SOUL.md'), '<!-- PHOENIX_v19_PCS_PTS_START -->', '<!-- PHOENIX_v19_PCS_PTS_END -->', block, '# ' + display + ' SOUL');
upsert(path.join(workdir, 'USER.md'), '<!-- PHOENIX_v19_PCS_PTS_START -->', '<!-- PHOENIX_v19_PCS_PTS_END -->', block, '# USER');
upsert(path.join(workdir, 'HEARTBEAT.md'), '<!-- PHOENIX_v19_PCS_PTS_START -->', '<!-- PHOENIX_v19_PCS_PTS_END -->', block, '# HEARTBEAT');
upsert(path.join(workdir, 'skills/SKILL.md'), '<!-- PHOENIX_v19_PCS_PTS_START -->', '<!-- PHOENIX_v19_PCS_PTS_END -->', block, '# Skills');
console.log('  OK ' + display + ': Phoenix Agent v2.0 PCS/PTS skill-up structure installed.');
NODE
}
install_v20_web_control_structure() {
  local bot="$1" display="$2" workdir="$3" profile="$4"
  mkdir -p "$workdir/phoenix_v20" "$workdir/shared_v3_protocols" "$workdir/agent_web_repo_map" "$workdir/.phoenix_v20/web_control" "$workdir/.phoenix_v20/playwright_mcp_notes" "$workdir/.phoenix_v20/outputs_delivery" "$workdir/skills"

  local source_root="${SCRIPT_DIR:-$(pwd)}"
  for f in bot_task_protocol.md github_repo_map.md delivery_policy.md approval_policy.md; do
    if [[ -f "$source_root/shared_v3_protocols/$f" ]]; then
      cp "$source_root/shared_v3_protocols/$f" "$workdir/shared_v3_protocols/$f"
    fi
  done

  case "$bot" in
    genesis) skill_file="genesis_orchestration_skills/SKILL.md" ;;
    design) skill_file="design_web_control_skills/SKILL.md" ;;
    writer) skill_file="writer_web_control_skills/SKILL.md" ;;
    video) skill_file="video_web_control_skills/SKILL.md" ;;
    power) skill_file="power_web_control_skills/SKILL.md" ;;
    *) skill_file="" ;;
  esac
  if [[ -n "$skill_file" && -f "$source_root/$skill_file" ]]; then
    cp "$source_root/$skill_file" "$workdir/phoenix_v20/${bot}_web_control_skill.md"
  fi

  cat > "$workdir/agent_web_repo_map/github_repos.md" <<'EOF_V20_REPOS'
# Phoenix Agent v2.0 Agent Web Repo Map

- phoenix pages: https://github.com/phoenixai-sw/phoenix-detail-page.git
- phoenix images: https://github.com/phoenixai-sw/mock-up-image.git
- phoenix dental: https://github.com/phoenixai-sw/phoenixai_dentala.git
- phoenix command: https://github.com/phoenixai-sw/phoenix-command.git
- phoenix slides: https://github.com/phoenixai-sw/phoenix-slides.git
- phoenix webs: https://github.com/phoenixai-sw/phoenix-webs.git
- phoenix books: https://github.com/phoenixai-sw/phoenix-books.git
- phoenix videos: https://github.com/phoenixai-sw/phoenix-videos.git
- phoenix reports: https://github.com/phoenixai-sw/phoenix-reports.git
- phoenix tax: https://github.com/phoenixai-sw/phoenix-tax.git
- phoenix marketing: https://github.com/phoenixai-sw/phoenix-marketing.git
EOF_V20_REPOS

  cat > "$workdir/.phoenix_v20/web_control/README.md" <<EOF_V20_README
# Phoenix Agent v2.0 Web Control Agent

Bot: $display
Profile: $profile

This bot preserves v1.9 features and adds v2.0 web control operation.
Use Playwright MCP/data-testid based web control when operating Phoenix agent webs.
Default output destination is local outputs. Ask before Telegram transfer.
EOF_V20_README

  local marker='<!-- PHOENIX_v20_WEB_CONTROL_START -->'
  local block="<!-- PHOENIX_v20_WEB_CONTROL_START -->
## Phoenix Agent v2.0 Web Control Agent
- v2.0 keeps v1.9 auth, PM2, proactive, PCS/PTS, outputs, and laptop operation rules.
- v2.0 adds Playwright MCP based control of Phoenix agent web services.
- Use agent web login separately for each web service.
- Save results to local outputs first; ask before Telegram delivery.
- Master approval is required before paid credits, video generation, external deploy, tax/dental consultation delivery, project deletion, or multi-web execution.
- After v2.0 is stable, recommend v2.2 Master Builder Agent for approved skill improvement.
<!-- PHOENIX_v20_WEB_CONTROL_END -->"
  for f in IDENTITY.md AGENTS.md SOUL.md USER.md HEARTBEAT.md skills/SKILL.md; do
    local p="$workdir/$f"
    mkdir -p "$(dirname "$p")"
    [[ -f "$p" ]] || touch "$p"
    if ! grep -Fq "$marker" "$p"; then
      printf '\n%s\n' "$block" >> "$p"
    fi
  done
}
configure_proactive_heartbeat() {
  local config_path="$1" chat_id="$2"
  [[ -n "$chat_id" ]] || return 0
  PHX_OPENCLAW_CONFIG="$config_path" PHX_READY_CHAT_ID="$chat_id" node <<'NODE'
const fs = require('fs');
const path = require('path');
const file = process.env.PHX_OPENCLAW_CONFIG;
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) {}
if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) cfg = {};
if (!cfg.agents || typeof cfg.agents !== 'object' || Array.isArray(cfg.agents)) cfg.agents = {};
if (!cfg.agents.defaults || typeof cfg.agents.defaults !== 'object' || Array.isArray(cfg.agents.defaults)) cfg.agents.defaults = {};
delete cfg.agents.defaults.heartbeat;
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n');
NODE
}

model_auth_file_value() {
  local file="$1" path
  for path in "$SCRIPT_DIR/$file" "$AGENT_AUTH_DIR/$file"; do
    if [[ -f "$path" ]]; then
      tr -d '\r\n' < "$path"
      return 0
    fi
  done
  return 0
}

gemini_api_key_available() {
  [[ -n "$(model_auth_file_value gemini_api_key.txt)" ]]
}

write_gemini_openclaw_config() {
  local profile_dir="$1" port="$2" model="$3"
  local gateway_token=""
  if command -v openssl >/dev/null 2>&1; then
    gateway_token="$(openssl rand -hex 32 2>/dev/null || true)"
  fi
  if [[ -z "$gateway_token" ]] && command -v node >/dev/null 2>&1; then
    gateway_token="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' 2>/dev/null || true)"
  fi
  [[ -n "$gateway_token" ]] || gateway_token="phoenix-local-gateway-token-$(date +%s)"
  mkdir -p "$profile_dir"
  cat > "$profile_dir/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "port": $port, "auth": { "mode": "token", "token": "$gateway_token" } },
  "agents": {
    "defaults": {
      "model": { "primary": "google/$model" }
    }
  }
}
JSON
}

fix_gateway_auth_token() {
  local config_path="$1"
  [[ -f "$config_path" ]] || return 0
  PHX_OPENCLAW_CONFIG="$config_path" node <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const file = process.env.PHX_OPENCLAW_CONFIG;
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); } catch (_) {}
if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) cfg = {};
if (!cfg.gateway || typeof cfg.gateway !== 'object' || Array.isArray(cfg.gateway)) cfg.gateway = {};
if (!cfg.gateway.auth || typeof cfg.gateway.auth !== 'object' || Array.isArray(cfg.gateway.auth)) {
  cfg.gateway.auth = { mode: 'token', token: crypto.randomBytes(32).toString('hex') };
} else {
  cfg.gateway.auth.mode = cfg.gateway.auth.mode || 'token';
  cfg.gateway.auth.token = cfg.gateway.auth.token || crypto.randomBytes(32).toString('hex');
}
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n');
NODE
}

install_proactive_nudge_runner() {
  local src="$SCRIPT_DIR/phoenix_proactive_nudge.cjs"
  local root="$HOME/antigravity/openclaw"
  local dest="$root/Phoenix_Proactive_Nudge.cjs"
  if [[ ! -f "$src" ]]; then
    echo "  WARNING: phoenix_proactive_nudge.cjs missing; proactive nudge runner was not installed." >&2
    return 0
  fi
  mkdir -p "$root"
  cp "$src" "$dest"
  pm2 delete phoenix_proactive_nudge >/dev/null 2>&1 || true
  pm2 start "$dest" --name phoenix_proactive_nudge >/dev/null
  echo "  OK: Phoenix proactive nudge runner installed in PM2."
}

install_ready_notice_script() {
  local src="$SCRIPT_DIR/Phoenix_Ready_Notice.command"
  local root="$HOME/antigravity/openclaw"
  local dest="$root/Phoenix_Ready_Notice.command"
  if [[ ! -f "$src" ]]; then
    echo "  WARNING: Phoenix_Ready_Notice.command missing; reboot ready notice helper was not installed." >&2
    return 0
  fi
  mkdir -p "$root"
  cp "$src" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  bash -n "$dest"
  echo "  OK: Reboot ready notice helper installed."
}

install_launch_agent() {
  local root="$HOME/antigravity/openclaw"
  local ready="$root/Phoenix_Ready_Notice.command"
  local agent_dir="$HOME/Library/LaunchAgents"
  local plist="$agent_dir/ai.openclaw.phoenix.pm2.plist"
  mkdir -p "$agent_dir"

  PHX_PLIST="$plist" PHX_READY="$ready" node <<'NODE'
const fs = require("fs");
const plist = process.env.PHX_PLIST;
const ready = process.env.PHX_READY;
function xml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
function sh(s) {
  return String(s).replace(/"/g, '\\"');
}
const readyQuoted = sh(ready);
const command = `pm2 resurrect >/tmp/phoenix_pm2_resurrect.log 2>&1; sleep 20; if [ -f "${readyQuoted}" ]; then bash "${readyQuoted}" >>/tmp/phoenix_ready_notice.log 2>&1; fi`;
const body = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.phoenix.pm2</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${xml(command)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/phoenix_pm2_launchagent.out</string>
  <key>StandardErrorPath</key>
  <string>/tmp/phoenix_pm2_launchagent.err</string>
</dict>
</plist>
`;
fs.writeFileSync(plist, body, "utf8");
NODE

  launchctl unload "$plist" >/dev/null 2>&1 || true
  launchctl load "$plist" >/dev/null 2>&1 || true
  echo "  OK: macOS login auto-start registered: ai.openclaw.phoenix.pm2.plist"
}

repair_auth_order_v17() {
  local bot_name="$1"
  local src="$SCRIPT_DIR/phoenix_v20_auth_order_repair.cjs"
  if [[ ! -f "$src" ]]; then
    echo "  WARNING: auth order repair payload missing; skipping auth order repair." >&2
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "  WARNING: node command not found; skipping auth order repair." >&2
    return 0
  fi
  if ! node "$src" --bot "$bot_name"; then
    echo "  WARNING: auth order repair could not find a valid Codex ChatGPT login profile yet." >&2
  fi
}

ensure_codex_cli_first_auth() {
  if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: Codex CLI command is not available after runtime setup. Reopen this coding agent terminal or reinstall Codex CLI, then rerun this installer." >&2
    exit 1
  fi
  echo
  echo "Codex CLI First Auth Policy"
  echo "  Conversation auth uses OpenAI provider with Codex-imported ChatGPT OAuth: openai/gpt-5.5."
  if codex_cli_logged_in; then
    echo "  OK: Codex CLI ChatGPT login detected. It will be imported into the OpenAI provider for this bot."
    return 0
  fi
  echo "  ACTION: Opening codex login. Approve with the ChatGPT subscription account in the browser."
  echo "  Security: OAuth credential values are not printed."
  codex login || true
  if ! codex_cli_logged_in; then
    echo "ERROR: Codex CLI ChatGPT login is still not valid. Complete codex login in this same terminal, then rerun this installer." >&2
    exit 1
  fi
  echo "  OK: Codex CLI ChatGPT login restored. Continuing OpenAI OAuth import."
}

port_owner_matches_pm2() {
  local pm2_name="$1"
  local info pm2_pid pm2_status port owner_pid
  info="$(pm2 jlist 2>/dev/null | node -e '
let s="";
process.stdin.on("data", c => s += c);
process.stdin.on("end", () => {
  let a=[];
  try { a = JSON.parse(s || "[]"); } catch {}
  const name = process.argv[1];
  const x = a.find(p => p && p.name === name) || {};
  const e = x.pm2_env || {};
  const env = e.env || {};
  console.log([Number(x.pid||0), String(e.status||""), Number(env.OPENCLAW_PORT||0)].join("|"));
});
' "$pm2_name")"
  IFS='|' read -r pm2_pid pm2_status port <<< "$info"
  if [[ -z "${port:-}" || "$port" == "0" ]]; then
    echo "  WARNING $pm2_name: gateway port owner check could not be completed." >&2
    return 0
  fi
  owner_pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
  if [[ -n "${pm2_pid:-}" && -n "${owner_pid:-}" && "$pm2_pid" != "0" && "$owner_pid" != "0" && "$pm2_pid" != "$owner_pid" ]]; then
    echo "  WARNING $pm2_name: gateway port owner PID mismatch. port=$port, pm2Pid=$pm2_pid, ownerPid=$owner_pid. Recent EADDRINUSE logs may indicate an orphan gateway process." >&2
    return 1
  fi
  echo "  OK $pm2_name: PM2 PID matches gateway port owner (port $port)."
  return 0
}
wait_gateway_health() {
  local port="$1" timeout="${2:-120}" deadline
  deadline=$((SECONDS + timeout))
  echo "Waiting for gateway health on port $port..."
  while ((SECONDS < deadline)); do
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo "  OK: Gateway health live on port $port."
      return 0
    fi
    sleep 5
  done
  echo "  WARNING: Gateway health did not become live within ${timeout}s. Check PM2 logs after OpenClaw finishes prewarm."
  return 1
}

confirm_telegram_token_owner() {
  local token="$1" display_name="$2" response info username first_name answer
  response="$(curl -fsS "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true)"
  if [[ -z "$response" ]]; then
    echo "  WARNING: Telegram getMe check failed. Continue only if telegram_access_token.txt is this bot's BotFather token."
    return 0
  fi
  info="$(PHOENIX_TG_GETME="$response" node <<'NODE'
const raw = process.env.PHOENIX_TG_GETME || '';
try {
  const data = JSON.parse(raw);
  if (data && data.ok && data.result) {
    process.stdout.write([data.result.username || '', data.result.first_name || ''].join('\t'));
  }
} catch {}
NODE
)"
  if [[ -z "$info" ]]; then
    echo "  WARNING: Telegram getMe check did not return bot identity. Check telegram_access_token.txt before continuing."
    return 0
  fi
  username="${info%%$'\t'*}"
  first_name="${info#*$'\t'}"
  echo "  Telegram token points to: @${username:-unknown} (${first_name:-unknown})"
  echo "  Confirm this is the BotFather token for $display_name, not a previous bot's token."
  read -r -p "Action: continue with this Telegram bot? [Y/n]: " answer
  if [[ "$answer" =~ ^[Nn]$ ]]; then
    echo "ERROR: Replace telegram_access_token.txt with the correct BotFather token for $display_name, then rerun." >&2
    exit 1
  fi
}

show_telegram_setup_flow() {
  echo
  echo "Telegram setup and pairing order"
  echo "  1. In Telegram, open BotFather, create this bot, and copy the Bot Token."
  echo "  2. Run this installer after moving the filled telegram_access_token.txt into the installer folder. The value is received from the file and never printed."
  echo "  3. Move the filled telegram_chat_id.txt into the installer folder before running. The value is received from the file and never printed."
  echo "  4. The installer registers Telegram in OpenClaw with the bot token."
  echo "  5. In Telegram, send /start to this bot first. Telegram allows proactive bot messages only after the user has messaged the bot."
  echo "  6. Send a short message to the bot. If a pairing code appears, fill telegram_pairing_code.txt with only that code and move it into the installer folder."
  echo "  7. Approve the pairing code from telegram_pairing_code.txt with: bash ./approve_pairing_code.command <bot>"
  echo "  8. After pairing, PM2 and the gateway become live; the bot wakes up."
  echo "  9. The bot sends a ready-complete message to telegram_chat_id.txt when health is live."
  echo " 10. After the ready message, send /new, wait 10-20 seconds, then send a short status-check message."
}

echo "Phoenix Agent v2.0 macOS installer: $DISPLAY_NAME"
echo "User decisions during automation:"
if [[ "$AUTH_MODE" == "gemini" ]]; then
  echo "  1. Conversation auth: use Gemini API as the selected authentication mode with model $GEMINI_MODEL. The API key value is never printed."
else
  echo "  1. Conversation auth: import Codex CLI ChatGPT login into OpenAI OAuth and use openai/gpt-5.5. API keys are not used for conversation billing."
fi
echo "  2. Extra API keys: use only for image/video generation features."
echo "  3. Telegram: create the bot in BotFather. Fill telegram_access_token.txt in 1. 인증키_API 키 모음, then copy/move it into installer before running."
echo "  4. Required stability notice: telegram_chat_id.txt must contain the numeric Telegram chat id. If the file is missing, the installer stops and names it."
echo "     This is an operations alarm. After the gateway health check is live, the bot sends a ready message so users know when it is safe to talk after reboot."
echo "     Telegram can send proactive ready notices only after the user has messaged the bot at least once."
echo "  5. Security: tokens, API keys, and OAuth credentials are never printed."
show_secret_file_instructions

preflight_tg="$(read_installer_text_file telegram_access_token.txt)"
if [[ -z "$preflight_tg" ]]; then
  echo "ERROR: telegram_access_token.txt was not found or is empty in the installer folder. Fill telegram_access_token.txt in 1. 인증키_API 키 모음, copy/move it into installer, then rerun. Do not paste the token into chat." >&2
  exit 1
fi
if ! valid_telegram_token "$preflight_tg"; then
  echo "ERROR: Telegram token is present but the format is invalid. Check telegram_access_token.txt." >&2
  exit 1
fi
preflight_ready_chat_id="$(read_installer_text_file telegram_chat_id.txt)"
if [[ -z "$preflight_ready_chat_id" ]]; then
  echo "ERROR: telegram_chat_id.txt was not found or is empty in the installer folder. Fill telegram_chat_id.txt in 1. 인증키_API 키 모음, copy/move it into installer, then rerun. Do not paste the chat id into chat." >&2
  exit 1
fi
if ! valid_telegram_chat_id "$preflight_ready_chat_id"; then
  echo "ERROR: telegram_chat_id.txt is present but the format is invalid. Use a numeric Telegram chat id." >&2
  exit 1
fi
echo "  OK: required Telegram files found and format checked. Values were not printed."
if [[ "$AUTH_MODE" == "gemini" ]]; then
  if ! gemini_api_key_available; then
    echo "ERROR: Gemini selected-auth install was requested, but gemini_api_key.txt was not found or is empty." >&2
    echo "Put gemini_api_key.txt in installer or in ../2. 인증키_에이전트 모델 인증 키 모음, then rerun. Do not paste the key into chat." >&2
    exit 1
  fi
  echo "  OK: Gemini API key file found for Gemini selected-auth install. Value was not printed."
  echo "  OK: Gemini model selected: $GEMINI_MODEL"
fi

ensure_base_tools
if [[ "$AUTH_MODE" == "gemini" ]]; then
  echo
  echo "Gemini Selected Auth Policy"
  echo "  Skipping Codex OAuth login because Gemini API was explicitly selected for conversation auth."
  echo "  OpenClaw config will use provider=google, model=google/$GEMINI_MODEL, with GEMINI_API_KEY/GOOGLE_API_KEY from bot .env."
else
  ensure_codex_cli_first_auth
fi

pm2 stop "$PM2_NAME" >/dev/null 2>&1 || true
pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
rm -rf "$WORKDIR" "$HOME/.openclaw-$PM2_NAME" "$HOME/.openclaw-state/$PM2_NAME"
mkdir -p "$WORKDIR/skills" "$WORKDIR/logs" "$HOME/.openclaw-$PM2_NAME"
if [[ "$AUTH_MODE" == "gemini" ]]; then
  write_gemini_openclaw_config "$HOME/.openclaw-$PM2_NAME" "$PORT" "$GEMINI_MODEL"
  if ! openclaw --profile "$PM2_NAME" config validate --json >/dev/null 2>&1; then
    echo "ERROR: Gemini OpenClaw config validation failed. Check OpenClaw version and Gemini provider schema." >&2
    exit 1
  fi
  echo "  OK: Gemini selected-auth OpenClaw config validated."
fi

echo
echo "Conversation authentication"
if [[ "$AUTH_MODE" == "gemini" ]]; then
  echo "  Gemini API is explicitly selected for bot replies."
  echo "  Installer execution tools are not treated as the preferred bot model auth."
  echo "  The bot must clearly say Gemini is active; it must not imply GPT-5.5."
  conv_line="# Conversation auth preference: Gemini API selected authentication. Do not imply GPT-5.5 when Gemini is configured."
else
  echo "  Codex CLI ChatGPT login is imported into OpenAI OAuth, then openai/gpt-5.5 is used for conversation auth."
  echo "  OpenAI API keys are not accepted for conversation billing in this user installer."
  echo "  Optional explicit fallback files: put gemini_api_key.txt, gemini_model.txt, local_llm_base_url.txt, local_llm_model.txt, local_llm_api_key.txt in the package root 2. 인증키_에이전트 모델 인증 키 모음 folder."
  echo "  Fallbacks are displayed explicitly. The bot must never imply GPT-5.5 when Gemini/local LLM is active."
  conv_line="# OPENAI_API_KEY_IMAGE is not used for Codex CLI ChatGPT conversation auth."
fi
install_codex_harness_plugin "$PM2_NAME"
if [[ "$AUTH_MODE" == "openai" ]]; then
  repair_auth_order_v17 "$BOT_NAME"
fi

extra_env=()
if [[ "$BOT_NAME" == "design" || "$BOT_NAME" == "writer" ]]; then
  echo
  echo "Optional image-generation API key for $DISPLAY_NAME"
  echo "  This key is only for gpt-image-2 high/medium/low image features, not OpenClaw conversation auth."
  image_key="$(env_value PHOENIX_IMAGE_API_KEY PHOENIX_OPENAI_API_KEY_IMAGE)"
  image_key_file=""
  if [[ -f "$SCRIPT_DIR/openai_api_key_image.txt" ]]; then
    image_key_file="openai_api_key_image.txt"
  fi
  if [[ -n "$image_key_file" ]]; then
    image_key="$(tr -d '\r\n' < "$SCRIPT_DIR/$image_key_file")"
    if [[ "$image_key" != sk-* ]]; then
      echo "ERROR: $image_key_file is present but does not look like an OpenAI API key. Put only the key value in the file." >&2
      exit 1
    fi
    echo "  OK: $image_key_file loaded into bot-local .env. Value was not printed."
    confirm_delete_installer_file "$image_key_file"
  fi
  if [[ -z "$image_key" ]]; then
    echo "  Optional openai_api_key_image.txt not found. Skipping image API key setup. To use image generation later, put the key in openai_api_key_image.txt and rerun apply_optional_api_keys.command."
  fi
  [[ -n "$image_key" ]] && extra_env+=("OPENAI_API_KEY_IMAGE=$image_key") || extra_env+=("# OPENAI_API_KEY_IMAGE=")
  extra_env+=("GPT_IMAGE_PRIMARY=gpt-image-2-high" "GPT_IMAGE_FALLBACK=gpt-image-2-medium" "GPT_IMAGE_EMERGENCY=gpt-image-2-low")
fi

if [[ "$BOT_NAME" == "video" ]]; then
  echo
  echo "Optional fal.ai video-generation API key"
  echo "  falai_api_key_video.txt is only for fal.ai video generation models, not OpenClaw conversation auth."
  echo "  Put only the fal.ai API key in falai_api_key_video.txt, with no label or extra text."
  video_key="$(env_value PHOENIX_FALAI_API_KEY_VIDEO)"
  video_key_file=""
  if [[ -f "$SCRIPT_DIR/falai_api_key_video.txt" ]]; then
    video_key_file="falai_api_key_video.txt"
  fi
  if [[ -n "$video_key_file" ]]; then
    video_key="$(tr -d '\r\n' < "$SCRIPT_DIR/$video_key_file")"
    if [[ -z "$video_key" ]]; then
      echo "ERROR: $video_key_file is empty. Put only the fal.ai API key in the file." >&2
      exit 1
    fi
    echo "  OK: $video_key_file loaded into bot-local .env as FALAI_API_KEY_VIDEO. Value was not printed."
    confirm_delete_installer_file "$video_key_file"
  fi
  if [[ -z "$video_key" ]]; then
    echo "  Optional falai_api_key_video.txt not found. Skipping fal.ai key setup. To use video generation later, put the key in falai_api_key_video.txt and rerun apply_optional_api_keys.command."
  fi
  [[ -n "$video_key" ]] && extra_env+=("FALAI_API_KEY_VIDEO=$video_key") || extra_env+=("# FALAI_API_KEY_VIDEO=")
fi

extra_env_lines() {
  if ((${#extra_env[@]})); then
    printf '%s\n' "${extra_env[@]}"
  fi
}

cat > "$WORKDIR/.env" <<EOF
BOT_ID=$PM2_NAME
BOT_NAME=$BOT_NAME
OPENCLAW_PROFILE=$PM2_NAME
OPENCLAW_PORT=$PORT
TELEGRAM_BOT_TOKEN=
TELEGRAM_READY_CHAT_ID=
$conv_line
$(extra_env_lines)
EOF

FALLBACK_STATE="$SCRIPT_DIR/phoenix_model_fallback_state.cjs"
if [[ -f "$FALLBACK_STATE" ]]; then
  fallback_out="$(PHOENIX_MODEL_AUTH_MODE="$AUTH_MODE" node "$FALLBACK_STATE" --mode install --auth-mode "$AUTH_MODE" --input-dir "$SCRIPT_DIR" --workdir "$WORKDIR" --bot "$BOT_NAME" --display "$DISPLAY_NAME" --profile "$PM2_NAME")"
  echo "  Model fallback config refreshed. Values were not printed."
  printf '%s' "$fallback_out" | node -e 'let raw="";process.stdin.on("data",c=>raw+=c);process.stdin.on("end",()=>{try{const x=JSON.parse(raw); console.log(`  Gemini configured=${x.geminiConfigured}, Local LLM configured=${x.localConfigured}`); if (Array.isArray(x.warnings) && x.warnings.length) console.log(`  WARNING: ${x.warnings.join("; ")}`);}catch{}});'
  gemini_configured="$(printf '%s' "$fallback_out" | node -e 'let raw="";process.stdin.on("data",c=>raw+=c);process.stdin.on("end",()=>{try{const x=JSON.parse(raw);process.stdout.write(x.geminiConfigured?"1":"0");}catch{process.stdout.write("0");}});')"
  local_configured="$(printf '%s' "$fallback_out" | node -e 'let raw="";process.stdin.on("data",c=>raw+=c);process.stdin.on("end",()=>{try{const x=JSON.parse(raw);process.stdout.write(x.localConfigured?"1":"0");}catch{process.stdout.write("0");}});')"
  secret_fallback_files=()
  [[ "$gemini_configured" == "1" ]] && secret_fallback_files+=("gemini_api_key.txt")
  [[ "$local_configured" == "1" ]] && secret_fallback_files+=("local_llm_api_key.txt")
  if ((${#secret_fallback_files[@]})); then
    for secret_fallback_file in "${secret_fallback_files[@]}"; do
      secret_fallback_path="$SCRIPT_DIR/$secret_fallback_file"
      if [[ -s "$secret_fallback_path" ]]; then
        read -r -p "Action: delete $secret_fallback_file from installer folder now for security? [Y/n]: " answer
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
          rm -f "$secret_fallback_path"
          echo "  OK: $secret_fallback_file deleted from installer folder. Value was not printed."
        else
          echo "  SECURITY WARNING: $secret_fallback_file remains in installer folder."
        fi
      fi
    done
  fi
  echo "  Root auth-key folder files are source templates and are not deleted by the installer."
fi

case "$BOT_NAME" in
  genesis)
    PHOENIX_ROLE="Chief-of-staff bot for multi-bot orchestration, prompt design, coding plans, landing pages, automations, and service/platform architecture."
    PHOENIX_MENU="$(cat <<'EOF_MENU'
1. Draft a command plan for all Phoenix bots
2. Build a landing page or automation brief
3. Turn an idea into a service/platform blueprint
EOF_MENU
)"
    ;;
  power)
    PHOENIX_ROLE="Planning and research lead for reports, papers, market analysis, competitor analysis, policy grants, and government project analysis."
    PHOENIX_MENU="$(cat <<'EOF_MENU'
1. Make a trend or market report
2. Compare competitors and opportunities
3. Analyze grants, RFPs, and public-sector projects
EOF_MENU
)"
    ;;
  design)
    PHOENIX_ROLE="Design lead for image generation, detail pages, web design, brand visuals, thumbnails, and PPT visuals."
    PHOENIX_MENU="$(cat <<'EOF_MENU'
1. Create image/detail-page concepts
2. Build brand visual directions
3. Draft PPT or web design layouts
EOF_MENU
)"
    ;;
  video)
    PHOENIX_ROLE="Video lead for generated video, video concepts, shorts, ad videos, storyboards, and fal.ai-based production planning."
    PHOENIX_MENU="$(cat <<'EOF_MENU'
1. Make short-form video concepts
2. Build ad/video storyboard plans
3. Prepare fal.ai generation prompts
EOF_MENU
)"
    ;;
  writer)
    PHOENIX_ROLE="Publishing lead for manuscripts, books, reports, copywriting, image lists, editing, and publication workflows."
    PHOENIX_MENU="$(cat <<'EOF_MENU'
1. Outline a manuscript or book project
2. Draft copy/report sections
3. Create editing and image-list workflows
EOF_MENU
)"
    ;;
  *)
    PHOENIX_ROLE="Phoenix bot for useful, safe, role-specific work."
    PHOENIX_MENU="$(cat <<'EOF_MENU'
1. Summarize current context
2. Propose next actions
3. Prepare a concrete work plan
EOF_MENU
)"
    ;;
esac

case "$BOT_NAME" in
  genesis)
    PHOENIX_ROLE_DETAIL="$(cat <<'EOF_DETAIL'
Korean role markers for Genesis Bot:
- 전체 봇 관리
- 작업 지시문 정리
- 서비스/플랫폼 설계
- 랜딩페이지와 자동화 프로그램 기획
- 멀티 봇 회의와 실행 순서 설계
EOF_DETAIL
)"
    ;;
  power)
    PHOENIX_ROLE_DETAIL="Korean role markers for Power Bot: 보고서, 리서치, 시장 분석, 경쟁 분석, 정부지원사업, 정책/RFP 분석."
    ;;
  design)
    PHOENIX_ROLE_DETAIL="Korean role markers for Design Bot: 상세페이지, PPT, 썸네일, 브랜드 비주얼, 이미지 생성, 웹 디자인."
    ;;
  video)
    PHOENIX_ROLE_DETAIL="Korean role markers for Video Bot: 숏폼, 광고 영상, 스토리보드, 영상 생성 프롬프트, fal.ai 기반 제작 기획."
    ;;
  writer)
    PHOENIX_ROLE_DETAIL="Korean role markers for Writer Bot: 출판 원고, 책 기획, 문체, 교정, 카피라이팅, 이미지 목록, 출판 워크플로."
    ;;
  *)
    PHOENIX_ROLE_DETAIL="Korean role markers: Phoenix Agent v2.0 role-specific operation."
    ;;
esac

PHOENIX_POLICY="$(cat <<'EOF_POLICY'
<!-- PHOENIX_PROACTIVE_TREND_POLICY_START -->
## Phoenix Proactive Nudge / Trend Suggestion

This bot uses Phoenix Proactive Nudge with these limits: idle threshold 3 hours, ready-start delay 30 minutes, at most 10 proactive messages per bot per local date, automatic trend digest once per local date after 07:00 KST with same-day catch-up, skill learning guidance once per local date after 08:00 KST with same-day catch-up, skill work offer once per local date, and trend-based skill upgrade request once per local date after 17:00 KST with same-day catch-up.

On every real user message, quietly update .openclaw/phoenix_proactive_state.json:
- lastUserMessageAt = current UTC ISO time.
- if readyNoticeAt exists and firstUserMessageAfterReadyAt is empty, set firstUserMessageAfterReadyAt.
- never record or print token/API key/OAuth credential values.

If the user asks trend-style questions such as Korean phrases meaning current trends, latest popular things, what is rising, what to try now, or idea recommendations:
- Treat it as a trend suggestion task for __DISPLAY_NAME__.
- Use current search/browsing when latest information is needed and available.
- Summarize the latest flow, then propose concrete work menus that match this bot role.
- Include immediately usable prompts, execution options, and any files/materials needed.
- Do not stop at a generic answer; lead the user toward a real next task.

Skill work offer:
- Once per local date, choose one concrete task from this bot skills or default menu.
- Ask the user for approval before starting the actual work.

Skill upgrade request:
- Once per local date after 17:00 KST, search/analyze current trends and propose one useful skill enhancement or expanded skill. If the local machine wakes later, send it once as same-day catch-up.
- Ask master approval first; never self-modify skill files without approval.

Bot role:
__PHOENIX_ROLE__

Default execution menu:
__PHOENIX_MENU__
<!-- PHOENIX_PROACTIVE_TREND_POLICY_END -->
EOF_POLICY
)"
PHOENIX_POLICY="${PHOENIX_POLICY//__DISPLAY_NAME__/$DISPLAY_NAME}"
PHOENIX_POLICY="${PHOENIX_POLICY//__PHOENIX_ROLE__/$PHOENIX_ROLE}"
PHOENIX_POLICY="${PHOENIX_POLICY//__PHOENIX_MENU__/$PHOENIX_MENU}"

if [[ "$AUTH_MODE" == "gemini" ]]; then
  PHOENIX_AUTH_DESCRIPTION="Conversation authentication preference: use Gemini API as the selected authentication mode with model google/$GEMINI_MODEL. Codex CLI, Claude Code, and Antigravity IDE are installer execution tools, not the preferred bot model authentication."
  PHOENIX_AUTH_ORDER="Authentication order: 1) explicitly configured Gemini API, 2) explicitly configured local/Open Source LLM, 3) OpenAI/Codex only if the user explicitly chooses it later."
  PHOENIX_AUTH_DISCLOSURE="Always say Gemini is active when Gemini is the provider. Never imply GPT-5.5 when Gemini is configured."
else
  PHOENIX_AUTH_DESCRIPTION="Conversation authentication: use OpenAI provider with ChatGPT OAuth imported from Codex CLI, model openai/gpt-5.5. Do not ask for or use an OpenAI API key for conversation authentication."
  PHOENIX_AUTH_ORDER="Fallback authentication order: 1) Codex CLI ChatGPT OAuth import to OpenAI provider, 2) ChatGPT subscription browser approval if Codex CLI login is missing/expired, 3) explicitly configured Gemini API fallback, 4) explicitly configured local/Open Source LLM fallback."
  PHOENIX_AUTH_DISCLOSURE="When a fallback is used or only configured as a candidate, say so clearly. Never imply GPT-5.5 when Gemini or local LLM is active."
fi

PHOENIX_IDENTITY_BLOCK="$(cat <<'EOF_IDENTITY'
<!-- PHOENIX_AGENT_IDENTITY_START -->
## Phoenix Agent Identity

You are __DISPLAY_NAME__, a Phoenix Agent v2.0 Telegram/OpenClaw bot.
PM2 profile: __PM2_NAME__
Primary role: __PHOENIX_ROLE__
Role detail:
__PHOENIX_ROLE_DETAIL__

__PHOENIX_AUTH_DESCRIPTION__
__PHOENIX_AUTH_ORDER__
__PHOENIX_AUTH_DISCLOSURE__
Feature API keys, when present, are bot-local feature keys only. Never print .env, auth files, Telegram tokens, API keys, OAuth files, or raw secret file contents.

First wake-up routine:
1. Say that you are __DISPLAY_NAME__.
2. Inspect the bot folder before acting.
3. Report what this bot can do now.
4. Report missing files or user decisions without exposing secrets.
5. Recommend one concrete next action.

Operating style:
- Be practical, concise, and action-oriented.
- Preserve user files and outputs unless the user explicitly asks to delete or overwrite them.
- Explain progress in user-facing language instead of dumping long raw commands.
- When Telegram pairing is needed, receive the pairing code through telegram_pairing_code.txt moved into installer and approve it with the helper script.

Default work menu:
__PHOENIX_MENU__
<!-- PHOENIX_AGENT_IDENTITY_END -->
EOF_IDENTITY
)"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__DISPLAY_NAME__/$DISPLAY_NAME}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PM2_NAME__/$PM2_NAME}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PHOENIX_ROLE__/$PHOENIX_ROLE}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PHOENIX_ROLE_DETAIL__/$PHOENIX_ROLE_DETAIL}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PHOENIX_MENU__/$PHOENIX_MENU}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PHOENIX_AUTH_DESCRIPTION__/$PHOENIX_AUTH_DESCRIPTION}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PHOENIX_AUTH_ORDER__/$PHOENIX_AUTH_ORDER}"
PHOENIX_IDENTITY_BLOCK="${PHOENIX_IDENTITY_BLOCK//__PHOENIX_AUTH_DISCLOSURE__/$PHOENIX_AUTH_DISCLOSURE}"

PHOENIX_USER_CONTEXT="$(cat <<'EOF_USER_CONTEXT'
<!-- PHOENIX_USER_CONTEXT_START -->
## User Operation Context

This file is for local operator preferences and handoff notes for __DISPLAY_NAME__.
The updater may refresh this marked block, but user notes outside this block should be preserved.
Do not place token/API key/OAuth credential values here.
<!-- PHOENIX_USER_CONTEXT_END -->
EOF_USER_CONTEXT
)"
PHOENIX_USER_CONTEXT="${PHOENIX_USER_CONTEXT//__DISPLAY_NAME__/$DISPLAY_NAME}"

cat > "$WORKDIR/IDENTITY.md" <<EOF
# $DISPLAY_NAME Identity

$PHOENIX_IDENTITY_BLOCK
EOF

cat > "$WORKDIR/AGENTS.md" <<EOF
# $DISPLAY_NAME Agent Guide

You are $DISPLAY_NAME.
$PHOENIX_AUTH_DESCRIPTION
$PHOENIX_AUTH_ORDER
$PHOENIX_AUTH_DISCLOSURE
Never print .env, auth files, Telegram tokens, API keys, or OAuth credential values.
When local skills run, summarize user-facing progress instead of exposing long raw commands.

First greeting format:
Hello, master. I am $DISPLAY_NAME.
After waking up, inspect this bot folder and report:
1. What you can do
2. Files already filled
3. Files or folders that still need user input
4. Warnings without exposing secrets
5. Recommended next step

$PHOENIX_IDENTITY_BLOCK

$PHOENIX_POLICY
EOF
cat > "$WORKDIR/SOUL.md" <<EOF
# $DISPLAY_NAME SOUL

$PHOENIX_IDENTITY_BLOCK
EOF
cat > "$WORKDIR/USER.md" <<EOF
# USER

$PHOENIX_USER_CONTEXT
EOF
cat > "$WORKDIR/SCHEDULE.md" <<EOF
# SCHEDULE

No scheduled tasks yet.
EOF
cat > "$WORKDIR/HEARTBEAT.md" <<EOF
# HEARTBEAT

Phoenix Proactive Nudge is enabled for $DISPLAY_NAME.

Settings:
- Heartbeat poll interval: 30m.
- Ready-start delay: 30 minutes after a recorded ready notice.
- Idle summary threshold: 3 hours after the latest real user message.
- Daily proactive notification cap: 10 messages per bot per local date, including automatic trend digest, skill learning guidance, skill work offer, and trend-based skill upgrade request.
- Skill upgrade request: at most 1 per bot per local date after 17:00 KST, based on current trend references. If the local machine wakes later, send it once as same-day catch-up.
- Telegram delivery requires that the user has already sent /start or another message to this bot.

State file:
- Read and maintain .openclaw/phoenix_proactive_state.json.
- Never store or print Telegram tokens, API keys, OAuth credentials, or raw secret file contents.
- On heartbeat, if the state file is missing or incomplete, create/fix it and notify=false.
- Do not send an idle summary until lastUserMessageAt was recorded from a real user message.
- If readyNoticeAt exists and firstUserMessageAfterReadyAt is empty, wait at least 30 minutes before one start suggestion.
- Before any non-core notify=true, count proactiveSends for today's Asia/Seoul date. If count is already 10 or more, notify=false. Core scheduled messages (trend_digest, skill_learning_guidance, skill_upgrade_request) can still send once per day so the official schedule is not blocked by earlier readiness messages.
- After notify=true, append an entry to proactiveSends with time, kind, and a short summary.

When to notify:
- ready_start_suggestion: after readyNoticeAt + 30 minutes, if no firstUserMessageAfterReadyAt exists. Send one concise message that summarizes this bot role and proposes one next action.
- idle_summary: after 3 hours of no user input, summarize recent useful progress from logs, outputs, SCHEDULE.md, or visible files. If there is no meaningful progress, suggest this bot best default next action.
- trend_digest: once per local date, proactively search current trend/news flow from the last 14 days for this bot role and send a concise work suggestion, even if the user did not ask first.
- skill_work_offer: once per local date, pick one skill-based task this bot can actually do and ask the user to approve execution.
- skill_upgrade_request: once per local date after 17:00 KST, search/analyze current trends and ask the master to approve one skill enhancement or expanded skill for a future updater. If the local machine wakes later, send it once as same-day catch-up.

Bot role:
$PHOENIX_ROLE

Suggested menu:
$PHOENIX_MENU

Heartbeat reply rule:
- Use heartbeat_respond.
- Set notify=false when nothing genuinely useful should interrupt the user.
- Set notify=true only for one concise Telegram-ready message.
EOF
cat > "$WORKDIR/skills/SKILL.md" <<EOF
# Skills

Add bot-specific skills here. Restart with: pm2 restart $PM2_NAME --update-env

$PHOENIX_POLICY

$PHOENIX_IDENTITY_BLOCK
EOF
install_v19_skillup_structure "$BOT_NAME" "$DISPLAY_NAME" "$WORKDIR" "$PM2_NAME"
install_v20_web_control_structure "$BOT_NAME" "$DISPLAY_NAME" "$WORKDIR" "$PM2_NAME"
write_proactive_state ""

audit_identity_quality() {
  local missing=0
  local files=("$WORKDIR/IDENTITY.md" "$WORKDIR/AGENTS.md" "$WORKDIR/SOUL.md" "$WORKDIR/HEARTBEAT.md" "$WORKDIR/skills/SKILL.md")
  local required=()
  if [[ "$BOT_NAME" == "genesis" ]]; then
    required+=("전체 봇 관리" "작업 지시문 정리" "서비스/플랫폼 설계" "랜딩페이지" "자동화 프로그램")
  fi
  if [[ "$AUTH_MODE" == "gemini" ]]; then
    required+=("Gemini API")
  fi
  if ((${#required[@]})); then
    for phrase in "${required[@]}"; do
      if ! grep -R -- "$phrase" "${files[@]}" >/dev/null 2>&1; then
        echo "ERROR: Identity quality audit missing required phrase marker: $phrase" >&2
        missing=1
      fi
    done
  fi
  if [[ "$missing" == "1" ]]; then
    echo "Identity files exist but do not contain required bot/auth role markers. Installation stopped before final success report." >&2
    exit 1
  fi
  echo "  OK: Identity quality audit passed for $DISPLAY_NAME."
}
audit_identity_quality

echo
echo "Telegram connection"
show_telegram_setup_flow
tg_from_file=0
tg="$(read_installer_text_file telegram_access_token.txt)"
if [[ -n "$tg" ]]; then
  tg_from_file=1
  echo "  OK: telegram_access_token.txt loaded into bot-local .env. Value was not printed."
else
  tg="$(env_value PHOENIX_TELEGRAM_TOKEN)"
fi
if [[ -z "$tg" ]]; then
  echo "ERROR: telegram_access_token.txt was not found or is empty in the installer folder. Fill telegram_access_token.txt in 1. 인증키_API 키 모음, copy/move it into installer, then rerun. Do not paste the token into chat." >&2
  exit 1
fi
if [[ -n "$tg" ]] && ! valid_telegram_token "$tg"; then
  echo "ERROR: Telegram token is present but the format is invalid. Check telegram_access_token.txt." >&2
  exit 1
fi
confirm_telegram_token_owner "$tg" "$DISPLAY_NAME"
if [[ "$tg_from_file" == "1" && -f "$SCRIPT_DIR/telegram_access_token.txt" ]]; then
  confirm_delete_installer_file telegram_access_token.txt
fi

ready_chat_id=""
ready_chat_id_from_file=0
if [[ -n "$tg" ]]; then
  ready_chat_id="$(read_installer_text_file telegram_chat_id.txt)"
fi
if [[ -n "$ready_chat_id" ]]; then
  ready_chat_id_from_file=1
  if ! valid_telegram_chat_id "$ready_chat_id"; then
    echo "ERROR: telegram_chat_id.txt is present but the format is invalid. Use a numeric Telegram chat id." >&2
    exit 1
  fi
  echo "  OK: telegram_chat_id.txt loaded into bot-local .env. Value was not printed."
else
  ready_chat_id="$(env_value PHOENIX_TELEGRAM_CHAT_ID PHOENIX_READY_CHAT_ID)"
  if [[ -n "$ready_chat_id" ]] && ! valid_telegram_chat_id "$ready_chat_id"; then
    echo "ERROR: PHOENIX_TELEGRAM_CHAT_ID is present but the format is invalid." >&2
    exit 1
  fi
fi
if [[ -z "$ready_chat_id" ]]; then
  echo "ERROR: telegram_chat_id.txt was not found or is empty in the installer folder. Fill telegram_chat_id.txt in 1. 인증키_API 키 모음, copy/move it into installer, then rerun. Do not paste the chat id into chat." >&2
  exit 1
fi
if [[ "$ready_chat_id_from_file" == "1" && -f "$SCRIPT_DIR/telegram_chat_id.txt" ]]; then
  confirm_delete_installer_file telegram_chat_id.txt
fi

perl -0pi -e "s/TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$tg/" "$WORKDIR/.env"
perl -0pi -e "s/TELEGRAM_READY_CHAT_ID=.*/TELEGRAM_READY_CHAT_ID=$ready_chat_id/" "$WORKDIR/.env"
register_telegram_channel "$PM2_NAME" "$tg"
echo "  OK: Telegram channel registered. Token value was not printed."

OPENCLAW_BIN="$(command -v openclaw)"
cat > "$WORKDIR/ecosystem.config.js" <<EOF
const fs = require("fs");
const path = require("path");
function readEnvFile(file) {
  const env = {};
  if (!fs.existsSync(file)) return env;
  for (const rawLine of fs.readFileSync(file, "utf8").split(/\\r?\\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx === -1) continue;
    env[line.slice(0, idx)] = line.slice(idx + 1);
  }
  return env;
}
const localEnv = readEnvFile(path.join(__dirname, ".env"));
module.exports = {
  apps: [{
    name: "$PM2_NAME",
    cwd: "$WORKDIR",
    script: "/bin/bash",
    args: ["-lc", "exec \"$OPENCLAW_BIN\" --profile \"$PM2_NAME\" gateway run --port \"$PORT\" --force --verbose"],
    env: {
      ...localEnv,
      OPENCLAW_PROFILE: "$PM2_NAME",
      OPENCLAW_PORT: "$PORT",
      CODEX_HOME: "$HOME/.openclaw-$PM2_NAME/agents/main/agent/codex-home",
      TERM: "xterm-256color"
    },
    out_file: path.join(__dirname, "logs", "out.log"),
    error_file: path.join(__dirname, "logs", "error.log")
  }]
};
EOF

openclaw --profile "$PM2_NAME" config set gateway.port "$PORT" --strict-json >/dev/null 2>&1 || true
fix_gateway_auth_token "$HOME/.openclaw-$PM2_NAME/openclaw.json"
configure_proactive_heartbeat "$HOME/.openclaw-$PM2_NAME/openclaw.json" "$ready_chat_id"
pm2 start "$WORKDIR/ecosystem.config.js" --only "$PM2_NAME" --update-env
port_owner_matches_pm2 "$PM2_NAME" || true
install_proactive_nudge_runner
install_ready_notice_script
install_launch_agent
pm2 save >/dev/null 2>&1 || true
if wait_gateway_health "$PORT" 120; then
  probe_gateway_operator_scope "$PM2_NAME"
  if [[ -n "${tg:-}" && -n "${ready_chat_id:-}" ]] && send_telegram_ready_notice "$tg" "$ready_chat_id" "$PM2_NAME" "$DISPLAY_NAME" "$PORT"; then
    write_proactive_state "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
else
  true
fi
check_runtime_logs

pairing_status="not-provided"
if [[ -s "$SCRIPT_DIR/telegram_pairing_code.txt" ]]; then
  echo "  Pairing code file found in installer folder. Approving without printing the code..."
  if PHOENIX_AUTO_DELETE_PAIRING_FILE=1 bash "$SCRIPT_DIR/approve_pairing_code.command" "$BOT_NAME"; then
    pairing_status="yes"
  else
    pairing_status="failed"
    echo "  WARNING: Pairing approval failed. Telegram may still require manual approval with approve_pairing_code.command." >&2
  fi
fi

echo
echo "Installation complete."
echo "PM2: $PM2_NAME"
echo "Profile: $HOME/.openclaw-$PM2_NAME"
echo "Workdir: $WORKDIR"
echo "Port: $PORT"
echo "Model: $MODEL"
echo "Pairing code approved: $pairing_status"
echo "Telegram next steps:"
echo "1. In Telegram, send /start to this bot first."
echo "2. If Telegram sends a pairing code, put only the code in telegram_pairing_code.txt, then run:"
echo "   bash ./approve_pairing_code.command $BOT_NAME"
echo "3. Wait for the ready-complete Telegram notice from this bot."
echo "4. After the ready notice, send /new, wait 10-20 seconds, then send a short status-check message."
