#!/usr/bin/env bash
# Phoenix package release: v1.9
set -u

WORKSPACE="$HOME/antigravity/openclaw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)"
PACKAGE_NAME="$(basename "$PACKAGE_ROOT")"

echo ""
echo "[User Checkpoints] Before running Super Cleaning Bot, confirm these items."
echo "  1. Cleaner is a deletion tool, not an install/auth tool."
echo "  2. For skill/rule updates, do not run cleaner. Use pm2 restart."
echo "  3. Choose deletion scope: one installed bot or all currently installed bots."
echo "  4. Choose whether to back up outputs for each target bot before deletion."
echo "  5. Type the exact final confirmation phrase before deletion proceeds."
echo "  6. If you are running from Antigravity Terminal/Codex, keep this in the current terminal. Do not open a separate terminal window."
echo "  Security: cleaner deletes installed bot runtime credentials, but keeps installer key folders and never prints token/API key/OAuth credential values."

normalize_bot() {
  local n="$1"
  n="${n#.openclaw-}"; n="${n#openclaw-}"; n="${n#pw_}"; n="${n%_bot}"; n="${n%-bot}"
  printf '%s' "$n" | tr '[:upper:]' '[:lower:]'
}

pm2_state_exists() {
  [[ -d "$HOME/.pm2" || -f "$HOME/.pm2/dump.pm2" || -f "$HOME/.pm2/dump.pm2.bak" || -S "$HOME/.pm2/rpc.sock" || -S "$HOME/.pm2/pub.sock" ]]
}

get_installed_bots() {
  {
    if pm2_state_exists && command -v pm2 >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
      pm2 jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const a=JSON.parse(s);for(const p of a){const n=String(p.name||"");const m=n.match(/^pw_(.+)_bot$/);if(m) console.log(m[1]);}}catch(e){}});' 2>/dev/null || true
    fi
    [[ -d "$WORKSPACE" ]] && find "$WORKSPACE" -maxdepth 1 -type d -name "*_bot" -exec basename {} \; 2>/dev/null | sed 's/_bot$//'
    find "$HOME" -maxdepth 1 -type d -name ".openclaw-pw_*" -exec basename {} \; 2>/dev/null | sed 's/^\.openclaw-pw_//; s/_bot$//'
    [[ -d "$HOME/.openclaw-state" ]] && find "$HOME/.openclaw-state" -maxdepth 1 -type d -name "pw_*" -exec basename {} \; 2>/dev/null | sed 's/^pw_//; s/_bot$//'
  } | awk 'NF {print tolower($0)}' | sort -u
}

