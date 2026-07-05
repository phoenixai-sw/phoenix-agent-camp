# Phoenix package release: v2.0_260706
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$helper = Join-Path $PSScriptRoot "phoenix_agent_oauth_helpers.ps1"
if (-not (Test-Path -LiteralPath $helper)) { throw "Missing helper: $helper" }
. $helper

function Test-PhoenixTelegramToken {
  param([string]$Token)
  return ($Token -match '^\d{6,}:[A-Za-z0-9_-]{20,}$')
}

function Test-PhoenixTelegramChatId {
  param([string]$ChatId)
  return ($ChatId -match '^-?\d+$')
}

function Confirm-PhoenixTelegramTokenOwner {
  param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$DisplayName
  )

  try {
    $result = Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/getMe" -Method Get -TimeoutSec 10 -ErrorAction Stop
  } catch {
    Write-Host "  WARNING: Telegram getMe check failed. Continue only if telegram_access_token.txt is this bot's BotFather token." -ForegroundColor Yellow
    return
  }

  if (-not $result.ok -or -not $result.result) {
    Write-Host "  WARNING: Telegram getMe check did not return bot identity. Check telegram_access_token.txt before continuing." -ForegroundColor Yellow
    return
  }

  $username = if ($result.result.username) { $result.result.username } else { "unknown" }
  $firstName = if ($result.result.first_name) { $result.result.first_name } else { "unknown" }
  Write-Host "  Telegram token points to: @$username ($firstName)"
  Write-Host "  Confirm this is the BotFather token for $DisplayName, not a previous bot's token." -ForegroundColor Yellow
  $answer = Read-Host "Action: continue with this Telegram bot? [Y/n]"
  if ($answer -match '^[Nn]$') {
    throw "Replace telegram_access_token.txt with the correct BotFather token for $DisplayName, then rerun."
  }
}

function Write-Utf8NoBomFile {
  param([string]$Path, [string]$Content)
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Read-PhoenixInstallerTextFile {
  param(
    [Parameter(Mandatory=$true)][string]$FileName,
    [switch]$DeleteAfterRead
  )

  $path = Join-Path $PSScriptRoot $FileName
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  $value = (Get-Content -LiteralPath $path -Raw).Trim()
  if ($DeleteAfterRead) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  return $value
}

function Show-PhoenixSecretFileInstructions {
  Write-Host ""
  Write-Host "Installer input rules" -ForegroundColor Yellow
  Write-Host "  Run the installer once. If a required value file is missing, the installer stops and tells you which one-line file is missing."
  Write-Host "  Sensitive values are received through one-line text files. Token/API key/OAuth credential values are never printed."
  Write-Host "  Fill Telegram/image/video one-line files in the package root input template folder, then copy/move only filled files into the installer folder before running:"
  Write-Host "    telegram_access_token.txt : Telegram BotFather token for this bot."
  Write-Host "    telegram_chat_id.txt          : Telegram numeric chat id for ready/proactive messages."
  Write-Host "    openai_api_key_image.txt : optional image-generation key for Design/Writer."
  Write-Host "    falai_api_key_video.txt  : optional fal.ai key for Video."
  Write-Host "  Put Gemini/local LLM fallback files only in the package root 2. ?紐꾩쵄???癒?뵠?袁る뱜 筌뤴뫀???紐꾩쵄 ??筌뤴뫁??folder:"
  Write-Host "    gemini_api_key.txt, gemini_model.txt, local_llm_base_url.txt, local_llm_model.txt, local_llm_api_key.txt"
  Write-Host "    Telegram pairing code: after Telegram shows a pairing code, fill telegram_pairing_code.txt in the input folder, move it into installer, and approve it with the helper."
  Write-Host "  After use, the installer asks whether to delete only copied files in the installer folder. Root auth-key folders are source templates and are preserved."
}

function Show-PhoenixTelegramSetupFlow {
  Write-Host ""
  Write-Host "Telegram setup and pairing order" -ForegroundColor Yellow
  Write-Host "  1. In Telegram, open BotFather, create this bot, and copy the Bot Token."
  Write-Host "  2. Run this installer after moving the filled telegram_access_token.txt into the installer folder. The value is received from the file and never printed."
  Write-Host "  3. Move the filled telegram_chat_id.txt into the installer folder before running. The value is received from the file and never printed."
  Write-Host "  4. The installer registers Telegram in OpenClaw with the bot token."
  Write-Host "  5. In Telegram, send /start to this bot first. Telegram allows proactive bot messages only after the user has messaged the bot."
  Write-Host "  6. Send a short message to the bot. If a pairing code appears, fill telegram_pairing_code.txt with only that code and move it into the installer folder."
  Write-Host "  7. Approve the pairing code from telegram_pairing_code.txt with: powershell -ExecutionPolicy Bypass -File .\approve_pairing_code.ps1 -BotName <bot>"
  Write-Host "  8. After pairing, PM2 and the gateway become live; the bot wakes up."
  Write-Host "  9. The bot sends a ready-complete message to telegram_chat_id.txt when health is live."
  Write-Host " 10. After the ready message, send /new, wait 10-20 seconds, then send a short status-check message."
}
function Confirm-PhoenixDeleteInstallerFile {
  param([Parameter(Mandatory=$true)][string]$FileName)

  $path = Join-Path $PSScriptRoot $FileName
  if (-not (Test-Path -LiteralPath $path)) { return }
  $answer = Read-Host "Action: delete $FileName from installer folder now for security? [Y/n]"
  if ($answer -notmatch '^[Nn]$') {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Write-Host "  OK: $FileName deleted from installer folder." -ForegroundColor Green
  } else {
    Write-Host "  SECURITY WARNING: $FileName remains in the installer folder." -ForegroundColor Yellow
    Write-Host "  Delete $path manually after installation if you do not need to keep it." -ForegroundColor Yellow
  }
}

function Get-PhoenixEnvValue {
  param([string[]]$Names)
  foreach ($name in $Names) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
  }
  return ""
}

function Get-PhoenixAgentAuthDir {
  $root = Split-Path -Parent $PSScriptRoot
  $canonical = Join-Path $root '2. 인증키_에이전트 모델 인증 키 모음'
  if (Test-Path -LiteralPath $canonical -PathType Container) { return $canonical }
  $match = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '2.*인증키*에이전트*모델*인증*키*모음*' } |
    Select-Object -First 1
  if ($match) { return $match.FullName }
  return $canonical
}

function Read-PhoenixModelAuthFile {
  param([Parameter(Mandatory=$true)][string]$FileName)
  foreach ($dir in @($PSScriptRoot, $script:PhoenixAgentAuthDir)) {
    if ([string]::IsNullOrWhiteSpace($dir)) { continue }
    $path = Join-Path $dir $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    return ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -replace "^\uFEFF", "").Trim()
  }
  return ""
}

function Test-PhoenixGeminiApiKeyAvailable {
  return -not [string]::IsNullOrWhiteSpace((Read-PhoenixModelAuthFile -FileName 'gemini_api_key.txt'))
}

function Write-PhoenixGeminiOpenClawConfig {
  param(
    [Parameter(Mandatory=$true)][string]$ProfileDir,
    [Parameter(Mandatory=$true)][int]$Port,
    [Parameter(Mandatory=$true)][string]$Model
  )
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  $gatewayToken = -join ($bytes | ForEach-Object { $_.ToString("x2") })
  $config = [ordered]@{
    gateway = [ordered]@{ mode = 'local'; port = $Port; auth = [ordered]@{ mode = 'token'; token = $gatewayToken } }
    agents = [ordered]@{
      defaults = [ordered]@{
        model = [ordered]@{ primary = "google/$Model" }
      }
    }
  }
  Write-PhoenixJsonNoBom -Path (Join-Path $ProfileDir 'openclaw.json') -Value $config
}

function Set-PhoenixGatewayAuthToken {
  param([Parameter(Mandatory=$true)][string]$ProfileDir)
  $configPath = Join-Path $ProfileDir 'openclaw.json'
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return }
  try { $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = [pscustomobject]@{} }
  if (-not $cfg.gateway) { $cfg | Add-Member -Force NoteProperty gateway ([pscustomobject]@{}) }
  if (-not $cfg.gateway.auth) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    $cfg.gateway | Add-Member -Force NoteProperty auth ([pscustomobject]@{ mode = 'token'; token = $token })
  } else {
    if (-not $cfg.gateway.auth.mode) { $cfg.gateway.auth | Add-Member -Force NoteProperty mode 'token' }
    if (-not $cfg.gateway.auth.token) {
      $bytes = New-Object byte[] 32
      [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
      $token = -join ($bytes | ForEach-Object { $_.ToString("x2") })
      $cfg.gateway.auth | Add-Member -Force NoteProperty token $token
    }
  }
  Write-PhoenixJsonNoBom -Path $configPath -Value $cfg
}

