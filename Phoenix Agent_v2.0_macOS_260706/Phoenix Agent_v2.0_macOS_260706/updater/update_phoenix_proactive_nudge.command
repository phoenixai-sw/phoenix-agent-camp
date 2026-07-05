#!/usr/bin/env bash
# Phoenix updater release: v2.0_260706
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HOME/antigravity/openclaw"
PHOENIX_RELEASE_VERSION="v2.0_260706"
PHOENIX_SUPPORTED_UPGRADE_FROM="v1.6,v1.7,v1.7_260619,v1.7_260626,v1.8,v1.8_260625,v1.9,v1.9_260702"
SRC="$SCRIPT_DIR/phoenix_proactive_nudge.cjs"
DEST="$ROOT/Phoenix_Proactive_Nudge.cjs"
REPAIR_SRC="$SCRIPT_DIR/phoenix_v20_auth_order_repair.cjs"
READY_SRC="$SCRIPT_DIR/Phoenix_Ready_Notice.command"
READY_DEST="$ROOT/Phoenix_Ready_Notice.command"
FALLBACK_SRC="$SCRIPT_DIR/phoenix_model_fallback_state.cjs"
BOT_NAME="${1:-all}"
BOT_NAME="$(printf '%s' "$BOT_NAME" | tr '[:upper:]' '[:lower:]')"
case "$BOT_NAME" in
  all|genesis|power|design|video|writer) ;;
  *)
    echo "ERROR: Unknown bot name: $BOT_NAME" >&2
    echo "Use one of: all, genesis, power, design, video, writer" >&2
    exit 1
    ;;
esac

echo "Phoenix Proactive Nudge updater $PHOENIX_RELEASE_VERSION - macOS"
echo "This is an updater, not a reinstall. Existing bots, auth, tokens, outputs, and logs are preserved."
echo "This updater preserves existing bots, refreshes the proactive runner, and upgrades v1.6/v1.7/v1.8 installs to Phoenix Agent v2.0 with PCS/PTS skill-up structure. v1.5 users should use cleaner then installer."
echo "Update target bot: $BOT_NAME"
echo "Security: token/API Key/OAuth credential values are never printed."

ensure_runtime() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm command not found. Install Node.js LTS, reopen the Codex/Antigravity terminal, then rerun this updater." >&2
    exit 1
  fi
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  for bin_dir in "$npm_prefix/bin" "$npm_prefix" /opt/homebrew/bin /usr/local/bin; do
    if [[ -n "$bin_dir" && -d "$bin_dir" ]]; then
      case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) PATH="$bin_dir:$PATH" ;;
      esac
    fi
  done
  export PATH
  missing=()
  for cmd in node pm2 openclaw clawhub; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ! command -v codex >/dev/null 2>&1; then
    missing+=("codex")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    echo "[runtime] Missing command(s): ${missing[*]}"
    echo "[runtime] Reinstalling/verifying Phoenix runtime packages with npm. Secret values are not printed."
    npm install -g openclaw@latest @openclaw/codex@latest clawhub@latest pm2@latest @openai/codex@latest --loglevel=error
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    for bin_dir in "$npm_prefix/bin" "$npm_prefix" /opt/homebrew/bin /usr/local/bin; do
      if [[ -n "$bin_dir" && -d "$bin_dir" ]]; then
        case ":$PATH:" in
          *":$bin_dir:"*) ;;
          *) PATH="$bin_dir:$PATH" ;;
        esac
      fi
    done
    export PATH
  fi
  for cmd in node pm2 openclaw; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: $cmd command is still missing after runtime repair. Reopen the terminal or reinstall Node.js LTS, then rerun this updater." >&2
      exit 1
    fi
  done
  patch_openclaw_mac_telegram_plain_text || true
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

codex_login_ok() {
  local status
  status="$(codex login status 2>&1 || true)"
  if printf '%s' "$status" | grep -Eiq 'logged in|authenticated|chatgpt' && ! printf '%s' "$status" | grep -Eiq 'not logged|not authenticated|logged out'; then
    echo "  Codex CLI ChatGPT login: detected"
    return 0
  fi
  echo "  WARNING: Codex CLI ChatGPT login was not detected." >&2
  echo "  If model replies fail, run 'codex login' in this same Codex/Antigravity terminal, then rerun this updater so OpenAI OAuth can be imported." >&2
  return 1
}