safe_delete_path() {
  local path="$1" bot="$2"
  [[ -n "$path" ]] || return 1
  local full home
  full="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")"
  home="$(cd "$HOME" 2>/dev/null && pwd -P)"
  [[ "$full" != "$home" && "$full" != "/" && ${#full} -ge 20 && "$full" == "$home/"* && "$full" == *"$bot"* ]]
}

path_is_under() {
  local path="$1" root="$2"
  local full base
  [[ -n "$path" && -n "$root" ]] || return 1
  full="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" || return 1
  base="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
  [[ "$full" == "$base" || "$full" == "$base/"* ]]
}

is_current_package_artifact() {
  local path="$1" full pkg_parent
  [[ -n "$path" ]] || return 1
  full="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" || return 1
  pkg_parent="$(cd "$PACKAGE_ROOT/.." 2>/dev/null && pwd -P)"
  [[ "$full" == "$PACKAGE_ROOT" ]] && return 0
  [[ "$full" == "$pkg_parent/$PACKAGE_NAME.zip" ]] && return 0
  [[ "$full" == "$HOME/Downloads/$PACKAGE_NAME.zip" ]] && return 0
  return 1
}

safe_delete_residual_path() {
  local path="$1" label="${2:-residual}"
  local full home
  [[ -n "$path" && -e "$path" ]] || return 0
  if is_current_package_artifact "$path"; then
    echo "Kept current package artifact: $path"
    return 0
  fi
  full="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" || return 0
  home="$(cd "$HOME" 2>/dev/null && pwd -P)"
  [[ "$full" != "$home" && "$full" != "/" && ${#full} -ge 10 && "$full" == "$home/"* ]] || { echo "Skipped unsafe $label path: $path"; return 0; }
  rm -rf -- "$full" 2>/dev/null || true
  [[ ! -e "$full" ]] && echo "Deleted $label: $full"
}

find_phoenix_credential_inputs() {
  local roots=(
    "$WORKSPACE"
    "$HOME/.openclaw"
    "$HOME/.openclaw-state"
  )
  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    find "$root" -type f \( \
      -name 'telegram_access_token.txt' -o \
      -name 'telegram_chat_id.txt' -o \
      -name 'telegram_pairing_code.txt' -o \
      -name 'bot_access_token.txt' -o \
      -name 'chat_id.txt' -o \
      -name 'pairing_code.txt' -o \
      -name 'openai_api_key_image.txt' -o \
      -name 'falai_api_key_video.txt' -o \
      -name 'gemini_api_key.txt' -o \
      -name 'local_llm_api_key.txt' -o \
      -name 'conversation_api_key.txt' -o \
      -name 'api_key.txt' -o \
      -name 'pal_api_key.txt' -o \
      -name '.env' -o \
      -name '.env.*' \
    \) -print 2>/dev/null
  done
  find "$HOME" -maxdepth 2 -type f \( \
    -path "$HOME/.openclaw-*/*" -o \
    -path "$HOME/.openclaw-state/*" \
  \) \( \
    -name 'telegram_access_token.txt' -o \
    -name 'telegram_chat_id.txt' -o \
    -name 'telegram_pairing_code.txt' -o \
    -name 'bot_access_token.txt' -o \
    -name 'chat_id.txt' -o \
    -name 'pairing_code.txt' -o \
    -name 'openai_api_key_image.txt' -o \
    -name 'falai_api_key_video.txt' -o \
    -name 'gemini_api_key.txt' -o \
    -name 'local_llm_api_key.txt' -o \
    -name 'conversation_api_key.txt' -o \
    -name 'api_key.txt' -o \
    -name 'pal_api_key.txt' -o \
    -name '.env' -o \
    -name '.env.*' \
  \) -print 2>/dev/null
}

remove_phoenix_credential_inputs() {
  echo ""; echo "Removing installed Phoenix/OpenClaw runtime credential files without printing values..."
  echo "Keeping installer/package key folders such as 인증키_API 키 모음 and 인증키_에이전트 모델 인증 키 모음; installer/package key folders are preserved."
  local count=0 item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    safe_delete_residual_path "$item" "installed runtime credential input file"
    count=$((count+1))
  done < <(find_phoenix_credential_inputs | sort -u)
  [[ "$count" -eq 0 ]] && echo "No Phoenix/OpenClaw installed runtime credential input files found."
}

find_legacy_phoenix_packages() {
  return 0
}

remove_legacy_phoenix_packages() {
  echo ""; echo "Preserved Phoenix Agent package folders and installer key folders. Cleaner only removes installed bot runtime state."
}

find_phoenix_library_residuals() {
  local exact=(
    "$HOME/Library/Application Support/clawhub"
  )
  local item
  for item in "${exact[@]}"; do
    [[ -e "$item" ]] && printf '%s\n' "$item"
  done
  for root in "$HOME/Library/Caches/claude-cli-nodejs" "$HOME/Library/Caches" "$HOME/Library/Logs" "$HOME/Library/Preferences" "$HOME/Library/Saved Application State"; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 3 \( -iname '*openclaw*' -o -iname '*phoenix*' -o -iname '*clawhub*' -o -iname '*pw_*_bot*' \) -print 2>/dev/null
  done
}

remove_phoenix_library_residuals() {
  echo ""; echo "Removing Phoenix/OpenClaw Library residuals..."
  local count=0 item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    safe_delete_residual_path "$item" "Library residual"
    count=$((count+1))
  done < <(find_phoenix_library_residuals | sort -u)
  [[ "$count" -eq 0 ]] && echo "No Phoenix/OpenClaw Library residuals found."
}

find_phoenix_developer_tool_residuals() {
  local root item npx_root
  for root in "$HOME/.claude/projects" "$HOME/.gemini/antigravity" "$HOME/.config" "$HOME/.cache"; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 4 \( -iname '*openclaw*' -o -iname '*phoenix*' -o -iname '*clawhub*' -o -iname '*pw_*_bot*' -o -iname '*powerbot*' -o -iname '*publish_bot*' \) -print 2>/dev/null
  done
  npx_root="$HOME/.npm/_npx"
  if [[ -d "$npx_root" ]]; then
    find "$npx_root" -maxdepth 4 \( -path '*/node_modules/openclaw' -o -path '*/node_modules/clawhub' -o -path '*/node_modules/@openclaw/codex' -o -path '*/.bin/openclaw' -o -path '*/.bin/clawhub' \) -print 2>/dev/null | while IFS= read -r item; do
      local rel="${item#$npx_root/}"
      local top="${rel%%/*}"
      [[ -n "$top" && -d "$npx_root/$top" ]] && printf '%s\n' "$npx_root/$top"
    done
  fi
}

remove_phoenix_developer_tool_residuals() {
  echo ""; echo "Removing Phoenix/OpenClaw developer tool residuals..."
  local count=0 item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    safe_delete_residual_path "$item" "developer tool residual"
    count=$((count+1))
  done < <(find_phoenix_developer_tool_residuals | sort -u)
  [[ "$count" -eq 0 ]] && echo "No Phoenix/OpenClaw developer tool residuals found."
}

backup_outputs() {
  local root="$HOME/Desktop/phoenix_super_cleaning_backup_$(date +%Y%m%d_%H%M%S)" made=0
  for bot in "$@"; do
    local outputs="$WORKSPACE/${bot}_bot/outputs"
    if [[ -d "$outputs" ]] && find "$outputs" -type f -print -quit | grep -q .; then
      [[ "$made" -eq 1 ]] || { mkdir -p "$root"; made=1; }
      cp -R "$outputs" "$root/${bot}_outputs"
    fi
  done
  [[ "$made" -eq 1 ]] && echo "Backed up outputs: $root" || echo "No outputs found to back up."
}

backup_outputs_per_bot() {
  local choice="$1"; shift
  local root="$HOME/Desktop/phoenix_super_cleaning_backup_$(date +%Y%m%d_%H%M%S)" made=0
  local bot outputs answer
  for bot in "$@"; do
    outputs="$WORKSPACE/${bot}_bot/outputs"
    if [[ ! -d "$outputs" ]] || ! find "$outputs" -type f -print -quit 2>/dev/null | grep -q .; then
      echo "No outputs found for $bot."
      continue
    fi
    if [[ "$choice" == "ask" || -z "$choice" ]]; then
      read -r -p "Action: back up $bot outputs before deleting this bot? Type Y to back up, or n to delete without backup [Y/n]: " answer
    else
      answer="$choice"
      echo "Action: backup $bot outputs before deletion = $choice"
    fi
    if [[ "$answer" =~ ^([Nn]|[Nn][Oo])$ ]]; then
      echo "Skipped outputs backup for $bot."
      continue
    fi
    [[ "$made" -eq 1 ]] || { mkdir -p "$root"; made=1; }
    cp -R "$outputs" "$root/${bot}_outputs"
    echo "Backed up $bot outputs."
  done
  [[ "$made" -eq 1 ]] && echo "Backed up outputs root: $root" || echo "No outputs were backed up."
}

remove_one() {
  local bot="$1" pm2_name="pw_${bot}_bot"
  local workdir="$WORKSPACE/${bot}_bot"
  local profiles=(
    "$HOME/.openclaw-$pm2_name"
    "$HOME/.openclaw-pw_$bot"
    "$HOME/.openclaw-pw_${bot}_bot"
    "$HOME/.openclaw-$bot"
    "$HOME/.openclaw-${bot}_bot"
    "$HOME/.openclaw-${bot}-bot"
  )
  local states=(
    "$HOME/.openclaw-state/$pm2_name"
    "$HOME/.openclaw-state/pw_$bot"
    "$HOME/.openclaw-state/$bot"
    "$HOME/.openclaw-state/${bot}_bot"
  )
  local plist="$HOME/Library/LaunchAgents/ai.openclaw.${pm2_name}.plist"
  echo ""; echo "Removing: $pm2_name"
  if command -v pm2 >/dev/null 2>&1; then
    pm2 stop "$pm2_name" >/dev/null 2>&1 || true
    pm2 delete "$pm2_name" >/dev/null 2>&1 || true
    rm -f "$HOME/.pm2/logs/"*"$pm2_name"* 2>/dev/null || true
  fi
  [[ -f "$plist" ]] && { launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true; rm -f "$plist"; echo "Deleted: $plist"; }
  for path in "${profiles[@]}" "${states[@]}" "$workdir"; do
    if [[ -e "$path" ]]; then
      if safe_delete_path "$path" "$bot"; then rm -rf "$path"; echo "Deleted: $path"; else echo "Skipped unsafe path: $path"; fi
    fi
  done
}

remove_proactive_runner() {
  echo ""; echo "Removing Phoenix proactive runner..."
  if command -v pm2 >/dev/null 2>&1; then
    pm2 stop phoenix_proactive_nudge >/dev/null 2>&1 || true
    pm2 delete phoenix_proactive_nudge >/dev/null 2>&1 || true
    rm -f "$HOME/.pm2/logs/"*phoenix_proactive_nudge* 2>/dev/null || true
  fi
  if [[ "$WORKSPACE" == "$HOME/antigravity/openclaw" ]]; then
    for path in "$WORKSPACE/Phoenix_Proactive_Nudge.cjs" "$WORKSPACE/Phoenix_Ready_Notice.command" "$WORKSPACE/logs/phoenix_proactive_nudge.log"; do
      if [[ -e "$path" ]]; then
        rm -f "$path" 2>/dev/null || true
        echo "Deleted: $path"
      fi
    done
  fi
  local shared_plist="$HOME/Library/LaunchAgents/ai.openclaw.phoenix.pm2.plist"
  if [[ -e "$shared_plist" ]]; then
    launchctl bootout "gui/$(id -u)" "$shared_plist" >/dev/null 2>&1 || true
    launchctl unload "$shared_plist" >/dev/null 2>&1 || true
    rm -f "$shared_plist"
    echo "Deleted shared Phoenix LaunchAgent: $shared_plist"
  fi
}

remove_all_openclaw_state() {
  echo ""; echo "Removing global OpenClaw state for clean reinstall..."
  rm -rf "$HOME/.openclaw" "$HOME/.openclaw-state" "$HOME"/.openclaw-pw_* 2>/dev/null || true
  for bot in genesis power design video writer; do
    rm -rf \
      "$HOME/.openclaw-$bot" \
      "$HOME/.openclaw-${bot}_bot" \
      "$HOME/.openclaw-${bot}-bot" \
      "$HOME/.openclaw-pw_$bot" \
      "$HOME/.openclaw-pw_${bot}_bot" \
      2>/dev/null || true
  done
  if [[ -d "$HOME/Library/LaunchAgents" ]]; then
    for plist in "$HOME"/Library/LaunchAgents/ai.openclaw.*.plist; do
      [[ -e "$plist" ]] || continue
      launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
      rm -f "$plist"
      echo "Deleted: $plist"
    done
  fi
}

clear_phoenix_pm2_dump() {
  local mode="${1:-selected}"
  shift || true
  command -v node >/dev/null 2>&1 || return 0
  local dump result
  for dump in "$HOME/.pm2/dump.pm2" "$HOME/.pm2/dump.pm2.bak"; do
    [[ -f "$dump" ]] || continue
    result="$(node -e 'const fs=require("fs");const p=process.argv[1];const mode=process.argv[2];const names=new Set(process.argv.slice(3));let a=[];try{a=JSON.parse((fs.readFileSync(p,"utf8")||"[]").replace(/^\uFEFF/,""))}catch(e){process.exit(0)}if(!Array.isArray(a))process.exit(0);const isPhoenix=n=>/^pw_.*_bot$/.test(n)||n==="phoenix_proactive_nudge";const keep=a.filter(x=>{const n=String(x&&x.name||"");return mode==="all" ? !isPhoenix(n) : !names.has(n)});if(keep.length!==a.length){fs.writeFileSync(p,JSON.stringify(keep,null,2)+"\n","utf8");console.log(a.length-keep.length)}' "$dump" "$mode" "$@" 2>/dev/null || true)"
    [[ -n "$result" ]] && echo "Updated PM2 dump $(basename "$dump"): removed $result Phoenix entries."
  done
}

pm2_dump_has_non_phoenix_state() {
  command -v node >/dev/null 2>&1 || return 1
  local dump
  for dump in "$HOME/.pm2/dump.pm2" "$HOME/.pm2/dump.pm2.bak"; do
    [[ -f "$dump" ]] || continue
    if node -e 'const fs=require("fs");const p=process.argv[1];let a=[];try{a=JSON.parse((fs.readFileSync(p,"utf8")||"[]").replace(/^\uFEFF/,""))}catch(e){process.exit(1)}if(!Array.isArray(a))process.exit(1);const isPhoenix=n=>/^pw_.*_bot$/.test(n)||n==="phoenix_proactive_nudge";process.exit(a.some(x=>{const n=String(x&&x.name||"");return n&&!isPhoenix(n)})?0:1)' "$dump" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

pm2_live_has_non_phoenix_state() {
  pm2_state_exists || return 1
  command -v pm2 >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  pm2 jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const a=JSON.parse(s);const isPhoenix=n=>/^pw_.*_bot$/.test(n)||n==="phoenix_proactive_nudge";process.exit(Array.isArray(a)&&a.some(x=>{const n=String(x&&x.name||"");return n&&!isPhoenix(n)})?0:1)}catch(e){process.exit(1)}});' 2>/dev/null
}

pm2_has_non_phoenix_state() {
  pm2_dump_has_non_phoenix_state || pm2_live_has_non_phoenix_state
}

remove_pm2_global_shells_if_safe() {
  pm2_has_non_phoenix_state && { echo "Preserved PM2 global state because non-Phoenix PM2 entries exist."; return 0; }
  if command -v pm2 >/dev/null 2>&1 && pm2_state_exists; then
    pm2 kill >/dev/null 2>&1 || true
    echo "Stopped PM2 daemon because no non-Phoenix PM2 state remains."
  fi
  if [[ -d "$HOME/Library/LaunchAgents" ]]; then
    local plist
    for plist in "$HOME"/Library/LaunchAgents/pm2.*.plist; do
      [[ -e "$plist" ]] || continue
      launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
      rm -f "$plist" 2>/dev/null || true
      [[ ! -e "$plist" ]] && echo "Deleted PM2 auto-start plist: $plist"
    done
  fi
  if [[ -e "$HOME/.pm2" ]]; then
    rm -rf "$HOME/.pm2" 2>/dev/null || true
    [[ ! -e "$HOME/.pm2" ]] && echo "Deleted PM2 global state: $HOME/.pm2"
  fi
}

save_pm2_process_list() {
  local mode="${1:-selected}"
  shift || true
  clear_phoenix_pm2_dump "$mode" "$@"
  if [[ "$mode" == "all" ]]; then
    if pm2_has_non_phoenix_state; then
      command -v pm2 >/dev/null 2>&1 && pm2_state_exists && pm2 save --force >/dev/null 2>&1 || true
      clear_phoenix_pm2_dump "$mode" "$@"
    else
      remove_pm2_global_shells_if_safe
    fi
  else
    command -v pm2 >/dev/null 2>&1 && pm2_state_exists && pm2 save --force >/dev/null 2>&1 || true
    clear_phoenix_pm2_dump "$mode" "$@"
  fi
}

remove_residual_phoenix_workspace() {
  [[ -d "$WORKSPACE" ]] || return 0
  [[ "$WORKSPACE" == "$HOME/antigravity/openclaw" ]] || return 0
  rm -rf "$WORKSPACE" 2>/dev/null || true
  [[ ! -e "$WORKSPACE" ]] && echo "Deleted residual workspace root: $WORKSPACE"
}

remove_phoenix_global_runtime_tools() {
  echo ""; echo "Removing Phoenix OpenClaw runtime npm packages for clean reinstall..."
  if command -v npm >/dev/null 2>&1; then
    npm uninstall -g openclaw clawhub @openclaw/codex >/dev/null 2>&1 || true
    echo "Removed npm runtime packages when present: openclaw, clawhub, @openclaw/codex"
    echo "OpenAI Codex CLI is kept to avoid replacing a running Codex process."
    local scope bin_dir bin
    for scope in "/opt/homebrew/lib/node_modules/@openclaw" "/usr/local/lib/node_modules/@openclaw"; do
      if [[ -d "$scope" ]] && [[ -z "$(find "$scope" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        rm -rf "$scope" 2>/dev/null || true
        [[ ! -e "$scope" ]] && echo "Deleted empty OpenClaw npm scope: $scope"
      fi
    done
    for bin_dir in "/opt/homebrew/bin" "/usr/local/bin"; do
      for bin in openclaw clawhub; do
        if [[ -e "$bin_dir/$bin" || -L "$bin_dir/$bin" ]]; then
          rm -f "$bin_dir/$bin" 2>/dev/null || true
          [[ ! -e "$bin_dir/$bin" && ! -L "$bin_dir/$bin" ]] && echo "Deleted OpenClaw runtime bin residue: $bin_dir/$bin"
        fi
      done
    done
  else
    echo "npm not found; skipped global runtime package removal."
  fi
}

confirm_phoenix_clean_state() {
  local full_reset="${1:-0}" residual=()
  shift || true
  local removed_pm2_names=("$@")
  local removed_bots=()
  local name bot
  for name in "${removed_pm2_names[@]}"; do
    [[ "$name" == "phoenix_proactive_nudge" ]] && continue
    bot="${name#pw_}"; bot="${bot%_bot}"
    [[ -n "$bot" ]] && removed_bots+=("$bot")
  done
  echo ""; echo "Post-clean verification..."
  if [[ "$full_reset" == "1" ]]; then
    [[ -d "$WORKSPACE" ]] && while IFS= read -r item; do residual+=("$item"); done < <(find "$WORKSPACE" -maxdepth 1 -type d \( -name "*_bot" -o -name "pw_*" \) -print 2>/dev/null)
    while IFS= read -r item; do residual+=("$item"); done < <(find "$HOME" -maxdepth 1 -type d \( -name ".openclaw-pw_*" -o -name ".openclaw-genesis*" -o -name ".openclaw-power*" -o -name ".openclaw-design*" -o -name ".openclaw-video*" -o -name ".openclaw-writer*" \) -print 2>/dev/null)
  else
    for bot in "${removed_bots[@]}"; do
      for item in \
        "$WORKSPACE/${bot}_bot" \
        "$HOME/.openclaw-pw_$bot" \
        "$HOME/.openclaw-pw_${bot}_bot" \
        "$HOME/.openclaw-$bot" \
        "$HOME/.openclaw-${bot}_bot" \
        "$HOME/.openclaw-${bot}-bot" \
        "$HOME/.openclaw-state/pw_$bot" \
        "$HOME/.openclaw-state/pw_${bot}_bot" \
        "$HOME/.openclaw-state/$bot" \
        "$HOME/.openclaw-state/${bot}_bot"; do
        [[ -e "$item" ]] && residual+=("$item")
      done
    done
  fi
  if command -v node >/dev/null 2>&1; then
    local mode="selected"
    [[ "$full_reset" == "1" ]] && mode="all"
    local dump
    for dump in "$HOME/.pm2/dump.pm2" "$HOME/.pm2/dump.pm2.bak"; do
      [[ -f "$dump" ]] || continue
      while IFS= read -r item; do residual+=("PM2 $(basename "$dump") entry: $item"); done < <(node -e 'const fs=require("fs");const p=process.argv[1];const mode=process.argv[2];const names=new Set(process.argv.slice(3));try{const a=JSON.parse((fs.readFileSync(p,"utf8")||"[]").replace(/^\uFEFF/,""));for(const x of a){const n=String(x.name||"");if(mode==="all"){if(/^pw_.*_bot$/.test(n)||n==="phoenix_proactive_nudge") console.log(n)}else if(names.has(n)){console.log(n)}}}catch{}' "$dump" "$mode" "${removed_pm2_names[@]}" 2>/dev/null)
    done
  fi
  if [[ "$full_reset" == "1" ]]; then
    rm -rf "$HOME/.openclaw" "$HOME/.openclaw-state" 2>/dev/null || true
    [[ -e "$HOME/.openclaw" ]] && residual+=("$HOME/.openclaw")
    [[ -e "$HOME/.openclaw-state" ]] && residual+=("$HOME/.openclaw-state")
    [[ -e "$WORKSPACE" ]] && residual+=("$WORKSPACE")
    while IFS= read -r item; do residual+=("credential input residual: $item"); done < <(find_phoenix_credential_inputs)
    while IFS= read -r item; do residual+=("legacy package residual: $item"); done < <(find_legacy_phoenix_packages)
    while IFS= read -r item; do residual+=("Library residual: $item"); done < <(find_phoenix_library_residuals)
    while IFS= read -r item; do residual+=("developer tool residual: $item"); done < <(find_phoenix_developer_tool_residuals)
    if ! pm2_has_non_phoenix_state; then
      [[ -e "$HOME/.pm2" ]] && residual+=("$HOME/.pm2")
      if [[ -d "$HOME/Library/LaunchAgents" ]]; then
        local plist
        for plist in "$HOME"/Library/LaunchAgents/pm2.*.plist; do
          [[ -e "$plist" ]] && residual+=("$plist")
        done
      fi
    fi
  fi
  if [[ "${#residual[@]}" -eq 0 ]]; then echo "Clean verification passed: no Phoenix bot/OpenClaw residual state found."; else echo "WARNING: residual items still found after cleanup:"; printf '  %s\n' "${residual[@]}" | sort -u; fi
}

INSTALLED_BOTS=()
while IFS= read -r bot; do
  INSTALLED_BOTS+=("$bot")
done < <(get_installed_bots)
MODE=""; BOT=""; BACKUP_CHOICE=""; CONFIRM_TEXT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      MODE="all"; shift ;;
    --backup|--backup-outputs)
      BACKUP_CHOICE="${2:-}"; shift 2 ;;
    --bot)
      MODE="one"; BOT="$(normalize_bot "${2:-}")"; shift 2 ;;
    --confirm)
      CONFIRM_TEXT="${2:-}"; shift 2 ;;
    --help|-h)
      echo "Usage: bash ./super_cleaning_bot.command [--all|bot_name] [--backup ask|no|yes] [--confirm CONFIRM_TEXT]"; exit 0 ;;
    *)
      MODE="one"; BOT="$(normalize_bot "$1")"; shift ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Phoenix Agent v1.9 Super Cleaning Bot"
  if [[ "${#INSTALLED_BOTS[@]}" -gt 0 ]]; then echo "Installed bots: ${INSTALLED_BOTS[*]}"; else echo "Installed bots: (none found)"; fi
  echo "  [1] Remove one installed bot"
  echo "  [2] Remove all currently installed bots"
  echo "  [Q] Cancel"
  read -r -p "Action: type 1 to delete one installed bot, type 2 to delete all currently installed bots, or type Q to cancel: " choice
  if [[ "$choice" == "2" ]]; then MODE="all"; elif [[ "$choice" == "1" ]]; then
    if [[ "${#INSTALLED_BOTS[@]}" -eq 0 ]]; then
      echo "No installed Phoenix bots were found for one-bot deletion. Use all-bots cleanup for full reset cleanup."
      exit 1
    fi
    i=1; for b in ${INSTALLED_BOTS[@]+"${INSTALLED_BOTS[@]}"}; do echo "  [$i] $b"; i=$((i+1)); done
    read -r -p "Action: type the number or exact bot name you want to delete, then press Enter: " selected
    [[ "$selected" =~ ^[0-9]+$ ]] && BOT="${INSTALLED_BOTS[$((selected-1))]:-}" || BOT="$(normalize_bot "$selected")"
    MODE="one"
  else echo "Cancelled."; exit 0; fi