function Test-PhoenixTelegramConfigured {
  param([string]$Profile)
  try {
    $out = (openclaw channels list --profile $Profile) 2>&1 | Out-String
    return ($out -match '(?i)telegram' -and $out -notmatch 'no configured chat channels')
  } catch {
    return $false
  }
}

function Register-PhoenixTelegramChannel {
  param(
    [Parameter(Mandatory=$true)][string]$Profile,
    [Parameter(Mandatory=$true)][string]$Token
  )

  openclaw channels add --channel telegram --token $Token --profile $Profile | Out-Null
  Start-Sleep -Seconds 1

  if (-not (Test-PhoenixTelegramConfigured -Profile $Profile)) {
    Write-Host "  Telegram channel was not fully configured. Re-registering once..." -ForegroundColor Yellow
    try { openclaw channels remove --channel telegram --delete --profile $Profile 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 1
    openclaw channels add --channel telegram --token $Token --profile $Profile | Out-Null
  }

  if (-not (Test-PhoenixTelegramConfigured -Profile $Profile)) {
    throw "Telegram channel registration did not become configured. Rerun: openclaw channels add --channel telegram --token <TOKEN> --profile $Profile"
  }

  try {
    openclaw channels status --profile $Profile --deep 2>&1 | Out-Null
  } catch {}
}

function Send-PhoenixTelegramReadyNotice {
  param(
    [string]$Token,
    [string]$ChatId,
    [string]$BotId,
    [string]$DisplayName,
    [int]$Port
  )

  if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)) { return }
  $templateBase64 = "7KO87J2464uYLCB7MH0g7KSA67mEIOyZhOujjOyeheuLiOuLpC4KUE0yOiB7MX0KR2F0ZXdheTogaHR0cDovLzEyNy4wLjAuMTp7Mn0vaGVhbHRoCuydtOygnCBUZWxlZ3JhbeyXkOyEnCAvbmV3IO2bhCAxMH4yMOy0iCDrkqQg7IOB7YOcIO2ZleyduCDrqZTsi5zsp4Drpbwg67O064K07IWU64+EIOuQqeuLiOuLpC4="
  $template = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($templateBase64))
  $text = [string]::Format($template, $DisplayName, $BotId, $Port)
  try {
    $payload = @{ chat_id = $ChatId; text = $text } | ConvertTo-Json -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/sendMessage" -ContentType "application/json; charset=utf-8" -Body $body -TimeoutSec 10 | Out-Null
    Write-Host "  OK: Telegram ready notice sent." -ForegroundColor Green
    return $true
  } catch {
    Write-Host "  WARNING: Telegram ready notice failed. Make sure the user has messaged this bot at least once." -ForegroundColor Yellow
    return $false
  }
}

function Set-PhoenixProactiveHeartbeatConfig {
  param(
    [string]$ProfileDir,
    [string]$ChatId
  )
  if ([string]::IsNullOrWhiteSpace($ChatId)) { return }
  $configPath = Join-Path $ProfileDir 'openclaw.json'
  if (-not (Test-Path -LiteralPath $configPath)) { return }
  try { $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { return }
  if (-not $cfg.agents) { $cfg | Add-Member -Force NoteProperty agents ([pscustomobject]@{}) }
  if (-not $cfg.agents.defaults) { $cfg.agents | Add-Member -Force NoteProperty defaults ([pscustomobject]@{}) }
  $heartbeatProperty = $cfg.agents.defaults.PSObject.Properties['heartbeat']
  if ($heartbeatProperty) {
    $cfg.agents.defaults.PSObject.Properties.Remove('heartbeat')
  }
  Write-PhoenixJsonNoBom -Path $configPath -Value $cfg
}

function Install-PhoenixProactiveNudgeRunner {
  param([Parameter(Mandatory=$true)][string]$RootDir)
  $src = Join-Path $PSScriptRoot 'phoenix_proactive_nudge.cjs'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "  WARNING: phoenix_proactive_nudge.cjs missing; proactive nudge runner was not installed." -ForegroundColor Yellow
    return
  }
  New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
  $dest = Join-Path $RootDir 'Phoenix_Proactive_Nudge.cjs'
  Copy-Item -LiteralPath $src -Destination $dest -Force
  Invoke-PhoenixExternal -Command "pm2" -Arguments @("delete", "phoenix_proactive_nudge") -IgnoreErrors *> $null
  Invoke-PhoenixExternal -Command "pm2" -Arguments @("start", $dest, "--name", "phoenix_proactive_nudge") *> $null
  Write-Host "  OK: Phoenix proactive nudge runner installed in PM2." -ForegroundColor Green
}

function Install-PhoenixReadyNoticeScript {
  param([Parameter(Mandatory=$true)][string]$RootDir)
  $src = Join-Path $PSScriptRoot 'Phoenix_Ready_Notice.ps1'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "  WARNING: Phoenix_Ready_Notice.ps1 missing; reboot ready notice helper was not installed." -ForegroundColor Yellow
    return
  }
  New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
  $dest = Join-Path $RootDir 'Phoenix_Ready_Notice.ps1'
  Copy-Item -LiteralPath $src -Destination $dest -Force
  $parseErrors = $null
  $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $dest -Raw -Encoding UTF8), [ref]$parseErrors)
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw "Phoenix_Ready_Notice.ps1 parser check failed after install."
  }
  Write-Host "  OK: Reboot ready notice helper installed." -ForegroundColor Green
}

