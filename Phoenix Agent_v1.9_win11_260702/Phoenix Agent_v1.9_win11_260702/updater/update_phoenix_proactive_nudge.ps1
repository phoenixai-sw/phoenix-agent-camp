# Phoenix updater release: v1.9_260702
param(
  [ValidateSet("all", "genesis", "power", "design", "video", "writer")]
  [string]$BotName = "all"
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$PhoenixReleaseVersion = "v1.9_260702"
$PhoenixSupportedUpgradeFrom = @("v1.6", "v1.7", "v1.7_260619", "v1.7_260626", "v1.8", "v1.8_260625")

Write-Host "Phoenix Proactive Nudge updater $PhoenixReleaseVersion - Windows" -ForegroundColor Cyan
Write-Host "This is an updater, not a reinstall. Existing bots, auth, tokens, outputs, and logs are preserved." -ForegroundColor Yellow
Write-Host "This updater preserves existing bots, refreshes the proactive runner, and upgrades v1.6/v1.7/v1.8 installs to Phoenix Agent v1.9 with PCS/PTS skill-up structure. v1.5 users should use cleaner then installer."
Write-Host "Update target bot: $BotName"
Write-Host "Security: token/API Key/OAuth credential values are never printed."

$root = Join-Path $env:USERPROFILE "antigravity\openclaw"
$src = Join-Path $PSScriptRoot "phoenix_proactive_nudge.cjs"
$dest = Join-Path $root "Phoenix_Proactive_Nudge.cjs"
$repairSrc = Join-Path $PSScriptRoot "phoenix_v19_auth_order_repair.cjs"
$readySrc = Join-Path $PSScriptRoot "Phoenix_Ready_Notice.ps1"
$readyDest = Join-Path $root "Phoenix_Ready_Notice.ps1"
$fallbackSrc = Join-Path $PSScriptRoot "phoenix_model_fallback_state.cjs"
$knownBotProcesses = @{
  genesis = "pw_genesis_bot"
  power = "pw_power_bot"
  design = "pw_design_bot"
  video = "pw_video_bot"
  writer = "pw_writer_bot"
}

function Ensure-PhoenixRuntime {
  $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
  if (-not $npm) {
    throw "npm command not found. Install Node.js LTS, reopen the Codex/Antigravity terminal, then rerun this updater."
  }

  $npmGlobalBins = @()
  if ($env:APPDATA) { $npmGlobalBins += (Join-Path $env:APPDATA "npm") }
  try {
    $npmPrefix = (& $npm.Source prefix -g) 2>$null | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace($npmPrefix)) { $npmGlobalBins += $npmPrefix.Trim() }
  } catch {}
  foreach ($bin in ($npmGlobalBins | Select-Object -Unique)) {
    if ((-not [string]::IsNullOrWhiteSpace($bin)) -and (Test-Path -LiteralPath $bin -PathType Container)) {
      if (($env:PATH -split ';') -notcontains $bin) { $env:PATH = "$bin;$env:PATH" }
    }
  }

  $missing = @()
  foreach ($cmd in @("node", "pm2", "openclaw", "clawhub")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
  }
  if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { $missing += "codex" }

  if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "[runtime] Missing command(s): $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "[runtime] Reinstalling/verifying Phoenix runtime packages with npm. Secret values are not printed." -ForegroundColor Yellow
    & $npm.Source install -g openclaw@latest '@openclaw/codex@latest' clawhub@latest pm2@latest '@openai/codex@latest' --loglevel=error
    foreach ($bin in ($npmGlobalBins | Select-Object -Unique)) {
      if ((-not [string]::IsNullOrWhiteSpace($bin)) -and (Test-Path -LiteralPath $bin -PathType Container)) {
        if (($env:PATH -split ';') -notcontains $bin) { $env:PATH = "$bin;$env:PATH" }
      }
    }
  }

  foreach ($cmd in @("node", "pm2", "openclaw")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
      throw "$cmd command is still missing after runtime repair. Reopen the terminal or reinstall Node.js LTS, then rerun this updater."
    }
  }
}

function Get-PhoenixWorkDir {
  param([string]$Bot)
  return (Join-Path $root "$($Bot)_bot")
}

function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content
  )
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-PhoenixBotAuthMode {
  param([string]$Bot)
  $envPath = Join-Path (Get-PhoenixWorkDir -Bot $Bot) ".env"
  if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    foreach ($line in (Get-Content -LiteralPath $envPath -Encoding UTF8)) {
      if ($line -match '^PHOENIX_MODEL_AUTH_MODE=(.+)$') {
        return $Matches[1].Trim().ToLowerInvariant()
      }
    }
  }
  return "openai"
}

function Get-PhoenixKnownBots {
  return @("genesis", "power", "design", "video", "writer")
}

function Get-PhoenixCommandSource {
  param([string]$Command)
  $cmd = Get-Command "$Command.cmd" -ErrorAction SilentlyContinue
  if (-not $cmd) { $cmd = Get-Command $Command -ErrorAction SilentlyContinue }
  if (-not $cmd) { throw "$Command command not found." }
  return $cmd.Source
}

function Invoke-PhoenixExternal {
  param(
    [Parameter(Mandatory=$true)][string]$Command,
    [string[]]$Arguments = @(),
    [switch]$IgnoreErrors
  )
  $source = Get-PhoenixCommandSource -Command $Command
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # Some CLIs, including Codex, print normal status text to stderr. Capture it
    # for parsing, but judge success by exit code instead of stderr presence.
    $ErrorActionPreference = "Continue"
    $output = & $source @Arguments 2>&1
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ((-not $IgnoreErrors) -and $exit -ne 0) {
    throw "$Command $($Arguments -join ' ') failed with exit code $exit.`n$($output | Out-String)"
  }
  return $output
}