fi

TARGETS=()
if [[ "$MODE" == "all" ]]; then
  [[ "${#INSTALLED_BOTS[@]}" -gt 0 ]] && TARGETS=("${INSTALLED_BOTS[@]}")
else
  TARGETS=("$BOT")
fi
echo ""; echo "Phoenix Agent v1.9 Super Cleaning Bot"
if [[ "${#TARGETS[@]}" -gt 0 ]]; then echo "Targets: ${TARGETS[*]}"; else echo "Targets: (none found)"; fi
echo "Deletes: PM2 process, bot work folder, bot-specific OpenClaw profile, .openclaw-state, PM2 logs, OpenClaw LaunchAgent, and bot-local Telegram token/chat-id config."
echo "Credential cleanup: installed bot runtime Telegram/OpenClaw credential files are deleted with the target bot/profile, but installer key folders are kept and values are never printed."
[[ "$MODE" == "all" ]] && echo "Full reset mode also deletes global OpenClaw state, OpenClaw runtime npm packages, empty @openclaw npm scopes, OpenClaw bin shims, and PM2 global shells when no non-Phoenix PM2 state remains."
echo "Keeps: installer/package key folders, Phoenix Agent zip/folders, Node.js, Git, PM2 binary, OpenAI Codex CLI, Claude Code, Antigravity, unrelated files. Full reset removes OpenClaw/clawhub/@openclaw/codex packages so the installer can reinstall the matched set."
if [[ -n "$BACKUP_CHOICE" ]]; then
  backup="$(printf '%s' "$BACKUP_CHOICE" | tr '[:upper:]' '[:lower:]')"