function Install-PhoenixStartupRunner {
  param([Parameter(Mandatory=$true)][string]$RootDir)

  $startupDir = [Environment]::GetFolderPath('Startup')
  if ([string]::IsNullOrWhiteSpace($startupDir)) {
    Write-Host "  WARNING: Windows Startup folder was not found; reboot auto-start was not installed." -ForegroundColor Yellow
    return
  }

  $readyScript = Join-Path $RootDir 'Phoenix_Ready_Notice.ps1'
  New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
  $startupFile = Join-Path $startupDir 'Phoenix_PM2_Stealth.vbs'
  $readyEsc = $readyScript.Replace('"', '""')
  $content = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c pm2 resurrect", 0, False
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$readyEsc""", 0, False
"@
  Write-Utf8NoBomFile -Path $startupFile -Content $content
  Write-Host "  OK: Windows reboot auto-start registered: Phoenix_PM2_Stealth.vbs" -ForegroundColor Green
}

function Invoke-PhoenixAuthOrderRepair {
  param([Parameter(Mandatory=$true)][string]$BotName)
  $src = Join-Path $PSScriptRoot 'phoenix_v20_auth_order_repair.cjs'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "  WARNING: auth order repair payload missing; skipping auth order repair." -ForegroundColor Yellow
    return
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "  WARNING: node command not found; skipping auth order repair." -ForegroundColor Yellow
    return
  }
  & node $src --bot $BotName
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: auth order repair could not find a valid Codex OAuth profile yet." -ForegroundColor Yellow
  }
}

function Ensure-PhoenixCodexCliFirstAuth {
  if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw "Codex CLI command is not available after runtime setup. Reopen this coding agent terminal or reinstall Codex CLI, then rerun this installer."
  }
  Write-Host ""
  Write-Host "Codex CLI First Auth Policy" -ForegroundColor Yellow
  Write-Host "  Conversation auth uses OpenAI provider with Codex-imported ChatGPT OAuth: openai/gpt-5.5."
  if (Test-PhoenixCodexCliLogin) {
    Write-Host "  OK: Codex CLI ChatGPT login detected. Reusing it for this bot." -ForegroundColor Green
    return
  }
  Write-Host "  ACTION: Opening codex login. Approve with the ChatGPT subscription account in the browser." -ForegroundColor Cyan
  Write-Host "  Security: OAuth credential values are not printed." -ForegroundColor DarkGray
  Invoke-PhoenixExternal -Command "codex" -Arguments @("login") -IgnoreErrors | Out-Null
  if (-not (Test-PhoenixCodexCliLogin)) {
    throw "Codex CLI ChatGPT login is still not valid. Complete codex login in this same terminal, then rerun this installer."
  }
  Write-Host "  OK: Codex CLI ChatGPT login restored. Continuing installation." -ForegroundColor Green
}

function Write-PhoenixProactiveState {
  param(
    [string]$WorkDir,
    [string]$BotName,
    [string]$DisplayName,
    [string]$BotId,
    [AllowNull()][string]$ReadyNoticeAt
  )
  $stateDir = Join-Path $WorkDir '.openclaw'
  $statePath = Join-Path $stateDir 'phoenix_proactive_state.json'
  New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
  $state = [ordered]@{
    version = 1
    botName = $BotName
    displayName = $DisplayName
    pm2Profile = $BotId
    initializedAt = (Get-Date).ToUniversalTime().ToString('o')
    readyNoticeAt = $ReadyNoticeAt
    firstUserMessageAfterReadyAt = $null
    lastUserMessageAt = $null
    proactiveSends = @()
    settings = [ordered]@{
      idleHours = 3
      readyStartDelayMinutes = 30
      dailyMaxProactiveMessages = 10
      trendDigestDailyMax = 1
      trendDigestHour = 7
      skillLearningGuidanceDailyMax = 1
      skillLearningGuidanceHour = 8
      skillWorkOfferDailyMax = 1
      skillWorkOfferDelayMinutes = 120
      skillUpgradeRequestDailyMax = 1
      skillUpgradeRequestHour = 17
      heartbeatEvery = '30m'
      timezone = 'Asia/Seoul'
    }
  }
  Write-Utf8NoBomFile -Path $statePath -Content (($state | ConvertTo-Json -Depth 12) + "
")
}

function Add-PhoenixMarkedBlock {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Start,
    [Parameter(Mandatory=$true)][string]$End,
    [Parameter(Mandatory=$true)][string]$Body,
    [string]$DefaultTitle = "# Phoenix Agent v2.0"
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
  $common = Join-Path $RootDir 'phoenix_v20'
  $commonDirs = @($common,(Join-Path $common 'skill_creator_prompts'),(Join-Path $common 'record_replay_guides'),(Join-Path $common 'skill_candidates'),(Join-Path $common 'approved_skills'),(Join-Path $common 'rejected_skills'))
  foreach ($base in @('skill_creator_prompts','record_replay_guides','skill_candidates','approved_skills','rejected_skills')) { foreach ($bot in $allBots) { $commonDirs += (Join-Path (Join-Path $common $base) $bot) } }
  $botDirs = @((Join-Path $WorkDir '.agents\skills'),(Join-Path $WorkDir '.phoenix_v20'),(Join-Path $WorkDir '.phoenix_v20\skill_candidates'),(Join-Path $WorkDir '.phoenix_v20\approved_skills'),(Join-Path $WorkDir '.phoenix_v20\rejected_skills'))
  foreach ($dir in ($commonDirs + $botDirs)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  $readme = @"
# Phoenix Agent v2.0 PCS/PTS Skill-Up

Phoenix Agent v2.0 keeps the existing Phoenix runtime features and adds two approved skill-up paths.

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
  $policyJson = @{ release = 'Phoenix Agent v2.0'; pcs = @{ name = 'Phoenix Copy Skill'; officialFeature = 'Codex Record & Replay'; primaryRecordingOs = 'macOS'; windowsPolicy = 'PTS or reviewed import only' }; pts = @{ name = 'Phoenix Talk Skill'; officialFeature = 'Codex Skill Creator'; supportedOs = @('Windows','macOS') }; approval = @{ botsCanSuggest = $true; masterApprovalRequired = $true; directSelfModification = $false }; safety = @('never copy secrets into skills','preserve outputs/logs/auth','use updater for approved shared changes') } | ConvertTo-Json -Depth 20
  Write-Utf8NoBomFile -Path (Join-Path $common 'skillup_policy.json') -Content ($policyJson + [Environment]::NewLine)
  $queuePath = Join-Path $common 'skillup_approval_queue.json'
  if (-not (Test-Path -LiteralPath $queuePath -PathType Leaf)) { Write-Utf8NoBomFile -Path $queuePath -Content ("[]" + [Environment]::NewLine) }
  $candidateReadme = @"
# $DisplayName v2.0 Skill Candidates

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
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path $WorkDir '.phoenix_v20\skill_candidates') 'README.md') -Content $candidateReadme
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path $WorkDir '.phoenix_v20\approved_skills') 'README.md') -Content ("# Approved v2.0 Skills" + [Environment]::NewLine + [Environment]::NewLine + "Approved skills wait here before being installed into .agents/skills." + [Environment]::NewLine)
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path $WorkDir '.phoenix_v20\rejected_skills') 'README.md') -Content ("# Rejected v2.0 Skill Ideas" + [Environment]::NewLine + [Environment]::NewLine + "Rejected or deferred ideas are kept here for review history." + [Environment]::NewLine)
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path (Join-Path $common 'skill_creator_prompts') $BotName) 'README.md') -Content ("# $DisplayName PTS prompt notes" + [Environment]::NewLine + [Environment]::NewLine + "Store Skill Creator prompt drafts for this bot here. Do not store secrets." + [Environment]::NewLine)
  Write-Utf8NoBomFile -Path (Join-Path (Join-Path (Join-Path $common 'record_replay_guides') $BotName) 'README.md') -Content ("# $DisplayName PCS notes" + [Environment]::NewLine + [Environment]::NewLine + "Store reviewed Record & Replay notes here. macOS recording is the primary official PCS path. Do not store secrets." + [Environment]::NewLine)
  $block = @"
## Phoenix Agent v2.0 PCS/PTS Skill-Up

This bot is part of Phoenix Agent v2.0.

PCS (Phoenix Copy Skill): a screen-and-workflow based skill-up path. Use it when the user can demonstrate the actual workflow, screen sequence, click/input order, upload/download path, folder operation, tool operation, or repeated business process. The bot must convert the observed flow into a reusable skill candidate, not merely summarize it. A PCS candidate must include the target bot, skill name, demonstrated workflow, screen checkpoints, required inputs, expected output format, success criteria, failure/exception cases, sensitive-information cautions, and concrete skills/examples/checklist updates.

PTS (Phoenix Talk Skill): an example-and-standard based skill-up path. Use it when the user provides strong samples, manuscripts, reports, scripts, prompts, checklists, tone/style rules, or quality criteria. The bot must extract the reasoning pattern, structure, style, quality bar, prohibited patterns, and reusable prompts from the sample. A PTS candidate must include the target bot, skill name, sample characteristics, desired output format, style rules, structure order, quality checklist, bad-output patterns, prohibited behaviors, and concrete skills/examples/checklist updates.

How to respond when asked for PCS/PTS consultation:
- First explain whether PCS, PTS, or a mixed approach is more suitable.
- Ask for missing materials before producing a final skill candidate.
- Produce a candidate that an external AI or Codex Skill Creator can understand without prior context.
- Separate the proposed changes into skills, examples, and checklist.
- State exactly which files should be updated after master approval.

Operating rule:
- Propose skill candidates in .phoenix_v20/skill_candidates.
- Keep approved candidates in .phoenix_v20/approved_skills until the master approves installation.
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
  Write-Host "  OK ${DisplayName}: Phoenix Agent v2.0 PCS/PTS skill-up structure installed." -ForegroundColor Green
}

function Install-Phoenixv20WebControlStructure {
  param(
    [Parameter(Mandatory=$true)][string]$RootDir,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [Parameter(Mandatory=$true)][string]$BotName,
    [Parameter(Mandatory=$true)][string]$DisplayName,
    [Parameter(Mandatory=$true)][string]$BotId
  )
  $common = Join-Path $RootDir 'phoenix_v20'
  $commonDirs = @(
    $common,
    (Join-Path $common 'shared_v3_protocols'),
    (Join-Path $common 'agent_web_repo_map'),
    (Join-Path $WorkDir '.phoenix_v20'),
    (Join-Path $WorkDir '.phoenix_v20\web_control'),
    (Join-Path $WorkDir '.phoenix_v20\playwright_mcp_notes'),
    (Join-Path $WorkDir '.phoenix_v20\outputs_delivery')
  )
  foreach ($dir in $commonDirs) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  $repoMap = @{
    'phoenix-command' = 'https://github.com/phoenixai-sw/phoenix-command.git'
    'phoenix-pages' = 'https://github.com/phoenixai-sw/phoenix-detail-page.git'
    'phoenix-images' = 'https://github.com/phoenixai-sw/mock-up-image.git'
    'phoenix-slides' = 'https://github.com/phoenixai-sw/phoenix-slides.git'
    'phoenix-webs' = 'https://github.com/phoenixai-sw/phoenix-webs.git'
    'phoenix-books' = 'https://github.com/phoenixai-sw/phoenix-books.git'
    'phoenix-videos' = 'https://github.com/phoenixai-sw/phoenix-videos.git'
    'phoenix-reports' = 'https://github.com/phoenixai-sw/phoenix-reports.git'
    'phoenix-tax' = 'https://github.com/phoenixai-sw/phoenix-tax.git'
    'phoenix-dental' = 'https://github.com/phoenixai-sw/phoenixai_dentala.git'
    'phoenix-marketing' = 'https://github.com/phoenixai-sw/phoenix-marketing.git'
  }
  Write-Utf8NoBomFile -Path (Join-Path $common 'agent_web_repo_map\github_repo_map.json') -Content (($repoMap | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

  Write-Utf8NoBomFile -Path (Join-Path $common 'shared_v3_protocols\bot_task_protocol.md') -Content @"
# Phoenix Agent v2.0 Web Control Task Protocol

Genesis Bot decomposes master requests into structured tasks. Specialist bots control only their assigned agent web.

Never include API keys, Telegram tokens, OAuth credentials, raw .env values, or private chat ids in task payloads.
"@
  Write-Utf8NoBomFile -Path (Join-Path $common 'shared_v3_protocols\delivery_policy.md') -Content @"
# Phoenix Agent v2.0 Delivery Policy

Default result storage is local outputs.
After saving, ask: 텔레그램으로도 결과물을 보실래요?
Telegram direct transfer happens only after the user asks for it.
"@
  Write-Utf8NoBomFile -Path (Join-Path $common 'shared_v3_protocols\approval_policy.md') -Content @"
# Phoenix Agent v2.0 Approval Policy

Master approval is required before video generation, paid credit use, external publishing, tax/dental consultation result delivery, project deletion, or multiple agent webs running together.
"@

  $websites = switch ($BotName) {
    'genesis' { 'phoenix command' }
    'design' { 'phoenix pages, phoenix slides, phoenix webs, phoenix images' }
    'writer' { 'phoenix books' }
    'video' { 'phoenix videos' }
    'power' { 'phoenix reports, phoenix tax, phoenix dental, phoenix marketing' }
    default { 'assigned Phoenix agent web' }
  }
  $role = switch ($BotName) {
    'genesis' { 'decompose master requests, register tasks in phoenix command, route work to specialist bots, track status, and report final results' }
    'design' { 'control visual agent webs for detail pages, slides, landing pages, product images, thumbnails, and card news' }
    'writer' { 'control phoenix books for lecture plans, manuscripts, SNS copy, DOCX/PDF/text outputs' }
    'video' { 'control phoenix videos for storyboards, short-form videos, render status, MP4 outputs, and thumbnail delivery' }
    'power' { 'control reports, tax, dental, and marketing agent webs with general-information safety wording and source/date awareness' }
    default { 'control its assigned Phoenix agent web' }
  }
  $block = @"
## Phoenix Agent v2.0 Web Control Agent

This bot is part of Phoenix Agent v2.0 Web Control Agent.

Assigned agent web:
$websites

Role:
$role

Automation method:
- Use Playwright MCP as the web-control inspection and agent connection layer.
- Prefer stable data-testid selectors when operating agent web screens.

Login/auth rule:
- Agent web login is separate from Phoenix model authentication.
- Never print login secrets, API keys, Telegram tokens, OAuth credentials, raw .env values, or private chat ids.

Result delivery rule:
- Store generated files in local outputs by default.
- After saving, ask: "텔레그램으로도 결과물을 보실래요?"
- Send files to Telegram only after the user asks for Telegram delivery.

Approval rule:
- Ask master approval before video generation, paid credit use, external publishing, tax/dental consultation result delivery, project deletion, or multiple agent webs running together.

Future roadmap:
- v2.0 is Web Control Agent.
- v2.2 is Master Builder Agent and should be proposed after v2.0 is stable.
"@
  $start = '<!-- PHOENIX_v20_WEB_CONTROL_START -->'
  $end = '<!-- PHOENIX_v20_WEB_CONTROL_END -->'
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'IDENTITY.md') -Start $start -End $end -Body $block -DefaultTitle "# $DisplayName Identity"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'AGENTS.md') -Start $start -End $end -Body $block -DefaultTitle "# $DisplayName Agent Guide"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'SOUL.md') -Start $start -End $end -Body $block -DefaultTitle "# $DisplayName SOUL"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'USER.md') -Start $start -End $end -Body $block -DefaultTitle "# USER"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'HEARTBEAT.md') -Start $start -End $end -Body $block -DefaultTitle "# HEARTBEAT"
  Add-PhoenixMarkedBlock -Path (Join-Path $WorkDir 'skills\SKILL.md') -Start $start -End $end -Body $block -DefaultTitle "# Skills"
  Write-Utf8NoBomFile -Path (Join-Path $WorkDir '.phoenix_v20\web_control\README.md') -Content ("# $DisplayName v2.0 Web Control" + [Environment]::NewLine + [Environment]::NewLine + $block + [Environment]::NewLine)
  Write-Host "  OK ${DisplayName}: Phoenix Agent v2.0 web control structure installed." -ForegroundColor Green
}

function Update-PhoenixProactiveReadyState {
  param(
    [string]$WorkDir,
    [string]$BotName,
    [string]$DisplayName,
    [string]$BotId
  )
  Write-PhoenixProactiveState -WorkDir $WorkDir -BotName $BotName -DisplayName $DisplayName -BotId $BotId -ReadyNoticeAt (Get-Date).ToUniversalTime().ToString('o')
}
function Ensure-PhoenixRuntimeToolchain {
  param([string]$Mode)
  Write-Host ""
  Write-Host "Runtime toolchain alignment: $Mode" -ForegroundColor Yellow
  $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if (-not $npm) { throw "npm.cmd not found. Install Node.js LTS and reopen Antigravity terminal." }
  $packages = @('openclaw@latest', '@openclaw/codex@latest', 'clawhub@latest', 'pm2@latest')
  & $npm.Source install -g @packages --loglevel=error
  Update-PhoenixProcessPath
  if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host "  OK: OpenAI Codex CLI found. Skipping Codex CLI npm update to avoid locking the running codex.exe." -ForegroundColor Green
  } else {
    Write-Host "  Installing OpenAI Codex CLI because codex command is missing..." -ForegroundColor Cyan
    & $npm.Source install -g '@openai/codex@latest' --loglevel=error
    Update-PhoenixProcessPath
  }
  foreach ($cmd in @('openclaw','clawhub','codex','pm2')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Required runtime command not found after install: $cmd" }
  }
  Write-Host "  OK: OpenClaw / Codex harness / ClawHub / Codex CLI / PM2 are ready. Existing Codex CLI was preserved when present." -ForegroundColor Green
}

function Install-PhoenixCodexHarnessPlugin {
  param([Parameter(Mandatory=$true)][string]$Profile)
  Write-Host "  Installing/verifying Codex harness plugin for $Profile..." -ForegroundColor Yellow
  $out = (& openclaw --profile $Profile plugins install clawhub:@openclaw/codex) 2>&1 | Out-String
  $code = $LASTEXITCODE
  if ($code -ne 0 -and $out -notmatch '(?i)already|installed|success|ok') {
    throw "Codex harness plugin install failed for $Profile. Output: $out"
  }
  Write-Host "  OK: Codex harness plugin installed/verified for $Profile." -ForegroundColor Green
}

function Test-PhoenixBotRuntimeLogs {
  param([Parameter(Mandatory=$true)][string]$BotId)
  try {
    $log = (pm2 logs $BotId --lines 80 --nostream) 2>&1 | Out-String
    if ($log -match 'Requested agent harness "codex" is not registered|Missing API key for OpenAI|Something went wrong while processing your request') {
      throw "Runtime log check failed for $BotId. Check Codex harness plugin, Codex CLI ChatGPT login, and model provider."
    }
  } catch {
    if ($_.Exception.Message -match 'Runtime log check failed') { throw }
  }
}

function Test-PhoenixGatewayOperatorScope {
  param([Parameter(Mandatory=$true)][string]$BotId)
  $raw = (Invoke-PhoenixExternal -Command "openclaw" -Arguments @("--profile", $BotId, "gateway", "probe", "--json") -IgnoreErrors) | Out-String
  if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "  WARNING ${BotId}: Gateway probe did not return JSON yet." -ForegroundColor Yellow
    return
  }
  if ($raw -match "write_capable" -or (($raw -match "operator\.read") -and ($raw -match "operator\.write"))) {
    Write-Host "  OK ${BotId}: Gateway write capability confirmed." -ForegroundColor Green
  } else {
    Write-Host "  WARNING ${BotId}: Gateway probe did not confirm operator.read/operator.write yet. If Telegram replies are invisible, approve pairing and rerun updater." -ForegroundColor Yellow
  }
}

if (-not $PhoenixBotName) { throw 'PhoenixBotName is not set by wrapper installer.' }

$botName = $PhoenixBotName
$displayName = if ($PhoenixDisplayName) { $PhoenixDisplayName } else { (Get-Culture).TextInfo.ToTitleCase($botName) + ' Bot' }
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
$botId = "pw_${botName}_bot"
$workDir = Join-Path $env:USERPROFILE "antigravity\openclaw\${botName}_bot"
$profileDir = Join-Path $env:USERPROFILE ".openclaw-$botId"
$stateDir = Join-Path $env:USERPROFILE ".openclaw-state\$botId"
$ecosystem = Join-Path $workDir "ecosystem.config.js"
$script:PhoenixAgentAuthDir = Get-PhoenixAgentAuthDir
$authModeRaw = Get-PhoenixEnvValue -Names @('PHOENIX_MODEL_AUTH_MODE','PHOENIX_AUTH_MODE')
if ([string]::IsNullOrWhiteSpace($authModeRaw)) { $authModeRaw = 'openai' }
$authMode = $authModeRaw.Trim().ToLowerInvariant()
if ($authMode -in @('gemini','google','google-gemini','gemini-selected')) { $authMode = 'gemini' } else { $authMode = 'openai' }
$geminiModel = Read-PhoenixModelAuthFile -FileName 'gemini_model.txt'
if ([string]::IsNullOrWhiteSpace($geminiModel)) { $geminiModel = 'gemini-2.5-flash' }
$modelStr = if ($authMode -eq 'gemini') { "google/$geminiModel" } else { 'openai/gpt-5.5' }

Write-Host "Phoenix Agent v2.0 Win11 installer: $displayName" -ForegroundColor Cyan
Write-Host "User decisions during automation:" -ForegroundColor Yellow
if ($authMode -eq 'gemini') {
  Write-Host "  1. Conversation auth: use Gemini API as the selected authentication mode with model $geminiModel. The API key value is never printed."
} else {
  Write-Host "  1. Conversation auth: import Codex CLI ChatGPT login into OpenAI OAuth and use openai/gpt-5.5. API keys are not used for conversation billing."
}
Write-Host "  2. Extra API keys: use only for image/video generation features."
Write-Host "  3. Telegram: create the bot in BotFather. Fill telegram_access_token.txt in 1. ?紐꾩쵄??API ??筌뤴뫁?? then copy/move it into installer before running."
Write-Host "  4. Required stability notice: telegram_chat_id.txt must contain the numeric Telegram chat id. If the file is missing, the installer stops and names it."
Write-Host "     This is an operations alarm. After the gateway health check is live, the bot sends a ready message so users know when it is safe to talk after reboot."
Write-Host "     Telegram can send proactive ready notices only after the user has messaged the bot at least once."
Write-Host "  5. Security: tokens, API keys, and OAuth credentials are never printed."
Show-PhoenixSecretFileInstructions

$preflightTelegramToken = Read-PhoenixInstallerTextFile -FileName 'telegram_access_token.txt'
if (-not $preflightTelegramToken) {
  throw "telegram_access_token.txt was not found or is empty in the installer folder. Fill telegram_access_token.txt in 1. ?紐꾩쵄??API ??筌뤴뫁?? copy/move it into installer, then rerun. Do not paste the token into chat."
}
if (-not (Test-PhoenixTelegramToken $preflightTelegramToken)) {
  throw "Telegram token is present but the format is invalid. Check telegram_access_token.txt."
}
$preflightReadyChatId = Read-PhoenixInstallerTextFile -FileName 'telegram_chat_id.txt'
if (-not $preflightReadyChatId) {
  throw "telegram_chat_id.txt was not found or is empty in the installer folder. Fill telegram_chat_id.txt in 1. ?紐꾩쵄??API ??筌뤴뫁?? copy/move it into installer, then rerun. Do not paste the chat id into chat."
}
if (-not (Test-PhoenixTelegramChatId $preflightReadyChatId)) {
  throw "telegram_chat_id.txt is present but the format is invalid. Use a numeric Telegram chat id."
}
Write-Host "  OK: required Telegram files found and format checked. Values were not printed."
if ($authMode -eq 'gemini') {
  if (-not (Test-PhoenixGeminiApiKeyAvailable)) {
    throw "Gemini selected-auth install was requested, but gemini_api_key.txt was not found or is empty. Put gemini_api_key.txt in installer or in 2. ?紐꾩쵄???癒?뵠?袁る뱜 筌뤴뫀???紐꾩쵄 ??筌뤴뫁?? then rerun. Do not paste the key into chat."
  }
  Write-Host "  OK: Gemini API key file found for Gemini selected-auth install. Value was not printed." -ForegroundColor Green
  Write-Host "  OK: Gemini model selected: $geminiModel" -ForegroundColor Green
}

Ensure-PhoenixWin11Base
Ensure-PhoenixRuntimeToolchain -Mode 'latest with postflight verification'
if ($authMode -eq 'gemini') {
  Write-Host ""
  Write-Host "Gemini Selected Auth Policy" -ForegroundColor Yellow
  Write-Host "  Skipping Codex OAuth login because Gemini API was explicitly selected for conversation auth."
  Write-Host "  OpenClaw config will use provider=google, model=google/$geminiModel, with GEMINI_API_KEY/GOOGLE_API_KEY from bot .env."
} else {
  Ensure-PhoenixCodexCliFirstAuth
}
Clear-PhoenixBotRuntimeTraces -BotId $botId -WorkDir $workDir -ProfileDir $profileDir -StateDir $stateDir -RemoveProfile -RemoveWorkDir

New-Item -ItemType Directory -Path $workDir, (Join-Path $workDir 'skills'), (Join-Path $workDir 'logs'), $profileDir -Force | Out-Null

Write-Host ""
Write-Host "Conversation authentication" -ForegroundColor Yellow
if ($authMode -eq 'gemini') {
  Write-Host "  Gemini API is explicitly selected for bot replies."
  Write-Host "  Installer execution tools are not treated as the preferred bot model auth."
  Write-Host "  The bot must clearly say Gemini is active; it must not imply GPT-5.5."
  $conversationApiLine = '# Conversation auth preference: Gemini API selected authentication. Do not imply GPT-5.5 when Gemini is configured.'
} else {
  Write-Host "  Codex CLI ChatGPT login is imported into OpenAI OAuth, then openai/gpt-5.5 is used for conversation auth."
  Write-Host "  OpenAI API keys are not accepted for conversation billing in this user installer."
  $conversationApiLine = '# OPENAI_API_KEY_IMAGE is not used for ChatGPT OAuth conversation auth.'
}

$extraEnv = @()
if ($botName -in @('design','writer')) {
  Write-Host ""
  Write-Host "Optional image-generation API key for $displayName" -ForegroundColor Yellow
  Write-Host "  This key is only for gpt-image-2 high/medium/low image features, not OpenClaw conversation auth."
  $apiFileName = 'openai_api_key_image.txt'
  $apiFile = Join-Path $PSScriptRoot $apiFileName
  $apiSourceFile = $null
  $imageKey = Get-PhoenixEnvValue -Names @('PHOENIX_IMAGE_API_KEY','PHOENIX_OPENAI_API_KEY_IMAGE')
  if (Test-Path -LiteralPath $apiFile) {
    $apiSourceFile = $apiFileName
  }
  if ($apiSourceFile) {
    $candidate = (Get-Content -LiteralPath (Join-Path $PSScriptRoot $apiSourceFile) -Raw).Trim()
    if ($candidate -match '^sk-') {
      $imageKey = $candidate
      Write-Host "  OK: $apiSourceFile loaded into bot-local .env. Value was not printed."
      Confirm-PhoenixDeleteInstallerFile -FileName $apiSourceFile
    } else {
      throw "$apiSourceFile is present but does not look like an OpenAI API key. Put only the key value in the file."
    }
  }
  if (-not $imageKey) {
    Write-Host "  Optional openai_api_key_image.txt not found. Skipping image API key setup. To use image generation later, put the key in openai_api_key_image.txt and rerun apply_optional_api_keys.ps1." -ForegroundColor Yellow
  }
  if ($imageKey) {
    $extraEnv += "OPENAI_API_KEY_IMAGE=$imageKey"
    $extraEnv += 'GPT_IMAGE_PRIMARY=gpt-image-2-high'
    $extraEnv += 'GPT_IMAGE_FALLBACK=gpt-image-2-medium'
    $extraEnv += 'GPT_IMAGE_EMERGENCY=gpt-image-2-low'
  } else {
    $extraEnv += '# OPENAI_API_KEY_IMAGE='
    $extraEnv += 'GPT_IMAGE_PRIMARY=gpt-image-2-high'
    $extraEnv += 'GPT_IMAGE_FALLBACK=gpt-image-2-medium'
    $extraEnv += 'GPT_IMAGE_EMERGENCY=gpt-image-2-low'
  }
}

if ($botName -eq 'video') {
  Write-Host ""
  Write-Host "Optional fal.ai video-generation API key" -ForegroundColor Yellow
  Write-Host "  falai_api_key_video.txt is only for fal.ai video generation models, not OpenClaw conversation auth."
  Write-Host "  Put only the fal.ai API key in falai_api_key_video.txt, with no label or extra text."
  $falFileName = 'falai_api_key_video.txt'
  $falFile = Join-Path $PSScriptRoot $falFileName
  $falSourceFile = $null
  $falKey = Get-PhoenixEnvValue -Names @('PHOENIX_FALAI_API_KEY_VIDEO')
  if (Test-Path -LiteralPath $falFile) {
    $falSourceFile = $falFileName
  }
  if ($falSourceFile) {
    $candidate = (Get-Content -LiteralPath (Join-Path $PSScriptRoot $falSourceFile) -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { throw "$falSourceFile is empty. Put only the fal.ai API key in the file." }
    $falKey = $candidate
    Write-Host "  OK: $falSourceFile loaded into bot-local .env as FALAI_API_KEY_VIDEO. Value was not printed."
    Confirm-PhoenixDeleteInstallerFile -FileName $falSourceFile
  }
  if (-not $falKey) {
    Write-Host "  Optional falai_api_key_video.txt not found. Skipping fal.ai key setup. To use video generation later, put the key in falai_api_key_video.txt and rerun apply_optional_api_keys.ps1." -ForegroundColor Yellow
  }
  if ($falKey) { $extraEnv += "FALAI_API_KEY_VIDEO=$falKey" } else { $extraEnv += '# FALAI_API_KEY_VIDEO=' }
}

$envLines = @(
  "BOT_ID=$botId",
  "BOT_NAME=$botName",
  "OPENCLAW_PROFILE=$botId",
  "OPENCLAW_PORT=",
  "TELEGRAM_BOT_TOKEN=",
  "TELEGRAM_READY_CHAT_ID=",
  $conversationApiLine
) + $extraEnv
Write-Utf8NoBomFile -Path (Join-Path $workDir '.env') -Content (($envLines -join "
") + "
")

$fallbackStateScript = Join-Path $PSScriptRoot 'phoenix_model_fallback_state.cjs'
if (Test-Path -LiteralPath $fallbackStateScript -PathType Leaf) {
  $oldPhoenixModelAuthMode = $env:PHOENIX_MODEL_AUTH_MODE
  $env:PHOENIX_MODEL_AUTH_MODE = $authMode
  try {
    $fallbackOut = & node $fallbackStateScript --mode install --auth-mode $authMode --input-dir $PSScriptRoot --workdir $workDir --bot $botName --display $displayName --profile $botId 2>&1
  } finally {
    $env:PHOENIX_MODEL_AUTH_MODE = $oldPhoenixModelAuthMode
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Model fallback state setup failed. Output: $($fallbackOut | Out-String)"
  }
  $fallbackInfo = $null
  try {
    $fallbackInfo = ($fallbackOut | Out-String | ConvertFrom-Json)
    Write-Host "  Model fallback config: Gemini configured=$($fallbackInfo.geminiConfigured), Local LLM configured=$($fallbackInfo.localConfigured). Values were not printed."
    if ($fallbackInfo.warnings -and $fallbackInfo.warnings.Count -gt 0) {
      Write-Host "  WARNING: $($fallbackInfo.warnings -join '; ')" -ForegroundColor Yellow
    }
  } catch {
    Write-Host "  Model fallback config refreshed. Values were not printed."
  }
  $secretFallbackFiles = @()
  if ($fallbackInfo -and $fallbackInfo.geminiConfigured) { $secretFallbackFiles += 'gemini_api_key.txt' }
  if ($fallbackInfo -and $fallbackInfo.localConfigured) { $secretFallbackFiles += 'local_llm_api_key.txt' }
  foreach ($secretFallbackFile in $secretFallbackFiles) {
    $secretFallbackPath = Join-Path $PSScriptRoot $secretFallbackFile
    if (Test-Path -LiteralPath $secretFallbackPath -PathType Leaf) {
      $secretFallbackValue = (Get-Content -LiteralPath $secretFallbackPath -Raw).Trim()
      if (-not [string]::IsNullOrWhiteSpace($secretFallbackValue)) {
        $answer = Read-Host "Action: delete $secretFallbackFile from installer folder now for security? [Y/n]"
        if ($answer -notmatch '^[Nn]$') {
          Remove-Item -LiteralPath $secretFallbackPath -Force -ErrorAction SilentlyContinue
          Write-Host "  OK: $secretFallbackFile deleted from installer folder. Value was not printed." -ForegroundColor Green
        } else {
          Write-Host "  SECURITY WARNING: $secretFallbackFile remains in installer folder." -ForegroundColor Yellow
        }
      }
    }
  }
  Write-Host "  Root auth-key folder files are source templates and are not deleted by the installer."
}

$phoenixAuthDescription = if ($authMode -eq 'gemini') {
  "Conversation authentication preference: use Gemini API as the selected authentication mode with model google/$geminiModel. Codex CLI, Claude Code, and Antigravity IDE are installer execution tools, not the preferred bot model authentication."
} else {
  "Conversation authentication: use OpenAI provider with ChatGPT OAuth imported from Codex CLI, model openai/gpt-5.5. Do not ask for or use an OpenAI API key for conversation authentication."
}
$phoenixAuthOrder = if ($authMode -eq 'gemini') {
  "Authentication order: 1) explicitly configured Gemini API, 2) explicitly configured local/Open Source LLM, 3) OpenAI/Codex only if the user explicitly chooses it later."
} else {
  "Fallback authentication order: 1) Codex CLI ChatGPT OAuth import to OpenAI provider, 2) ChatGPT subscription browser approval if Codex CLI login is missing/expired, 3) explicitly configured Gemini API fallback, 4) explicitly configured local/Open Source LLM fallback."
}
$phoenixAuthDisclosure = if ($authMode -eq 'gemini') {
  "Always say Gemini is active when Gemini is the provider. Never imply GPT-5.5 when Gemini is configured."
} else {
  "When a fallback is used or only configured as a candidate, say so clearly. Never imply GPT-5.5 when Gemini or local LLM is active."
}

$identity = @"
# $displayName Identity

- Name: $displayName
- PM2: $botId
- $phoenixAuthDescription
- API key policy: API keys are bot-local feature keys only, not subscription auth.
"@
Write-Utf8NoBomFile -Path (Join-Path $workDir 'IDENTITY.md') -Content $identity

$phoenixRole = switch ($botName) {
  'genesis' { 'Chief-of-staff bot for multi-bot orchestration, prompt design, coding plans, landing pages, automations, and service/platform architecture.' }
  'power' { 'Planning and research lead for reports, papers, market analysis, competitor analysis, policy grants, and government project analysis.' }
  'design' { 'Design lead for image generation, detail pages, web design, brand visuals, thumbnails, and PPT visuals.' }
  'video' { 'Video lead for generated video, video concepts, shorts, ad videos, storyboards, and fal.ai-based production planning.' }
  'writer' { 'Publishing lead for manuscripts, books, reports, copywriting, image lists, editing, and publication workflows.' }
  default { 'Phoenix bot for useful, safe, role-specific work.' }
}
$phoenixRoleDetail = switch ($botName) {
  'genesis' { 'Genesis Bot role markers: multi-bot orchestration, task instruction design, service/platform architecture, landing page planning, automation program design.' }
  'power' { 'Power Bot role markers: reports, research, market analysis, competitor analysis, grant/RFP analysis, evidence-based planning.' }
  'design' { 'Design Bot role markers: detail pages, PPT visuals, thumbnails, brand visual direction, image generation planning.' }
  'video' { 'Video Bot role markers: shorts, ad video scripts, storyboards, scene planning, hook writing, fal.ai production prompts.' }
  'writer' { 'Writer Bot role markers: manuscripts, book planning, copywriting, editing, image lists, publishing workflow.' }
  default { 'Phoenix Agent v2.0 role-specific operation.' }
}
$phoenixMenu = switch ($botName) {
  'genesis' { @'
1. Draft a command plan for all Phoenix bots
2. Build a landing page or automation brief
3. Turn an idea into a service/platform blueprint
'@ }
  'power' { @'
1. Make a trend or market report
2. Compare competitors and opportunities
3. Analyze grants, RFPs, and public-sector projects
'@ }
  'design' { @'
1. Create image/detail-page concepts
2. Build brand visual directions
3. Draft PPT or web design layouts
'@ }
  'video' { @'
1. Make short-form video concepts
2. Build ad/video storyboard plans
3. Prepare fal.ai generation prompts
'@ }
  'writer' { @'
1. Outline a manuscript or book project
2. Draft copy/report sections
3. Create editing and image-list workflows
'@ }
  default { @'
1. Summarize current context
2. Propose next actions
3. Prepare a concrete work plan
'@ }
}
$phoenixPolicy = @"
<!-- PHOENIX_PROACTIVE_TREND_POLICY_START -->
## Phoenix Proactive Nudge / Trend Suggestion

This bot uses Phoenix Proactive Nudge with these limits: idle threshold 3 hours, ready-start delay 30 minutes, at most 10 proactive messages per bot per local date, automatic trend digest once per local date after 07:00 KST with same-day catch-up, skill learning guidance once per local date after 08:00 KST with same-day catch-up, skill work offer once per local date, and trend-based skill upgrade request once per local date after 17:00 KST with same-day catch-up.

On every real user message, quietly update .openclaw/phoenix_proactive_state.json:
- lastUserMessageAt = current UTC ISO time.
- if readyNoticeAt exists and firstUserMessageAfterReadyAt is empty, set firstUserMessageAfterReadyAt.
- never record or print token/API key/OAuth credential values.

If the user asks trend-style questions such as Korean phrases meaning current trends, latest popular things, what is rising, what to try now, or idea recommendations:
- Treat it as a trend suggestion task for $displayName.
- Use current search/browsing when latest information is needed and available.
- Summarize the latest flow, then propose concrete work menus that match this bot's role.
- Include immediately usable prompts, execution options, and any files/materials needed.
- Do not stop at a generic answer; lead the user toward a real next task.

Skill work offer:
- Once per local date, choose one concrete task from this bot skills or default menu.
- Ask the user for approval before starting the actual work.

Skill upgrade request:
- Once per local date after 17:00 KST, search/analyze current trends and propose one useful skill enhancement or expanded skill. If the local machine wakes later, send it once as same-day catch-up.
- Ask master approval first; never self-modify skill files without approval.

Bot role:
$phoenixRole

Default execution menu:
$phoenixMenu
<!-- PHOENIX_PROACTIVE_TREND_POLICY_END -->
"@
$heartbeatGuide = @"
# HEARTBEAT

Phoenix Proactive Nudge is enabled for $displayName.

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
- ready_start_suggestion: after readyNoticeAt + 30 minutes, if no firstUserMessageAfterReadyAt exists. Send one concise message that summarizes this bot's role and proposes one next action.
- idle_summary: after 3 hours of no user input, summarize recent useful progress from logs, outputs, SCHEDULE.md, or visible files. If there is no meaningful progress, suggest this bot's best default next action.
- trend_digest: once per local date, proactively search current trend/news flow from the last 14 days for this bot role and send a concise work suggestion, even if the user did not ask first.
- skill_work_offer: once per local date, pick one skill-based task this bot can actually do and ask the user to approve execution.
- skill_upgrade_request: once per local date after 17:00 KST, search/analyze current trends and ask the master to approve one skill enhancement or expanded skill for a future updater. If the local machine wakes later, send it once as same-day catch-up.

Bot role:
$phoenixRole

Suggested menu:
$phoenixMenu

Heartbeat reply rule:
- Use heartbeat_respond.
- Set notify=false when nothing genuinely useful should interrupt the user.
- Set notify=true only for one concise Telegram-ready message.
"@
$skillGuide = @"
# Skills

Add bot-specific skills here. Restart with: pm2 restart $botId --update-env

$phoenixPolicy
"@

$phoenixIdentityBlock = @"
<!-- PHOENIX_AGENT_IDENTITY_START -->
## Phoenix Agent Identity

You are $displayName, a Phoenix Agent v2.0 Telegram/OpenClaw bot.
PM2 profile: $botId
Primary role: $phoenixRole
Role detail:
$phoenixRoleDetail

$phoenixAuthDescription
$phoenixAuthOrder
$phoenixAuthDisclosure
Feature API keys, when present, are bot-local feature keys only. Never print .env, auth files, Telegram tokens, API keys, OAuth files, or raw secret file contents.

First wake-up routine:
1. Say that you are $displayName.
2. Inspect the bot folder before acting.
3. Report what this bot can do now.
4. Report missing files or user decisions without exposing secrets.
5. Recommend one concrete next action.

Operating style:
- Be practical, concise, and action-oriented.
- Preserve the user's files and outputs unless the user explicitly asks to delete or overwrite them.
- Explain progress in user-facing language instead of dumping long raw commands.
- When Telegram pairing is needed, receive the pairing code through telegram_pairing_code.txt moved into installer and approve it with the helper script.

Default work menu:
$phoenixMenu
<!-- PHOENIX_AGENT_IDENTITY_END -->
"@
$phoenixUserContext = @"
<!-- PHOENIX_USER_CONTEXT_START -->
## User Operation Context

This file is for local operator preferences and handoff notes for $displayName.
The updater may refresh this marked block, but user notes outside this block should be preserved.
Do not place token/API key/OAuth credential values here.
<!-- PHOENIX_USER_CONTEXT_END -->
"@
Write-Utf8NoBomFile -Path (Join-Path $workDir 'IDENTITY.md') -Content "# $displayName Identity

$phoenixIdentityBlock
"

$agents = @"
# $displayName Agent Guide

You are $displayName.
$phoenixAuthDescription
$phoenixAuthOrder
$phoenixAuthDisclosure
Never print .env, auth files, Telegram tokens, API keys, or OAuth credential values.
When local skills run, summarize user-facing progress instead of exposing long raw commands.

First greeting format:
Hello, master. I am $displayName.
After waking up, inspect this bot folder and report:
1. What you can do
2. Files already filled
3. Files or folders that still need user input
4. Warnings without exposing secrets
5. Recommended next step

$phoenixIdentityBlock

$phoenixPolicy
"@
Write-Utf8NoBomFile -Path (Join-Path $workDir 'AGENTS.md') -Content $agents
Write-Utf8NoBomFile -Path (Join-Path $workDir 'SOUL.md') -Content "# $displayName SOUL

$phoenixIdentityBlock
"
Write-Utf8NoBomFile -Path (Join-Path $workDir 'USER.md') -Content "# USER

$phoenixUserContext
"
Write-Utf8NoBomFile -Path (Join-Path $workDir 'SCHEDULE.md') -Content "# SCHEDULE

No scheduled tasks yet.
"
Write-Utf8NoBomFile -Path (Join-Path $workDir 'HEARTBEAT.md') -Content $heartbeatGuide
Write-Utf8NoBomFile -Path (Join-Path $workDir 'skills\SKILL.md') -Content ($skillGuide.TrimEnd() + "

" + $phoenixIdentityBlock + "
")
Install-Phoenixv19SkillupStructure -RootDir (Split-Path -Parent $workDir) -WorkDir $workDir -BotName $botName -DisplayName $displayName -BotId $botId
Install-Phoenixv20WebControlStructure -RootDir (Split-Path -Parent $workDir) -WorkDir $workDir -BotName $botName -DisplayName $displayName -BotId $botId
Write-PhoenixProactiveState -WorkDir $workDir -BotName $botName -DisplayName $displayName -BotId $botId -ReadyNoticeAt $null

$identityFiles = @(
  (Join-Path $workDir 'IDENTITY.md'),
  (Join-Path $workDir 'AGENTS.md'),
  (Join-Path $workDir 'SOUL.md'),
  (Join-Path $workDir 'HEARTBEAT.md'),
  (Join-Path $workDir 'skills\SKILL.md')
)
$requiredIdentityMarkers = @()
if ($botName -eq 'genesis') {
  $requiredIdentityMarkers += @('Genesis Bot')
}
if ($authMode -eq 'gemini') {
  $requiredIdentityMarkers += @('Gemini API')
}
foreach ($marker in $requiredIdentityMarkers) {
  $found = $false
  foreach ($file in $identityFiles) {
    if ((Test-Path -LiteralPath $file -PathType Leaf) -and ((Get-Content -LiteralPath $file -Raw -Encoding UTF8) -like "*$marker*")) {
      $found = $true
      break
    }
  }
  if (-not $found) {
    throw "Identity quality audit missing required phrase marker: $marker. Installation stopped before final success report."
  }
}
Write-Host "  OK: Identity quality audit passed for $displayName." -ForegroundColor Green

if ($botName -eq 'writer') {
  $src = Join-Path $PSScriptRoot 'writer_publication_skills'
  if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $workDir 'skills\writer_publication_skills') -Recurse -Force }
}
if ($botName -eq 'design') {
  $src = Join-Path $PSScriptRoot 'design_super_detail_page_skills'
  if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $workDir 'skills\design_super_detail_page_skills') -Recurse -Force }
}

$port = Get-PhoenixNextGatewayPort -StartPort 18790 -EcosystemPaths @($ecosystem)
$envPath = Join-Path $workDir '.env'
$envText = Get-Content -LiteralPath $envPath -Raw
$envText = $envText -replace 'OPENCLAW_PORT=', "OPENCLAW_PORT=$port"
Write-Utf8NoBomFile -Path $envPath -Content $envText

$configPath = Join-Path $profileDir 'openclaw.json'
if ($authMode -eq 'gemini') {
  Write-PhoenixGeminiOpenClawConfig -ProfileDir $profileDir -Port $port -Model $geminiModel
  $validateOut = (openclaw --profile $botId config validate --json) 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "Gemini OpenClaw config validation failed. Check OpenClaw version and Gemini provider schema. Secret values were not printed."
  }
  Write-Host "  OK: Gemini selected-auth OpenClaw config validated." -ForegroundColor Green
} else {
  $config = [ordered]@{
    gateway = [ordered]@{ mode = 'local'; port = $port }
    agents = [ordered]@{
      defaults = [ordered]@{
        model = [ordered]@{ primary = $modelStr }
        models = [ordered]@{ 'openai/gpt-5.5' = [ordered]@{} }
      }
    }
    models = [ordered]@{
      providers = [ordered]@{
        openai = [ordered]@{
          auth = 'oauth'
          models = @([ordered]@{ id = 'gpt-5.5'; name = 'gpt-5.5'; api = 'openai-chatgpt-responses' })
        }
      }
    }
    auth = [ordered]@{
      profiles = [ordered]@{}
      order = [ordered]@{}
    }
  }
  Write-PhoenixJsonNoBom -Path $configPath -Value $config
}
Set-PhoenixGatewayAuthToken -ProfileDir $profileDir

Install-PhoenixCodexHarnessPlugin -Profile $botId
if ($authMode -eq 'openai') {
  Invoke-PhoenixAuthOrderRepair -BotName $botName
}

Write-Host ""
Write-Host "Telegram connection" -ForegroundColor Yellow
Show-PhoenixTelegramSetupFlow
$tgFromFile = $false
$tg = Read-PhoenixInstallerTextFile -FileName 'telegram_access_token.txt'
if ($tg) {
  $tgFromFile = $true
  Write-Host "  OK: telegram_access_token.txt loaded into bot-local .env. Value was not printed."
} else {
  $tg = Get-PhoenixEnvValue -Names @('PHOENIX_TELEGRAM_TOKEN')
}
if (-not $tg) {
  throw "telegram_access_token.txt was not found or is empty in the installer folder. Fill telegram_access_token.txt in 1. ?紐꾩쵄??API ??筌뤴뫁?? copy/move it into installer, then rerun. Do not paste the token into chat."
}
if ($tg -and -not (Test-PhoenixTelegramToken $tg)) {
  throw "Telegram token is present but the format is invalid. Check telegram_access_token.txt."
}
Confirm-PhoenixTelegramTokenOwner -Token $tg -DisplayName $displayName
if ($tgFromFile -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'telegram_access_token.txt'))) {
  Confirm-PhoenixDeleteInstallerFile -FileName 'telegram_access_token.txt'
}

$readyChatId = ""
$readyChatIdFromFile = $false
if ($tg) { $readyChatId = Read-PhoenixInstallerTextFile -FileName 'telegram_chat_id.txt' }
if ($readyChatId) {
  $readyChatIdFromFile = $true
  if (-not (Test-PhoenixTelegramChatId $readyChatId)) { throw "telegram_chat_id.txt is present but the format is invalid. Use a numeric Telegram chat id." }
  Write-Host "  OK: telegram_chat_id.txt loaded into bot-local .env. Value was not printed."
} else {
  $readyChatId = Get-PhoenixEnvValue -Names @('PHOENIX_TELEGRAM_CHAT_ID','PHOENIX_READY_CHAT_ID')
  if ($readyChatId -and -not (Test-PhoenixTelegramChatId $readyChatId)) { throw "PHOENIX_TELEGRAM_CHAT_ID is present but the format is invalid." }
}
if (-not $readyChatId) {
  throw "telegram_chat_id.txt was not found or is empty in the installer folder. Fill telegram_chat_id.txt in 1. ?紐꾩쵄??API ??筌뤴뫁?? copy/move it into installer, then rerun. Do not paste the chat id into chat."
}
if ($readyChatIdFromFile -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'telegram_chat_id.txt'))) {
  Confirm-PhoenixDeleteInstallerFile -FileName 'telegram_chat_id.txt'
}
Set-PhoenixProactiveHeartbeatConfig -ProfileDir $profileDir -ChatId $readyChatId
$envText = Get-Content -LiteralPath $envPath -Raw
$envText = $envText -replace 'TELEGRAM_BOT_TOKEN=.*', "TELEGRAM_BOT_TOKEN=$tg"
$envText = $envText -replace 'TELEGRAM_READY_CHAT_ID=.*', "TELEGRAM_READY_CHAT_ID=$readyChatId"
Write-Utf8NoBomFile -Path $envPath -Content $envText
Register-PhoenixTelegramChannel -Profile $botId -Token $tg
Write-Host '  OK: Telegram channel registered. Token value was not printed.' -ForegroundColor Green

$openclawMjs = Join-Path $env:APPDATA 'npm\node_modules\openclaw\openclaw.mjs'
if (-not (Test-Path -LiteralPath $openclawMjs)) { $openclawMjs = Join-Path (npm.cmd root -g) 'openclaw\openclaw.mjs' }
if (-not (Test-Path -LiteralPath $openclawMjs)) { throw 'openclaw.mjs not found after OpenClaw install.' }

$wdEsc = $workDir -replace '\\','/'
$mjsEsc = $openclawMjs -replace '\\','/'
$eco = @"
const fs = require('fs');
const path = require('path');
function readEnvFile(file) {
  const env = {};
  if (!fs.existsSync(file)) return env;
  for (const rawLine of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const idx = line.indexOf('=');
    if (idx === -1) continue;
    env[line.slice(0, idx)] = line.slice(idx + 1);
  }
  return env;
}
const localEnv = readEnvFile(path.join(__dirname, '.env'));
module.exports = {
  apps: [{
    name: '$botId',
    script: '$mjsEsc',
    args: '--profile $botId gateway run --port $port',
    cwd: '$wdEsc',
    env: {
      ...localEnv,
      OPENCLAW_PROFILE: '$botId',
      OPENCLAW_PORT: '$port',
      CODEX_HOME: '$($profileDir -replace '\\','/')/agents/main/agent/codex-home',
      TERM: 'xterm-256color',
      NODE_ENV: 'production'
    },
    autorestart: true,
    watch: false,
    max_restarts: 10,
    restart_delay: 5000,
    out_file: path.join(__dirname, 'logs', 'out.log'),
    error_file: path.join(__dirname, 'logs', 'error.log')
  }]
};
"@
Write-Utf8NoBomFile -Path $ecosystem -Content $eco

Invoke-PhoenixExternal -Command "pm2" -Arguments @("delete", $botId) -IgnoreErrors *> $null
Push-Location $workDir
Invoke-PhoenixExternal -Command "pm2" -Arguments @("start", "ecosystem.config.js", "--only", $botId) *> $null
Pop-Location
Test-PhoenixPortOwnerMatchesPm2 -Pm2Name $botId | Out-Null
Install-PhoenixProactiveNudgeRunner -RootDir (Split-Path -Parent $workDir)
Install-PhoenixReadyNoticeScript -RootDir (Split-Path -Parent $workDir)
Install-PhoenixStartupRunner -RootDir (Split-Path -Parent $workDir)
Invoke-PhoenixExternal -Command "pm2" -Arguments @("save", "--force") -IgnoreErrors *> $null

$ok = Test-PhoenixGatewayReady -BotId $botId -Port $port -TimeoutSeconds 30
if ($ok) { Test-PhoenixGatewayOperatorScope -BotId $botId }
Test-PhoenixBotRuntimeLogs -BotId $botId
if ($ok -and $tg -and $readyChatId) {
  $readySent = Send-PhoenixTelegramReadyNotice -Token $tg -ChatId $readyChatId -BotId $botId -DisplayName $displayName -Port $port
  if ($readySent) { Update-PhoenixProactiveReadyState -WorkDir $workDir -BotName $botName -DisplayName $displayName -BotId $botId }
}
$pairingStatus = 'not-provided'
$pairingFile = Join-Path $PSScriptRoot 'telegram_pairing_code.txt'
$approvePairingScript = Join-Path $PSScriptRoot 'approve_pairing_code.ps1'
if (Test-Path -LiteralPath $pairingFile -PathType Leaf) {
  $pairingValue = (Get-Content -LiteralPath $pairingFile -Raw -Encoding UTF8).Trim()
  if (-not [string]::IsNullOrWhiteSpace($pairingValue)) {
    Write-Host "  Pairing code file found in installer folder. Approving without printing the code..." -ForegroundColor Yellow
    $oldAutoDeletePairing = $env:PHOENIX_AUTO_DELETE_PAIRING_FILE
    $env:PHOENIX_AUTO_DELETE_PAIRING_FILE = '1'
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $approvePairingScript -BotName $botName
      if ($LASTEXITCODE -eq 0) { $pairingStatus = 'yes' } else { $pairingStatus = 'failed' }
    } catch {
      $pairingStatus = 'failed'
      Write-Host "  WARNING: Pairing approval failed. Telegram may still require manual approval with approve_pairing_code.ps1." -ForegroundColor Yellow
    } finally {
      $env:PHOENIX_AUTO_DELETE_PAIRING_FILE = $oldAutoDeletePairing
    }
  }
}
pm2 list

Write-Host ""
Write-Host "Installation result for $displayName" -ForegroundColor Green
Write-Host "  PM2 name: $botId"
Write-Host "  Work dir: $workDir"
Write-Host "  Profile dir: $profileDir"
Write-Host "  Port: $port"
Write-Host "  Conversation model: $modelStr"
Write-Host "  Gateway health: $ok"
Write-Host "  Pairing code approved: $pairingStatus"
Write-Host ""
Write-Host "Next user action:" -ForegroundColor Yellow
Write-Host "  1. In Telegram, send /start to this bot first."
Write-Host "  2. If the bot sends a pairing code, fill telegram_pairing_code.txt in 1. ?紐꾩쵄??API ??筌뤴뫁?? copy/move it into installer, then run:"
Write-Host "     powershell -ExecutionPolicy Bypass -File .\approve_pairing_code.ps1 -BotName $botName"
Write-Host "  3. Wait for the ready-complete Telegram notice from this bot."
Write-Host "  4. After the ready notice, send /new, wait 10-20 seconds, then send a short status-check message."