function Test-PhoenixCodexCliLogin {
  if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Host "  WARNING: Codex CLI command is not available after runtime repair." -ForegroundColor Yellow
    return $false
  }
  $status = (Invoke-PhoenixExternal -Command "codex" -Arguments @("login", "status") -IgnoreErrors) | Out-String
  if (($status -match "(?i)logged in|authenticated|chatgpt") -and ($status -notmatch "(?i)not logged|not authenticated|logged out")) {
    Write-Host "  Codex CLI ChatGPT login: detected"
    return $true
  }
  Write-Host "  WARNING: Codex CLI ChatGPT login was not detected." -ForegroundColor Yellow
    Write-Host "  If model replies fail, run 'codex login' in this same Codex/Antigravity terminal, then rerun this updater so OpenAI OAuth can be imported." -ForegroundColor Yellow
  return $false
}

function Ensure-PhoenixCodexCliFirstAuth {
  if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw "Codex CLI command is not available after runtime repair. Reopen this coding agent terminal or reinstall Codex CLI, then rerun this updater."
  }
  Write-Host "  Codex CLI First Auth Policy: checking current ChatGPT login before OpenAI OAuth import."
  if (Test-PhoenixCodexCliLogin) {
    Write-Host "  OK: Codex CLI login detected. It will be imported into the OpenAI provider for Phoenix bots." -ForegroundColor Green
    return
  }
  Write-Host "  ACTION: Opening codex login. Approve with the ChatGPT subscription account in the browser." -ForegroundColor Cyan
  Write-Host "  Security: OAuth credential values are not printed." -ForegroundColor DarkGray
  Invoke-PhoenixExternal -Command "codex" -Arguments @("login") -IgnoreErrors | Out-Null
  if (-not (Test-PhoenixCodexCliLogin)) {
    throw "Codex CLI ChatGPT login is still not valid. Complete codex login in this same terminal, then rerun this updater."
  }
  Write-Host "  OK: Codex CLI ChatGPT login restored and ready for OpenAI OAuth import." -ForegroundColor Green
}

function Ensure-PhoenixCodexProvider {
  param([string[]]$Pm2Names)
  foreach ($pm2Name in ($Pm2Names | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($pm2Name)) { continue }
    Write-Host "  Ensuring Codex provider plugin for $pm2Name"
    Invoke-PhoenixExternal -Command "openclaw" -Arguments @("--profile", $pm2Name, "plugins", "install", "clawhub:@openclaw/codex") -IgnoreErrors | Out-Null
    Invoke-PhoenixExternal -Command "openclaw" -Arguments @("--profile", $pm2Name, "plugins", "inspect", "codex") -IgnoreErrors | Out-Null
  }
}

function Update-PhoenixBotEcosystemRuntimeEnv {
  param([string]$Bot, [string]$Pm2Name, [string]$EcoPath)
  if (-not (Test-Path -LiteralPath $EcoPath -PathType Leaf)) { return }
  $profileDir = Join-Path $env:USERPROFILE ".openclaw-$Pm2Name"
  $codexHome = (Join-Path $profileDir "agents\main\agent\codex-home") -replace '\\','/'
  $text = Get-Content -LiteralPath $EcoPath -Raw -Encoding UTF8
  if ($text -match "CODEX_HOME" -and $text -match "xterm-256color") { return }
  $before = $text
  $pattern = "env:\s*\{\s*\.\.\.localEnv,\s*OPENCLAW_PROFILE:\s*'[^']+',\s*OPENCLAW_PORT:\s*'([^']+)',\s*NODE_ENV:\s*'production'\s*\}"
  $replacement = "env: { ...localEnv, OPENCLAW_PROFILE: '$Pm2Name', OPENCLAW_PORT: '`$1', CODEX_HOME: '$codexHome', TERM: 'xterm-256color', NODE_ENV: 'production' }"
  $text = [regex]::Replace($text, $pattern, $replacement)
  if ($text -eq $before -and $text -match "env:\s*\{") {
    $text = [regex]::Replace($text, "env:\s*\{", "env: { CODEX_HOME: '$codexHome', TERM: 'xterm-256color', ", 1)
  }
  if ($text -ne $before) {
    Copy-Item -LiteralPath $EcoPath -Destination "$EcoPath.bak_v17_codexhome" -Force
    [System.IO.File]::WriteAllText($EcoPath, $text, [System.Text.UTF8Encoding]::new($false))
  }
}

function Start-OrRestartPhoenixBot {
  param([string]$Bot, [string]$Pm2Name)
  $workDir = Get-PhoenixWorkDir -Bot $Bot
  $eco = Join-Path $workDir "ecosystem.config.js"
  Write-Host "Refreshing bot PM2 process: $Pm2Name"
  Update-PhoenixBotEcosystemRuntimeEnv -Bot $Bot -Pm2Name $Pm2Name -EcoPath $eco
  if (Test-Path -LiteralPath $eco -PathType Leaf) {
    $reloadOutput = (Invoke-PhoenixExternal -Command "pm2" -Arguments @("startOrReload", $eco, "--only", $Pm2Name, "--update-env") -IgnoreErrors) | Out-String
    if ($reloadOutput -notmatch "(?i)error|failed|not found|unknown") {
      return $true
    }
  }
  $restartOutput = (Invoke-PhoenixExternal -Command "pm2" -Arguments @("restart", $Pm2Name, "--update-env") -IgnoreErrors) | Out-String
  if ($restartOutput -match "(?i)doesn.?t exist|not found|unknown process") {
    if (Test-Path -LiteralPath $eco -PathType Leaf) {
      Write-Host "  PM2 process not found; registering from $eco" -ForegroundColor Yellow
      Invoke-PhoenixExternal -Command "pm2" -Arguments @("start", $eco, "--only", $Pm2Name, "--update-env") | Out-Null
      return $true
    }
    Write-Host "  WARNING: PM2 process and ecosystem file are both missing for $Bot. This looks like a failed or deleted install." -ForegroundColor Yellow
    return $false
  }
  return $true
}