else
  backup="ask"
fi
backup_outputs_per_bot "$backup" ${TARGETS[@]+"${TARGETS[@]}"}
if [[ "$MODE" == "all" ]]; then
  if [[ -n "$CONFIRM_TEXT" ]]; then confirm="$CONFIRM_TEXT"; else read -r -p "Action: to permanently delete all currently installed bots, type DELETE ALL INSTALLED PHOENIX BOTS exactly: " confirm; fi
  [[ "$confirm" == "DELETE ALL INSTALLED PHOENIX BOTS" ]] || { echo "Cancelled."; exit 0; }
else
  if [[ -n "$CONFIRM_TEXT" ]]; then confirm="$CONFIRM_TEXT"; else read -r -p "Action: to permanently delete this bot, type DELETE ${TARGETS[0]} exactly: " confirm; fi
  [[ "$confirm" == "DELETE ${TARGETS[0]}" ]] || { echo "Cancelled."; exit 0; }
fi
for bot in ${TARGETS[@]+"${TARGETS[@]}"}; do remove_one "$bot"; done
REMOVE_PROACTIVE=0
if [[ "$MODE" == "all" ]]; then
  remove_proactive_runner
  REMOVE_PROACTIVE=1
else
  REMAINING_BOTS=()
  while IFS= read -r bot; do
    REMAINING_BOTS+=("$bot")
  done < <(get_installed_bots)
  if [[ "${#REMAINING_BOTS[@]}" -eq 0 ]]; then
    remove_proactive_runner
    REMOVE_PROACTIVE=1
  fi
fi
[[ "$MODE" == "all" ]] && {
  remove_all_openclaw_state
  remove_phoenix_credential_inputs
  remove_legacy_phoenix_packages
  remove_phoenix_library_residuals
  remove_phoenix_developer_tool_residuals
  remove_phoenix_global_runtime_tools
  remove_residual_phoenix_workspace
}
PM2_TARGETS=()
for bot in ${TARGETS[@]+"${TARGETS[@]}"}; do PM2_TARGETS+=("pw_${bot}_bot"); done
[[ "$REMOVE_PROACTIVE" == "1" ]] && PM2_TARGETS+=("phoenix_proactive_nudge")
if [[ "$MODE" == "all" ]]; then
  save_pm2_process_list all ${PM2_TARGETS[@]+"${PM2_TARGETS[@]}"}
  confirm_phoenix_clean_state 1 ${PM2_TARGETS[@]+"${PM2_TARGETS[@]}"}
else
  save_pm2_process_list selected ${PM2_TARGETS[@]+"${PM2_TARGETS[@]}"}
  confirm_phoenix_clean_state 0 ${PM2_TARGETS[@]+"${PM2_TARGETS[@]}"}
fi
echo ""; echo "Super cleaning complete."