ensure_codex_cli_first_auth() {
  if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: Codex CLI command is not available after runtime repair. Reopen this coding agent terminal or reinstall Codex CLI, then rerun this updater." >&2
    exit 1
  fi
  echo "  Codex CLI First Auth Policy: checking current ChatGPT login before OpenAI OAuth import."
  if codex_login_ok; then
    echo "  OK: Codex CLI login detected. It will be imported into the OpenAI provider for Phoenix bots."
    return 0
  fi
  echo "  ACTION: Opening codex login. Approve with the ChatGPT subscription account in the browser."
  echo "  Security: OAuth credential values are not printed."
  codex login || true
  if ! codex_login_ok; then
    echo "ERROR: Codex CLI ChatGPT login is still not valid. Complete codex login in this same terminal, then rerun this updater." >&2
    exit 1
  fi
  echo "  OK: Codex CLI ChatGPT login restored and ready for OpenAI OAuth import."
}

work_dir_for_bot() {
  printf '%s/antigravity/openclaw/%s_bot' "$HOME" "$1"
}

pm2_name_for_bot() {
  case "$1" in
    genesis) printf '%s' "pw_genesis_bot" ;;
    power) printf '%s' "pw_power_bot" ;;
    design) printf '%s' "pw_design_bot" ;;
    video) printf '%s' "pw_video_bot" ;;
    writer) printf '%s' "pw_writer_bot" ;;
    *) printf '%s' "" ;;
  esac
}

display_name_for_bot() {
  case "$1" in
    genesis) printf '%s' "Genesis Bot" ;;
    power) printf '%s' "Power Bot" ;;
    design) printf '%s' "Design Bot" ;;
    video) printf '%s' "Video Bot" ;;
    writer) printf '%s' "Writer Bot" ;;
    *) printf '%s Bot' "$1" ;;
  esac
}

profile_dir_for_bot() {
  printf '%s/.openclaw-pw_%s_bot' "$HOME" "$1"
}

legacy_profile_dir_for_bot() {
  printf '%s/.openclaw-pw_%s' "$HOME" "$1"
}

auth_mode_for_bot() {
  local env_file value
  env_file="$(work_dir_for_bot "$1")/.env"
  if [[ -f "$env_file" ]]; then
    value="$(grep -E '^PHOENIX_MODEL_AUTH_MODE=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]' | tr -d '\r' || true)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  printf '%s' "openai"
}

write_release_marker() {
  local bots_json
  bots_json="$(printf '%s\n' "${INSTALLED_TARGET_BOTS[@]}" | node -e 'const fs=require("fs"); const bots=fs.readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean); process.stdout.write(JSON.stringify(bots));')"
  node - "$ROOT" "$PHOENIX_RELEASE_VERSION" "$PHOENIX_SUPPORTED_UPGRADE_FROM" "$bots_json" <<'NODE'
const fs = require("fs");
const path = require("path");
const [root, releaseVersion, supportedRaw, botsRaw] = process.argv.slice(2);
const bots = JSON.parse(botsRaw || "[]");
const marker = {
  releaseVersion,
  updaterPackageDate: "260706",
  supportedUpgradeFrom: supportedRaw.split(",").filter(Boolean),
  appliedAt: new Date().toISOString(),
  bots,
  preserves: ["Telegram token/chat id", "model auth mode", "OAuth/API key values", "outputs", "logs"],
  updaterRole: "preserve existing installs and upgrade v1.6/v1.7/v1.7_260619/v1.7_260626/v1.8/v1.8_260625/v1.9/v1.9_260702 to v2.0_260706 Web Control Agent with PCS/PTS preserved"
};
function writeJson(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(marker, null, 2) + "\n", "utf8");
}
writeJson(path.join(root, "PHOENIX_AGENT_RELEASE.json"));
for (const bot of bots) {
  const dir = path.join(root, `${bot}_bot`);
  if (fs.existsSync(dir)) writeJson(path.join(dir, "PHOENIX_AGENT_RELEASE.json"));
}
NODE
  echo "  Release marker written: $PHOENIX_RELEASE_VERSION. Upgrade sources accepted: $PHOENIX_SUPPORTED_UPGRADE_FROM"
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
test_installed_target() {
  case "$BOT_NAME" in
    all) bots=(genesis power design video writer) ;;
    *) bots=("$BOT_NAME") ;;
  esac
  INSTALLED_TARGET_BOTS=()
  for bot in "${bots[@]}"; do
    if [[ -d "$(work_dir_for_bot "$bot")" || -d "$(profile_dir_for_bot "$bot")" || -d "$(legacy_profile_dir_for_bot "$bot")" ]]; then
      INSTALLED_TARGET_BOTS+=("$bot")
    fi
  done
  if [[ "${#INSTALLED_TARGET_BOTS[@]}" -eq 0 ]]; then
    echo "ERROR: No installed Phoenix bot work folder/profile was found for target '$BOT_NAME'." >&2
    echo "If the previous install failed or you are in the wrong macOS user account, use the v2.0 installer instead of the updater. v1.5 users should clean reinstall with the v1.9 cleaner and installer." >&2
    exit 1
  fi
}