function Get-PhoenixPm2PortOwnerStatus {
  param([Parameter(Mandatory=$true)][string]$Pm2Name)
  $result = [ordered]@{ Pm2Name=$Pm2Name; Pm2Pid=0; Pm2Status=''; Port=0; OwnerPid=0; Match=$true; Checked=$false }
  try {
    $raw = pm2 jlist 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]$result }
    $nodeScript = @"
let s='';
process.stdin.on('data', c => s += c);
process.stdin.on('end', () => {
  let a=[];
  try { a = JSON.parse(s || '[]'); } catch {}
  const name = process.argv[1];
  const x = a.find(p => p && p.name === name) || {};
  const e = x.pm2_env || {};
  const env = e.env || {};
  console.log(JSON.stringify({ pid:Number(x.pid||0), status:String(e.status||''), port:Number(env.OPENCLAW_PORT||0) }));
});
"@
    $json = $raw | node -e $nodeScript $Pm2Name
    $info = $json | ConvertFrom-Json
    $result.Pm2Pid = [int]($info.pid)
    $result.Pm2Status = [string]($info.status)
    $result.Port = [int]($info.port)
    if ($result.Port -gt 0) {
      $conn = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $result.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($conn) { $result.OwnerPid = [int]$conn.OwningProcess }
      $result.Checked = $true
      if ($result.Pm2Pid -gt 0 -and $result.OwnerPid -gt 0 -and $result.Pm2Pid -ne $result.OwnerPid) { $result.Match = $false }
    }
  } catch {}
  [pscustomobject]$result
}

function Test-PhoenixPortOwnerMatchesPm2 {
  param([Parameter(Mandatory=$true)][string]$Pm2Name)
  $status = Get-PhoenixPm2PortOwnerStatus -Pm2Name $Pm2Name
  if ($status.Checked -and -not $status.Match) {
    Write-Host "  WARNING ${Pm2Name}: gateway port owner PID mismatch. port=$($status.Port), pm2Pid=$($status.Pm2Pid), ownerPid=$($status.OwnerPid). Recent EADDRINUSE logs may indicate an orphan gateway process." -ForegroundColor Yellow
    return $false
  }
  if ($status.Checked) {
    Write-Host "  OK ${Pm2Name}: PM2 PID matches gateway port owner (port $($status.Port))." -ForegroundColor Green
  } else {
    Write-Host "  WARNING ${Pm2Name}: gateway port owner check could not be completed." -ForegroundColor Yellow
  }
  return $true
}
function Test-PhoenixGatewayOperatorScope {
  param([string[]]$Pm2Names)
  foreach ($pm2Name in ($Pm2Names | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($pm2Name)) { continue }
    $raw = (Invoke-PhoenixExternal -Command "openclaw" -Arguments @("--profile", $pm2Name, "gateway", "probe", "--json") -IgnoreErrors) | Out-String
    if ([string]::IsNullOrWhiteSpace($raw)) {
      Write-Host "  WARNING ${pm2Name}: Gateway probe did not return JSON yet." -ForegroundColor Yellow
      continue
    }
    try {
      $probe = $raw | ConvertFrom-Json
      $target = @($probe.targets | Select-Object -First 1)
      $connectOk = $false
      if ($target -and $target.connect) {
        $connectOk = [bool]$target.connect.ok -and [bool]$target.connect.rpcOk
      }
      if ([bool]$probe.ok -and -not [bool]$probe.degraded -and $connectOk) {
        Write-Host "  OK ${pm2Name}: Gateway health/connect/rpc probe confirmed." -ForegroundColor Green
      } else {
        Write-Host "  WARNING ${pm2Name}: Gateway probe did not fully confirm health/connect/rpc yet. Recheck health and Telegram pairing if replies are invisible." -ForegroundColor Yellow
      }
    } catch {
      Write-Host "  WARNING ${pm2Name}: Gateway probe parse failed. Secret values were not printed." -ForegroundColor Yellow
    }
  }
}