disable_internal_telegram_heartbeat() {
  echo
  echo "[2c/5] Disabling internal OpenClaw Telegram heartbeat"
  local bot profile updated
  for bot in "${INSTALLED_TARGET_BOTS[@]}"; do
    updated=0
    for profile in "$(profile_dir_for_bot "$bot")" "$(legacy_profile_dir_for_bot "$bot")"; do
      [[ -f "$profile/openclaw.json" ]] || continue
      if PHX_OPENCLAW_CONFIG="$profile/openclaw.json" node <<'NODE'
const fs = require('fs');
const file = process.env.PHX_OPENCLAW_CONFIG;
let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
} catch (_) {
  process.exit(1);
}
if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) cfg = {};
if (!cfg.agents || typeof cfg.agents !== 'object' || Array.isArray(cfg.agents)) cfg.agents = {};
if (!cfg.agents.defaults || typeof cfg.agents.defaults !== 'object' || Array.isArray(cfg.agents.defaults)) cfg.agents.defaults = {};
delete cfg.agents.defaults.heartbeat;
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
NODE
      then
        updated=1
      else
        echo "  WARN $bot: openclaw.json heartbeat update failed; rerun updater after checking profile JSON." >&2
      fi
    done
    if [[ "$updated" -eq 1 ]]; then
      echo "  OK $bot: internal heartbeat disabled; external proactive runner remains active"
    else
      echo "  WARN $bot: profile openclaw.json not found for heartbeat update" >&2
    fi
  done
}