function Test-PhoenixInstalledTarget {
  $known = Get-PhoenixKnownBots
  $targets = if ($BotName -eq "all") { $known } else { @($BotName) }
  $found = @()
  foreach ($bot in $targets) {
    $workDir = Get-PhoenixWorkDir -Bot $bot
    $profileDirs = @(
      (Join-Path $env:USERPROFILE ".openclaw-pw_$($bot)_bot"),
      (Join-Path $env:USERPROFILE ".openclaw-pw_$bot")
    )
    if ((Test-Path -LiteralPath $workDir) -or (@($profileDirs | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0)) {
      $found += $bot
    }
  }
  if ($found.Count -eq 0) {
    throw "No installed Phoenix bot work folder/profile was found for target '$BotName'. If the previous install failed or you are in the wrong Windows user account, use the v1.9 installer instead of the updater. v1.5 users should clean reinstall with the v1.9 cleaner and installer."
  }
  return $found
}

function Add-PhoenixMarkedBlock {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Start,
    [Parameter(Mandatory=$true)][string]$End,
    [Parameter(Mandatory=$true)][string]$Body,
    [string]$DefaultTitle = "# Phoenix Agent v1.9"
  )
  $block = $Start + [Environment]::NewLine + $Body.Trim() + [Environment]::NewLine + $End
  if (Test-Path -LiteralPath $Path -PathType Leaf) { $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } else { $text = $DefaultTitle + [Environment]::NewLine }
  $pattern = [regex]::Escape($Start) + "(?s).*?" + [regex]::Escape($End)
  if ([regex]::IsMatch($text, $pattern)) { $text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1) }
  else { $text = $text.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $block + [Environment]::NewLine }
  [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Install-Phoenixv19SkillupStructure {
  param(
    [Parameter(Mandatory=$true)][string]$RootDir,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [Parameter(Mandatory=$true)][string]$BotName,
    [Parameter(Mandatory=$true)][string]$DisplayName,
    [Parameter(Mandatory=$true)][string]$BotId
  )
  $allBots = @('genesis','power','design','video','writer')
  $common = Join-Path $RootDir 'phoenix_v19'
  $commonDirs = @($common,(Join-Path $common 'skill_creator_prompts'),(Join-Path $common 'record_replay_guides'),(Join-Path $common 'skill_candidates'),(Join-Path $common 'approved_skills'),(Join-Path $common 'rejected_skills'))
  foreach ($base in @('skill_creator_prompts','record_replay_guides','skill_candidates','approved_skills','rejected_skills')) { foreach ($bot in $allBots) { $commonDirs += (Join-Path (Join-Path $common $base) $bot) } }
  $botDirs = @((Join-Path $WorkDir '.agents\skills'),(Join-Path $WorkDir '.phoenix_v19'),(Join-Path $WorkDir '.phoenix_v19\skill_candidates'),(Join-Path $WorkDir '.phoenix_v19\approved_skills'),(Join-Path $WorkDir '.phoenix_v19\rejected_skills'))
  foreach ($dir in ($commonDirs + $botDirs)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  $readme = @"
# Phoenix Agent v1.9 PCS/PTS Skill-Up

Phoenix Agent v1.9 keeps the existing Phoenix runtime features and adds two approved skill-up paths.

- PCS (Phoenix Copy Skill): screen-and-workflow based skill-up. Use it when the user can demonstrate an actual workflow, screen sequence, click/input order, upload/download path, folder operation, tool operation, or repeated business process. The result must be a reusable skill candidate with skills, examples, and checklist updates.
- PTS (Phoenix Talk Skill): example-and-standard based skill-up. Use it when the user provides strong samples, manuscripts, reports, scripts, prompts, checklists, tone/style rules, or quality criteria. The result must extract reusable reasoning patterns, output structures, style rules, quality bars, prohibited patterns, and prompt examples.

A good PCS/PTS candidate must include:
- target bot and skill name
- source material or demonstrated workflow
- required inputs and expected output format
- success criteria and quality checklist
- failure cases, prohibited behavior, and sensitive-information cautions
- exact proposed changes for skills, examples, and checklist

Safety rules:
- Bots may suggest skill candidates, but they must not self-install or self-edit approved skill files.
- Master approval is required before anything moves into .agents/skills.
- Secrets, Telegram tokens, API keys, OAuth files, and raw .env values must never be copied into skill files.
"@
  Write-Utf8NoBomFile -Path (Join-Path $common 'README_v19_SKILLUP.md') -Content $readme
  $policyJson = @{ release = 'Phoenix Agent v1.9'; pcs = @{ name = 'Phoenix Copy Skill'; officialFeature = 'Codex Record & Replay'; primaryRecordingOs = 'macOS'; windowsPolicy = 'PTS or reviewed import only' }; pts = @{ name = 'Phoenix Talk Skill'; officialFeature = 'Codex Skill Creator'; supportedOs = @('Windows','macOS') }; approval = @{ botsCanSuggest = $true; masterApprovalRequired = $true; directSelfModification = $false }; safety = @('never copy secrets into skills','preserve outputs/logs/auth','use updater for approved shared changes') } | ConvertTo-Json -Depth 20
  Write-Utf8NoBomFile -Path (Join-Path $common 'skillup_policy.json') -Content ($policyJson + [Environment]::NewLine)
  $queuePath = Join-Path $common 'skillup_approval_queue.json'
  if (-not (Test-Path -LiteralPath $queuePath -PathType Leaf)) { Write-Utf8NoBomFile -Path $queuePath -Content ("[]" + [Environment]::NewLine) }
  $candidateReadme = @"
# $DisplayName v1.9 Skill Candidates

Use this folder for skill ideas proposed by the bot. A candidate is not active until the master approves it and it is installed into .agents/skills.

Recommended candidate format:
1. Skill name
2. Problem it solves
3. Input examples
4. Output examples
5. Checklist
6. Files to update
7. Safety notes
"@
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path $WorkDir '.phoenix_v19\skill_candidates') 'README.md') -Content $candidateReadme
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path $WorkDir '.phoenix_v19\approved_skills') 'README.md') -Content ("# Approved v1.9 Skills" + [Environment]::NewLine + [Environment]::NewLine + "Approved skills wait here before being installed into .agents/skills." + [Environment]::NewLine)
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path $WorkDir '.phoenix_v19\rejected_skills') 'README.md') -Content ("# Rejected v1.9 Skill Ideas" + [Environment]::NewLine + [Environment]::NewLine + "Rejected or deferred ideas are kept here for review history." + [Environment]::NewLine)
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path (Join-Path $common 'skill_creator_prompts') $BotName) 'README.md') -Content ("# $DisplayName PTS prompt notes" + [Environment]::NewLine + [Environment]::NewLine + "Store Skill Creator prompt drafts for this bot here. Do not store secrets." + [Environment]::NewLine)
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path (Join-Path $common 'record_replay_guides') $BotName) 'README.md') -Content ("# $DisplayName PCS notes" + [Environment]::NewLine + [Environment]::NewLine + "Store reviewed Record & Replay notes here. macOS recording is the primary official PCS path. Do not store secrets." + [Environment]::NewLine)
  $block = @"
## Phoenix Agent v1.9 PCS/PTS Skill-Up

This bot is part of Phoenix Agent v1.9.

PCS (Phoenix Copy Skill): a screen-and-workflow based skill-up path. Use it when the user can demonstrate the actual workflow, screen sequence, click/input order, upload/download path, folder operation, tool operation, or repeated business process. The bot must convert the observed flow into a reusable skill candidate, not merely summarize it. A PCS candidate must include the target bot, skill name, demonstrated workflow, screen checkpoints, required inputs, expected output format, success criteria, failure/exception cases, sensitive-information cautions, and concrete skills/examples/checklist updates.

PTS (Phoenix Talk Skill): an example-and-standard based skill-up path. Use it when the user provides strong samples, manuscripts, reports, scripts, prompts, checklists, tone/style rules, or quality criteria. The bot must extract the reasoning pattern, structure, style, quality bar, prohibited patterns, and reusable prompts from the sample. A PTS candidate must include the target bot, skill name, sample characteristics, desired output format, style rules, structure order, quality checklist, bad-output patterns, prohibited behaviors, and concrete skills/examples/checklist updates.

How to respond when asked for PCS/PTS consultation:
- First explain whether PCS, PTS, or a mixed approach is more suitable.
- Ask for missing materials before producing a final skill candidate.
- Produce a candidate that an external AI or Codex Skill Creator can understand without prior context.
- Separate the proposed changes into skills, examples, and checklist.
- State exactly which files should be updated after master approval.

Operating rule:
- Propose skill candidates in .phoenix_v19/skill_candidates.
- Keep approved candidates in .phoenix_v19/approved_skills until the master approves installation.
- Install active Codex skills only under .agents/skills after approval.
- Never place tokens, API keys, OAuth credentials, raw .env values, or private chat ids inside skills.
"@
  $start = '<!-- PHOENIX_v19_PCS_PTS_START -->'
  $end = '<!-- PHOENIX_v19_PCS_PTS_END -->'
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'IDENTITY.md') -Start $start -End $end -Body $block -DefaultTitle "# $DisplayName Identity"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'AGENTS.md') -Start $start -End $end -Body $block -DefaultTitle "# $DisplayName Agent Guide"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'SOUL.md') -Start $start -End $end -Body $block -DefaultTitle "# $DisplayName SOUL"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'USER.md') -Start $start -End $end -Body $block -DefaultTitle "# USER"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'HEARTBEAT.md') -Start $start -End $end -Body $block -DefaultTitle "# HEARTBEAT"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'skills\SKILL.md') -Start $start -End $end -Body $block -DefaultTitle "# Skills"
  Write-Host "  OK ${DisplayName}: Phoenix Agent v1.9 PCS/PTS skill-up structure installed." -ForegroundColor Green
}
function Write-PhoenixJsonNoBom {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 80
  [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Write-PhoenixReleaseMarker {
  param([string[]]$Bots)

  $marker = [ordered]@{
    releaseVersion = $PhoenixReleaseVersion
    updaterPackageDate = "260702"
    supportedUpgradeFrom = $PhoenixSupportedUpgradeFrom
    appliedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    bots = $Bots
    preserves = @("Telegram token/chat id", "model auth mode", "OAuth/API key values", "outputs", "logs")
    updaterRole = "preserve existing installs and upgrade v1.6/v1.7/v1.7_260619/v1.7_260626/v1.8/v1.8_260625 to v1.9_260702 with PCS/PTS skill-up structure"
  }

  Write-PhoenixJsonNoBom -Path (Join-Path $root "PHOENIX_AGENT_RELEASE.json") -Value $marker
  foreach ($bot in $Bots) {
    $workDir = Get-PhoenixWorkDir -Bot $bot
    if (Test-Path -LiteralPath $workDir -PathType Container) {
      Write-PhoenixJsonNoBom -Path (Join-Path $workDir "PHOENIX_AGENT_RELEASE.json") -Value $marker
    }
  }
  Write-Host "  Release marker written: $PhoenixReleaseVersion. Upgrade sources accepted: $($PhoenixSupportedUpgradeFrom -join ', ')"
}

function Disable-PhoenixInternalTelegramHeartbeat {
  param([string[]]$Bots)
  Write-Host ""
  Write-Host "[2c/5] Disabling internal OpenClaw Telegram heartbeat" -ForegroundColor Cyan
  foreach ($bot in $Bots) {
    $profileDirs = @(
      (Join-Path $env:USERPROFILE ".openclaw-pw_$($bot)_bot"),
      (Join-Path $env:USERPROFILE ".openclaw-pw_$bot")
    )
    $updated = $false
    foreach ($profileDir in $profileDirs) {
      $configPath = Join-Path $profileDir "openclaw.json"
      if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }
      try {
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $cfg.agents) { $cfg | Add-Member -Force NoteProperty agents ([pscustomobject]@{}) }
        if (-not $cfg.agents.defaults) { $cfg.agents | Add-Member -Force NoteProperty defaults ([pscustomobject]@{}) }
        $heartbeatProperty = $cfg.agents.defaults.PSObject.Properties["heartbeat"]
        if ($heartbeatProperty) {
          $cfg.agents.defaults.PSObject.Properties.Remove("heartbeat")
        }
        Write-PhoenixJsonNoBom -Path $configPath -Value $cfg
        $updated = $true
      } catch {
        Write-Host "  WARN ${bot}: openclaw.json heartbeat update failed; rerun updater after checking profile JSON." -ForegroundColor Yellow
      }
    }
    if ($updated) {
      Write-Host "  OK ${bot}: internal heartbeat disabled; external proactive runner remains active"
    } else {
      Write-Host "  WARN ${bot}: profile openclaw.json not found for heartbeat update" -ForegroundColor Yellow
    }
  }
}