audit_v19_feature_upgrade() {
  local required_files=(
    "IDENTITY.md"
    "AGENTS.md"
    "SOUL.md"
    "USER.md"
    "HEARTBEAT.md"
    "skills/SKILL.md"
  )
  local required_markers=(
    "ready_start_suggestion"
    "idle_summary"
    "trend_digest"
    "skill_learning_guidance"
    "skill_work_offer"
    "skill_upgrade_request"
  )
  local all_ok=0

  echo
  echo "[4/5] v2.0 PCS/PTS feature upgrade audit"

  if [[ ! -f "$DEST" ]]; then
    echo "  WARN runner: Phoenix_Proactive_Nudge.cjs missing" >&2
    all_ok=1
  else
    local missing_runner=()
    local marker
    for marker in "${required_markers[@]}"; do
      if ! grep -Fq "$marker" "$DEST"; then
        missing_runner+=("$marker")
      fi
    done
    if [[ "${#missing_runner[@]}" -gt 0 ]]; then
      echo "  WARN runner: missing v1.9 marker(s): ${missing_runner[*]}" >&2
      all_ok=1
    else
      echo "  OK runner: proactive feature markers present"
    fi
  fi

  local root_release_marker="$ROOT/PHOENIX_AGENT_RELEASE.json"
  if [[ ! -f "$root_release_marker" ]]; then
    echo "  WARN root: PHOENIX_AGENT_RELEASE.json missing" >&2
    all_ok=1
  elif ! grep -Fq "$PHOENIX_RELEASE_VERSION" "$root_release_marker"; then
    echo "  WARN root: release marker is not $PHOENIX_RELEASE_VERSION" >&2
    all_ok=1
  else
    echo "  OK root: release marker $PHOENIX_RELEASE_VERSION present"
  fi

  local bot workdir rel file
  for bot in "${INSTALLED_TARGET_BOTS[@]}"; do
    workdir="$(work_dir_for_bot "$bot")"
    if [[ ! -d "$workdir" ]]; then
      echo "  WARN $bot: work folder missing; feature upgrade could not be applied" >&2
      all_ok=1
      continue
    fi

    local bot_release_marker="$workdir/PHOENIX_AGENT_RELEASE.json"
    if [[ ! -f "$bot_release_marker" ]]; then
      echo "  WARN $bot: PHOENIX_AGENT_RELEASE.json missing" >&2
      all_ok=1
    elif ! grep -Fq "$PHOENIX_RELEASE_VERSION" "$bot_release_marker"; then
      echo "  WARN $bot: release marker is not $PHOENIX_RELEASE_VERSION" >&2
      all_ok=1
    fi

    local missing_files=()
    for rel in "${required_files[@]}"; do
      file="$workdir/$rel"
      if [[ ! -f "$file" ]]; then
        missing_files+=("$rel")
      fi
    done

    local missing_markers=()
    for marker in "${required_markers[@]}"; do
      local found=0
      for rel in "${required_files[@]}"; do
        file="$workdir/$rel"
        if [[ -f "$file" ]] && grep -Fq "$marker" "$file"; then
          found=1
          break
        fi
      done
      if [[ "$found" -eq 0 ]]; then
        missing_markers+=("$marker")
      fi
    done

    if [[ "${#missing_files[@]}" -gt 0 || "${#missing_markers[@]}" -gt 0 ]]; then
      if [[ "${#missing_files[@]}" -gt 0 ]]; then
        echo "  WARN $bot: missing file(s): ${missing_files[*]}" >&2
      fi
      if [[ "${#missing_markers[@]}" -gt 0 ]]; then
        echo "  WARN $bot: missing v1.9 marker(s): ${missing_markers[*]}" >&2
      fi
      all_ok=1
    else
      echo "  OK $bot: v1.9 identity, proactive policy, PCS/PTS folders, and skill-up markers applied"
    fi
  done

  if [[ "$all_ok" -eq 0 ]]; then
    echo "  v2.0 PCS/PTS feature upgrade audit: OK"
  else
    echo "  v2.0 PCS/PTS feature upgrade audit: review warnings above" >&2
  fi
  return "$all_ok"
}

apply_model_fallback_config() {
  if [[ ! -f "$FALLBACK_SRC" ]]; then
    echo "  WARNING: model fallback helper is missing: $FALLBACK_SRC" >&2
    return 0
  fi
  local bot workdir pm2_name display fallback_out
  for bot in "${INSTALLED_TARGET_BOTS[@]}"; do
    workdir="$(work_dir_for_bot "$bot")"
    if [[ ! -d "$workdir" ]]; then
      echo "  WARNING: $bot work folder missing; fallback config skipped." >&2
      continue
    fi
    pm2_name="$(pm2_name_for_bot "$bot")"
    display="$(display_name_for_bot "$bot")"
    fallback_out="$(node "$FALLBACK_SRC" --mode update --input-dir "$SCRIPT_DIR" --workdir "$workdir" --bot "$bot" --display "$display" --profile "$pm2_name")"
    printf '%s' "$fallback_out" | node -e 'let raw="";process.stdin.on("data",c=>raw+=c);process.stdin.on("end",()=>{try{const x=JSON.parse(raw); console.log(`  ${x.botName}: fallback config refreshed. Gemini configured=${x.geminiConfigured}, Local LLM configured=${x.localConfigured}. Values were not printed.`); if (Array.isArray(x.warnings) && x.warnings.length) console.log(`  ${x.botName}: WARNING ${x.warnings.join("; ")}`);}catch{console.log("  fallback config refreshed. Values were not printed.");}});'
  done
}