function Test-Phoenixv19FeatureUpgrade {
  param([string[]]$Bots)
  $requiredFiles = @(
    "IDENTITY.md",
    "AGENTS.md",
    "SOUL.md",
    "USER.md",
    "HEARTBEAT.md",
    "skills\SKILL.md"
  )
  $requiredFeatureMarkers = @(
    "ready_start_suggestion",
    "idle_summary",
    "trend_digest",
    "skill_learning_guidance",
    "skill_work_offer",
    "skill_upgrade_request"
  )
  $allOk = $true

  Write-Host ""
  Write-Host "[4/5] v1.9 PCS/PTS feature upgrade audit" -ForegroundColor Cyan

  if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
    Write-Host "  WARN runner: Phoenix_Proactive_Nudge.cjs missing" -ForegroundColor Yellow
    $allOk = $false
  } else {
    $runnerText = Get-Content -LiteralPath $dest -Raw -Encoding UTF8
    $runnerMissing = @($requiredFeatureMarkers | Where-Object { $runnerText -notmatch [regex]::Escape($_) })
    if ($runnerMissing.Count -gt 0) {
      Write-Host "  WARN runner: missing v1.9 marker(s): $($runnerMissing -join ', ')" -ForegroundColor Yellow
      $allOk = $false
    } else {
      Write-Host "  OK runner: proactive feature markers present"
    }
  }

  $rootReleaseMarker = Join-Path $root "PHOENIX_AGENT_RELEASE.json"
  if (-not (Test-Path -LiteralPath $rootReleaseMarker -PathType Leaf)) {
    Write-Host "  WARN root: PHOENIX_AGENT_RELEASE.json missing" -ForegroundColor Yellow
    $allOk = $false
  } else {
    $rootMarkerText = Get-Content -LiteralPath $rootReleaseMarker -Raw -Encoding UTF8
    if ($rootMarkerText -notmatch [regex]::Escape($PhoenixReleaseVersion)) {
      Write-Host "  WARN root: release marker is not $PhoenixReleaseVersion" -ForegroundColor Yellow
      $allOk = $false
    } else {
      Write-Host "  OK root: release marker $PhoenixReleaseVersion present"
    }
  }

  foreach ($bot in $Bots) {
    $workDir = Get-PhoenixWorkDir -Bot $bot
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
      Write-Host "  WARN ${bot}: work folder missing; feature upgrade could not be applied" -ForegroundColor Yellow
      $allOk = $false
      continue
    }

    $missingFiles = @()
    $combined = ""
    foreach ($rel in $requiredFiles) {
      $file = Join-Path $workDir $rel
      if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $missingFiles += $rel
        continue
      }
      $combined += "`n" + (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    }

    $botReleaseMarker = Join-Path $workDir "PHOENIX_AGENT_RELEASE.json"
    if (-not (Test-Path -LiteralPath $botReleaseMarker -PathType Leaf)) {
      Write-Host "  WARN ${bot}: PHOENIX_AGENT_RELEASE.json missing" -ForegroundColor Yellow
      $allOk = $false
    } else {
      $botMarkerText = Get-Content -LiteralPath $botReleaseMarker -Raw -Encoding UTF8
      if ($botMarkerText -notmatch [regex]::Escape($PhoenixReleaseVersion)) {
        Write-Host "  WARN ${bot}: release marker is not $PhoenixReleaseVersion" -ForegroundColor Yellow
        $allOk = $false
      }
    }

    $missingMarkers = @($requiredFeatureMarkers | Where-Object { $combined -notmatch [regex]::Escape($_) })
    if ($missingFiles.Count -gt 0 -or $missingMarkers.Count -gt 0) {
      if ($missingFiles.Count -gt 0) {
        Write-Host "  WARN ${bot}: missing file(s): $($missingFiles -join ', ')" -ForegroundColor Yellow
      }
      if ($missingMarkers.Count -gt 0) {
        Write-Host "  WARN ${bot}: missing v1.9 marker(s): $($missingMarkers -join ', ')" -ForegroundColor Yellow
      }
      $allOk = $false
    } else {
      Write-Host "  OK ${bot}: v1.9 identity, proactive policy, PCS/PTS folders, and skill-up markers applied"
    }
  }

  if ($allOk) {
    Write-Host "  v1.9 PCS/PTS feature upgrade audit: OK" -ForegroundColor Green
  } else {
    Write-Host "  v1.9 PCS/PTS feature upgrade audit: review warnings above" -ForegroundColor Yellow
  }
  return $allOk
}

function Apply-PhoenixModelFallbackConfig {
  param([string[]]$Bots)
  if (-not (Test-Path -LiteralPath $fallbackSrc -PathType Leaf)) {
    Write-Host "  WARNING: model fallback helper is missing: $fallbackSrc" -ForegroundColor Yellow
    return
  }
  foreach ($bot in $Bots) {
    $workDir = Get-PhoenixWorkDir -Bot $bot
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
      Write-Host "  WARNING: $bot work folder missing; fallback config skipped." -ForegroundColor Yellow
      continue
    }
    $display = (Get-Culture).TextInfo.ToTitleCase($bot) + " Bot"
    $pm2Name = $knownBotProcesses[$bot]
    $fallbackOut = & node $fallbackSrc --mode update --input-dir $PSScriptRoot --workdir $workDir --bot $bot --display $display --profile $pm2Name 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Model fallback config failed for $bot. Output: $($fallbackOut | Out-String)"
    }
    try {
      $fallbackInfo = ($fallbackOut | Out-String | ConvertFrom-Json)
      Write-Host "  ${bot}: fallback config refreshed. Gemini configured=$($fallbackInfo.geminiConfigured), Local LLM configured=$($fallbackInfo.localConfigured). Values were not printed."
      if ($fallbackInfo.warnings -and $fallbackInfo.warnings.Count -gt 0) {
        Write-Host "  ${bot}: WARNING $($fallbackInfo.warnings -join '; ')" -ForegroundColor Yellow
      }
    } catch {
      Write-Host "  ${bot}: fallback config refreshed. Values were not printed."
    }
  }
}