ensure_codex_provider() {
  local pm2_name
  for pm2_name in "$@"; do
    [[ -z "$pm2_name" ]] && continue
    echo "  Ensuring Codex provider plugin for $pm2_name"
    openclaw --profile "$pm2_name" plugins install clawhub:@openclaw/codex >/dev/null 2>&1 || true
    openclaw --profile "$pm2_name" plugins inspect codex >/dev/null 2>&1 || true
  done
}

install_launch_agent() {
  local agent_dir="$HOME/Library/LaunchAgents"
  local plist="$agent_dir/ai.openclaw.phoenix.pm2.plist"
  mkdir -p "$agent_dir"

  PHX_PLIST="$plist" PHX_READY="$READY_DEST" node <<'NODE'
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
  echo "Reboot auto-start registered: $plist"
}

start_or_restart_bot() {
  local bot="$1"
  local pm2_name="$2"
  local workdir eco
  workdir="$(work_dir_for_bot "$bot")"
  eco="$workdir/ecosystem.config.js"
  echo "Refreshing bot PM2 process: $pm2_name"
  patch_bot_ecosystem_runtime_env "$bot" "$pm2_name" "$workdir" "$eco"
  if [[ -f "$eco" ]] && pm2 startOrReload "$eco" --only "$pm2_name" --update-env >/dev/null 2>&1; then
    RUNNING_BOTS="${RUNNING_BOTS}${pm2_name}"$'\n'
    return 0
  fi
  if pm2 restart "$pm2_name" --update-env >/dev/null 2>&1; then
    RUNNING_BOTS="${RUNNING_BOTS}${pm2_name}"$'\n'
    return 0
  fi
  if [[ -f "$eco" ]]; then
    echo "  PM2 process not found; registering from $eco"
    pm2 start "$eco" --only "$pm2_name" --update-env >/dev/null
    RUNNING_BOTS="${RUNNING_BOTS}${pm2_name}"$'\n'
    return 0
  fi
  echo "  WARNING: PM2 process and ecosystem file are both missing for $bot. This looks like a failed or deleted install." >&2
  return 1
}