function Install-PhoenixStartupRunner {
  param([string]$ReadyScriptPath)
  $startupDir = [Environment]::GetFolderPath("Startup")
  if ([string]::IsNullOrWhiteSpace($startupDir)) {
    Write-Host "WARNING: Windows Startup folder was not found. Reboot auto-start was not registered." -ForegroundColor Yellow
    return
  }
  if (-not (Test-Path -LiteralPath $startupDir -PathType Container)) {
    New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
  }
  $vbsPath = Join-Path $startupDir "Phoenix_PM2_Stealth.vbs"
  $readyEscaped = $ReadyScriptPath.Replace('"', '""')
  $vbs = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c pm2 resurrect", 0, False
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$readyEscaped""", 0, False
"@
  Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
  Write-Host "Reboot auto-start registered: $vbsPath"
}

if ((Split-Path -Leaf $PSScriptRoot) -ne "updater") {
  Write-Host "WARNING: This script is expected to run from the package updater folder. Current script folder: $PSScriptRoot" -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath $root)) {
  throw "OpenClaw workspace not found: $root. If the previous install failed or was deleted, run the v1.9 installer. If you are using another Windows account, switch to the account where the bots were installed."
}
if (-not (Test-Path -LiteralPath $src)) {
  throw "Missing updater payload: $src"
}
if (-not (Test-Path -LiteralPath $repairSrc)) {
  throw "Missing updater payload: $repairSrc"
}
if (-not (Test-Path -LiteralPath $fallbackSrc)) {
  throw "Missing updater payload: $fallbackSrc"
}
Ensure-PhoenixRuntime
$targetBots = Test-PhoenixInstalledTarget
$targetPm2Names = @()
foreach ($targetBot in $targetBots) {
  $pm2Name = $knownBotProcesses[$targetBot]
  if (-not [string]::IsNullOrWhiteSpace($pm2Name)) { $targetPm2Names += $pm2Name }
}

Copy-Item -LiteralPath $src -Destination $dest -Force
& node --check $dest | Out-Null
& node --check $repairSrc | Out-Null
if (Test-Path -LiteralPath $readySrc) {
  Copy-Item -LiteralPath $readySrc -Destination $readyDest -Force
  $parseErrors = $null
  $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $readyDest -Raw -Encoding UTF8), [ref]$parseErrors)
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw "Phoenix_Ready_Notice.ps1 parser check failed after copy."
  }
  Install-PhoenixStartupRunner -ReadyScriptPath $readyDest
}

Write-Host ""
Write-Host "[1/5] Repairing OpenAI/Codex OAuth routing" -ForegroundColor Cyan
$openaiRepairBots = @()
foreach ($targetBot in $targetBots) {
  if ((Get-PhoenixBotAuthMode -Bot $targetBot) -eq "gemini") {
    Write-Host "  SKIP ${targetBot}: Gemini selected-auth mode detected; OpenAI/Codex repair will not overwrite it." -ForegroundColor Yellow
  } else {
    $openaiRepairBots += $targetBot
  }
}
if ($openaiRepairBots.Count -gt 0) {
  Ensure-PhoenixCodexCliFirstAuth
  Write-Host "  Codex provider plugin check is handled by phoenix_v19_auth_order_repair.cjs to avoid duplicate OpenClaw plugin installs." -ForegroundColor DarkGray
  foreach ($repairBot in $openaiRepairBots) {
    & node $repairSrc --bot $repairBot
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  WARNING: v1.9 OpenAI/Codex OAuth repair reported an issue for $repairBot. Continuing with config refresh, PM2 restart, and final checks." -ForegroundColor Yellow
      Write-Host "  If replies still fail after this updater, run codex login in this same terminal and rerun the updater." -ForegroundColor Yellow
    }
  }
} else {
  Write-Host "  All selected bots use Gemini selected-auth; OpenAI/Codex OAuth repair skipped." -ForegroundColor Green
}

Write-Host ""
Write-Host "[2/5] Upgrading bots to Phoenix Agent v1.9 proactive + PCS/PTS features" -ForegroundColor Cyan
& node $dest --apply-identity-only --bot $BotName | Out-Null
foreach ($targetBot in $targetBots) {
  $workDir = Get-PhoenixWorkDir -Bot $targetBot
  if (Test-Path -LiteralPath $workDir -PathType Container) {
    $display = switch ($targetBot) {
      "genesis" { "Genesis Bot" }
      "power" { "Power Bot" }
      "design" { "Design Bot" }
      "video" { "Video Bot" }
      "writer" { "Writer Bot" }
      default { ((Get-Culture).TextInfo.ToTitleCase($targetBot) + " Bot") }
    }
    Install-Phoenixv19SkillupStructure -RootDir $root -WorkDir $workDir -BotName $targetBot -DisplayName $display -BotId $knownBotProcesses[$targetBot]
  }
}

Write-Host ""
Write-Host "[2b/5] Refreshing explicit model fallback configuration" -ForegroundColor Cyan
Apply-PhoenixModelFallbackConfig -Bots $targetBots
Disable-PhoenixInternalTelegramHeartbeat -Bots $targetBots
Write-PhoenixReleaseMarker -Bots $targetBots

$botProcesses = @()
foreach ($targetBot in $targetBots) {
  $botProcess = $knownBotProcesses[$targetBot]
  if ([string]::IsNullOrWhiteSpace($botProcess)) { continue }
  if (Start-OrRestartPhoenixBot -Bot $targetBot -Pm2Name $botProcess) {
    $botProcesses += $botProcess
  }
}

foreach ($botProcess in $botProcesses) { Test-PhoenixPortOwnerMatchesPm2 -Pm2Name $botProcess | Out-Null }
Test-PhoenixGatewayOperatorScope -Pm2Names $botProcesses

Invoke-PhoenixExternal -Command "pm2" -Arguments @("delete", "phoenix_proactive_nudge") -IgnoreErrors | Out-Null
Invoke-PhoenixExternal -Command "pm2" -Arguments @("start", $dest, "--name", "phoenix_proactive_nudge") | Out-Null
Invoke-PhoenixExternal -Command "pm2" -Arguments @("save", "--force") -IgnoreErrors | Out-Null

if (Test-Path -LiteralPath $readyDest) {
  Write-Host ""
  Write-Host "[3/5] Sending refreshed Telegram ready notices" -ForegroundColor Cyan
  if ($env:PHOENIX_UPDATER_SKIP_READY_NOTICE -eq "1") {
    Write-Host "  Skipped by PHOENIX_UPDATER_SKIP_READY_NOTICE=1. Normal user runs do not set this." -ForegroundColor Yellow
  } else {
    $oldReadyInitialDelay = $env:PHOENIX_READY_INITIAL_DELAY_SECONDS
    $oldReadyTimeout = $env:PHOENIX_READY_TIMEOUT_MINUTES
    try {
      $env:PHOENIX_READY_INITIAL_DELAY_SECONDS = "5"
      $env:PHOENIX_READY_TIMEOUT_MINUTES = "2"
      powershell -ExecutionPolicy Bypass -File $readyDest
    } finally {
      $env:PHOENIX_READY_INITIAL_DELAY_SECONDS = $oldReadyInitialDelay
      $env:PHOENIX_READY_TIMEOUT_MINUTES = $oldReadyTimeout
    }
  }
}

Test-Phoenixv19FeatureUpgrade -Bots $targetBots | Out-Null

Write-Host ""
Write-Host "Update complete." -ForegroundColor Green
Write-Host "Installed runner: $dest"
Write-Host "PM2 process: phoenix_proactive_nudge"
if ($botProcesses.Count -gt 0) {
  Write-Host "Bot PM2 processes refreshed: $($botProcesses -join ', ')"
} else {
  Write-Host "Bot PM2 processes refreshed: none found for target $BotName" -ForegroundColor Yellow
  Write-Host "If this bot should be installed, run the v1.9 installer or check that you are in the same Windows user account where the previous Phoenix Agent was installed." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "[5/5] PM2 status" -ForegroundColor Cyan
Invoke-PhoenixExternal -Command "pm2" -Arguments @("list") -IgnoreErrors
Write-Host ""
Write-Host "Recent proactive log" -ForegroundColor Cyan
$logPath = Join-Path $root "logs\phoenix_proactive_nudge.log"
if (Test-Path -LiteralPath $logPath -PathType Leaf) {
  Get-Content -LiteralPath $logPath -Tail 40
} else {
  Write-Host "Log file not found yet: $logPath"
  Write-Host "This can be normal right after the first updater run."
}
Write-Host ""
Write-Host "Normal log examples: ok genesis: no nudge due / sent genesis: ready_start_suggestion"
Write-Host "$PhoenixReleaseVersion upgrade markers: trend_digest / skill_learning_guidance / skill_work_offer / skill_upgrade_request / PHOENIX_v19_PCS_PTS / PHOENIX_AGENT_RELEASE.json"
Write-Host "If 'telegram target missing' repeats, report the log without exposing secret values." -ForegroundColor Yellow
Write-Host "If model replies fail later, run codex login in this same coding-agent terminal, then rerun this updater so OpenAI OAuth is imported again." -ForegroundColor Yellow