patch_bot_ecosystem_runtime_env() {
  local bot="$1" pm2_name="$2" workdir="$3" eco="$4"
  [[ -f "$eco" ]] || return 0
  PHX_ECO="$eco" PHX_PM2_NAME="$pm2_name" PHX_CODEX_HOME="$HOME/.openclaw-$pm2_name/agents/main/agent/codex-home" node <<'NODE'
const fs = require("fs");
const file = process.env.PHX_ECO;
const pm2Name = process.env.PHX_PM2_NAME;
const codexHome = process.env.PHX_CODEX_HOME;
let text = fs.readFileSync(file, "utf8");
if (text.includes("CODEX_HOME") && text.includes("xterm-256color")) process.exit(0);
const before = text;
text = text.replace(
  /env:\s*\{\s*\.\.\.localEnv,\s*OPENCLAW_PROFILE:\s*["'][^"']+["'],\s*OPENCLAW_PORT:\s*["']?([^"',}]+)["']?\s*\}/m,
  (m, port) => `env: { ...localEnv, OPENCLAW_PROFILE: "${pm2Name}", OPENCLAW_PORT: "${String(port).replace(/"/g, "")}", CODEX_HOME: "${codexHome.replace(/\\/g, "\\\\")}", TERM: "xterm-256color" }`
);
if (text === before && text.includes("env:")) {
  text = text.replace(/env:\s*\{/, `env: { CODEX_HOME: "${codexHome.replace(/\\/g, "\\\\")}", TERM: "xterm-256color", `);
}
if (text !== before) {
  fs.copyFileSync(file, `${file}.bak_v17_codexhome`);
  fs.writeFileSync(file, text, "utf8");
}
NODE
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
probe_gateway_operator_scope() {
  local pm2_name="$1"
  local out
  out="$(openclaw --profile "$pm2_name" gateway probe --json 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    echo "  WARNING $pm2_name: Gateway probe did not return JSON yet." >&2
    return 0
  fi
  PHX_GATEWAY_PROBE="$out" PHX_PM2_NAME="$pm2_name" node <<'NODE'
const raw = process.env.PHX_GATEWAY_PROBE || "";
const name = process.env.PHX_PM2_NAME || "bot";
try {
  const data = JSON.parse(raw);
  const target = Array.isArray(data.targets) ? data.targets[0] : null;
  const connectOk = Boolean(target && target.connect && target.connect.ok && target.connect.rpcOk);
  if (data.ok && !data.degraded && connectOk) {
    console.log(`  OK ${name}: Gateway health/connect/rpc probe confirmed.`);
  } else {
    console.log(`  WARNING ${name}: Gateway probe did not fully confirm health/connect/rpc yet. Recheck health and Telegram pairing if replies are invisible.`);
  }
} catch {
  console.log(`  WARNING ${name}: Gateway probe JSON parse failed. Secret values were not printed.`);
}
NODE
}

if [[ "$(basename "$SCRIPT_DIR")" != "updater" ]]; then
  echo "WARNING: This script is expected to run from the package updater folder. Current script folder: $SCRIPT_DIR" >&2
fi
if [[ ! -d "$ROOT" ]]; then
  echo "ERROR: OpenClaw workspace not found: $ROOT." >&2
  echo "If the previous install failed or was deleted, run the v2.0 installer. If you are using another macOS account, switch to the account where the bots were installed." >&2
  exit 1
fi
if [[ ! -f "$SRC" ]]; then
  echo "ERROR: Missing updater payload: $SRC" >&2
  exit 1
fi
if [[ ! -f "$REPAIR_SRC" ]]; then
  echo "ERROR: Missing updater payload: $REPAIR_SRC" >&2
  exit 1
fi
if [[ ! -f "$FALLBACK_SRC" ]]; then
  echo "ERROR: Missing updater payload: $FALLBACK_SRC" >&2
  exit 1
fi
ensure_runtime
test_installed_target
TARGET_PROCESSES=()
for target_bot in "${INSTALLED_TARGET_BOTS[@]}"; do
  pm2_name="$(pm2_name_for_bot "$target_bot")"
  [[ -n "$pm2_name" ]] && TARGET_PROCESSES+=("$pm2_name")
done

mkdir -p "$ROOT"
cp "$SRC" "$DEST"
node --check "$DEST" >/dev/null
node --check "$REPAIR_SRC" >/dev/null
if [[ -f "$READY_SRC" ]]; then
  cp "$READY_SRC" "$READY_DEST"
  chmod +x "$READY_DEST" 2>/dev/null || true
  bash -n "$READY_DEST"
  install_launch_agent
fi

echo
echo "[1/5] Repairing OpenAI/Codex OAuth routing"
OPENAI_REPAIR_BOTS=()
for target_bot in "${INSTALLED_TARGET_BOTS[@]}"; do
  if [[ "$(auth_mode_for_bot "$target_bot")" == "gemini" ]]; then
    echo "  SKIP $target_bot: Gemini selected-auth mode detected; OpenAI/Codex repair will not overwrite it."
  else
    OPENAI_REPAIR_BOTS+=("$target_bot")
  fi
done
if [[ "${#OPENAI_REPAIR_BOTS[@]}" -gt 0 ]]; then
  ensure_codex_cli_first_auth
  echo "  Codex provider plugin check is handled by phoenix_v20_auth_order_repair.cjs to avoid duplicate OpenClaw plugin installs."
  for repair_bot in "${OPENAI_REPAIR_BOTS[@]}"; do
    if ! node "$REPAIR_SRC" --bot "$repair_bot"; then
      echo "  WARNING: v1.9 OpenAI/Codex OAuth repair reported an issue for $repair_bot. Continuing with config refresh, PM2 restart, and final checks." >&2
      echo "  If replies still fail after this updater, run codex login in this same terminal and rerun the updater." >&2
    fi
  done
else
  echo "  All selected bots use Gemini selected-auth; OpenAI/Codex OAuth repair skipped."
fi

echo
echo "[2/5] Upgrading bots to Phoenix Agent v2.0 proactive + PCS/PTS features"
node "$DEST" --apply-identity-only --bot "$BOT_NAME" >/dev/null
for target_bot in "${INSTALLED_TARGET_BOTS[@]}"; do
  target_workdir="$(work_dir_for_bot "$target_bot")"
  if [[ -d "$target_workdir" ]]; then
    install_v19_skillup_structure "$target_bot" "$(display_name_for_bot "$target_bot")" "$target_workdir" "$(pm2_name_for_bot "$target_bot")"
    install_v20_web_control_structure "$target_bot" "$(display_name_for_bot "$target_bot")" "$target_workdir" "$(pm2_name_for_bot "$target_bot")"
  fi
done

echo
echo "[2b/5] Refreshing explicit model fallback configuration"
apply_model_fallback_config
disable_internal_telegram_heartbeat
write_release_marker

RUNNING_BOTS=""
for bot_process in "${TARGET_PROCESSES[@]}"; do
  case "$bot_process" in
    pw_genesis_bot) bot_key=genesis ;;
    pw_power_bot) bot_key=power ;;
    pw_design_bot) bot_key=design ;;
    pw_video_bot) bot_key=video ;;
    pw_writer_bot) bot_key=writer ;;
    *) bot_key="" ;;
  esac
  [[ -n "$bot_key" ]] && start_or_restart_bot "$bot_key" "$bot_process" || true
done
RUNNING_BOTS="$(printf '%s' "$RUNNING_BOTS" | sed '/^$/d')"

for bot_process in "${TARGET_PROCESSES[@]}"; do
  if [[ -n "$bot_process" ]]; then
    port_owner_matches_pm2 "$bot_process" || true
    probe_gateway_operator_scope "$bot_process" || true
  fi
done

pm2 delete phoenix_proactive_nudge >/dev/null 2>&1 || true
pm2 start "$DEST" --name phoenix_proactive_nudge >/dev/null
pm2 save --force >/dev/null 2>&1 || true

if [[ -f "$READY_DEST" ]]; then
  echo
  echo "[3/5] Sending refreshed Telegram ready notices"
  if [[ "${PHOENIX_UPDATER_SKIP_READY_NOTICE:-}" == "1" ]]; then
    echo "  Skipped by PHOENIX_UPDATER_SKIP_READY_NOTICE=1. Normal user runs do not set this."
  else
    PHOENIX_READY_INITIAL_DELAY_SECONDS=5 bash "$READY_DEST" || true
  fi
fi

audit_v19_feature_upgrade || true

echo
echo "Update complete."
echo "Installed runner: $DEST"
echo "PM2 process: phoenix_proactive_nudge"
if [[ -n "$RUNNING_BOTS" ]]; then
  echo "Bot PM2 processes refreshed:"
  echo "$RUNNING_BOTS"
else
  echo "Bot PM2 processes refreshed: none found for target $BOT_NAME"
  echo "If this bot should be installed, run the v2.0 installer or check that you are in the same macOS user account where the previous Phoenix Agent was installed."
fi
echo
echo "[5/5] PM2 status"
pm2 list
echo
echo "Recent proactive log"
LOG_PATH="$ROOT/logs/phoenix_proactive_nudge.log"
if [[ -f "$LOG_PATH" ]]; then
  tail -n 40 "$LOG_PATH"
else
  echo "Log file not found yet: $LOG_PATH"
  echo "This can be normal right after the first updater run."
fi
echo
echo "Normal log examples: ok genesis: no nudge due / sent genesis: ready_start_suggestion"
echo "$PHOENIX_RELEASE_VERSION upgrade markers: trend_digest / skill_learning_guidance / skill_work_offer / skill_upgrade_request / PHOENIX_v19_PCS_PTS / PHOENIX_AGENT_RELEASE.json"
echo "If 'telegram target missing' repeats, report the log without exposing secret values."
echo "If model replies fail later, run codex login in this same coding-agent terminal, then rerun this updater so OpenAI OAuth is imported again."

