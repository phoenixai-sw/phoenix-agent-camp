# Phoenix Agent v1.9 Ready Notice
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "SilentlyContinue"

$root = Join-Path $env:USERPROFILE "antigravity\openclaw"
$bots = @(
  @{ Name = "genesis"; Display = "Genesis Bot"; Pm2 = "pw_genesis_bot"; Port = 18791 },
  @{ Name = "power";   Display = "Power Bot";   Pm2 = "pw_power_bot";   Port = 18798 },
  @{ Name = "design";  Display = "Design Bot";  Pm2 = "pw_design_bot";  Port = 18790 },
  @{ Name = "video";   Display = "Video Bot";   Pm2 = "pw_video_bot";   Port = 18794 },
  @{ Name = "writer";  Display = "Writer Bot";  Pm2 = "pw_writer_bot";  Port = 18795 }
)

function Decode-PhoenixText {
  param([string]$Base64)
  return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64))
}

function Get-EnvMap {
  param([string]$Path)
  $map = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $map }
  foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
    $line = $rawLine -replace "^\uFEFF", ""
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { continue }
    $map[$line.Substring(0, $idx)] = $line.Substring($idx + 1).Trim()
  }
  return $map
}

function Find-JsonTelegramToken {
  param([object]$Value)
  if ($null -eq $Value) { return "" }
  if ($Value -is [string]) {
    if ($Value -match '^\d{6,}:[A-Za-z0-9_-]{20,}$') { return $Value }
    return ""
  }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    foreach ($item in $Value) {
      $found = Find-JsonTelegramToken -Value $item
      if ($found) { return $found }
    }
    return ""
  }
  if ($Value.PSObject) {
    foreach ($prop in $Value.PSObject.Properties) {
      if ($prop.Name -match '(?i)token|botToken|bot_token') {
        $candidate = [string]$prop.Value
        if ($candidate -match '^\d{6,}:[A-Za-z0-9_-]{20,}$') { return $candidate }
      }
      $found = Find-JsonTelegramToken -Value $prop.Value
      if ($found) { return $found }
    }
  }
  return ""
}

function Get-BotToken {
  param([string]$BotName, [string]$Pm2Name)
  $envFile = Join-Path $root "$($BotName)_bot\.env"
  $envMap = Get-EnvMap -Path $envFile
  foreach ($key in @("TELEGRAM_BOT_TOKEN", "BOT_ACCESS_TOKEN", "BOT_TOKEN", "PHOENIX_TELEGRAM_TOKEN")) {
    if ($envMap[$key] -match '^\d{6,}:[A-Za-z0-9_-]{20,}$') {
      return $envMap[$key]
    }
  }

  $legacyName = $Pm2Name -replace '^pw_', '' -replace '_bot$', ''
  $configs = @(
    (Join-Path $env:USERPROFILE ".openclaw-$Pm2Name\openclaw.json"),
    (Join-Path $env:USERPROFILE ".openclaw-pw_$legacyName\openclaw.json")
  )
  foreach ($config in $configs) {
    if (-not (Test-Path -LiteralPath $config)) { continue }
    try {
      $json = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
      $found = Find-JsonTelegramToken -Value $json
      if ($found) { return $found }
    } catch {}
  }
  return ""
}

function Get-ReadyChatId {
  param([string]$BotName)
  $envFile = Join-Path $root "$($BotName)_bot\.env"
  $envMap = Get-EnvMap -Path $envFile
  foreach ($key in @("TELEGRAM_READY_CHAT_ID", "TELEGRAM_CHAT_ID", "CHAT_ID", "PHOENIX_TELEGRAM_CHAT_ID", "PHOENIX_READY_CHAT_ID")) {
    $chatId = [string]$envMap[$key]
    if ($chatId -match '^-?\d+$') { return $chatId }
  }
  return ""
}

function Get-BotPort {
  param(
    [string]$BotName,
    [string]$Pm2Name,
    [int]$FallbackPort
  )
  $envFile = Join-Path $root "$($BotName)_bot\.env"
  $envMap = Get-EnvMap -Path $envFile
  foreach ($key in @("OPENCLAW_PORT", "OPENCLAW_GATEWAY_PORT", "PORT")) {
    $candidate = [string]$envMap[$key]
    if ($candidate -match '^\d+$') { return [int]$candidate }
  }

  $legacyName = $Pm2Name -replace '^pw_', '' -replace '_bot$', ''
  $configs = @(
    (Join-Path $env:USERPROFILE ".openclaw-$Pm2Name\openclaw.json"),
    (Join-Path $env:USERPROFILE ".openclaw-pw_$legacyName\openclaw.json"),
    (Join-Path $env:USERPROFILE ".openclaw-pw_$($legacyName)_bot\openclaw.json")
  )
  foreach ($config in $configs) {
    if (-not (Test-Path -LiteralPath $config)) { continue }
    try {
      $json = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
      $port = [string]$json.gateway.port
      if ($port -match '^\d+$') { return [int]$port }
    } catch {}
  }
  return $FallbackPort
}

function Update-ProactiveReadyState {
  param(
    [string]$BotName,
    [string]$Display,
    [string]$Pm2
  )
  $stateDir = Join-Path $root "$($BotName)_bot\.openclaw"
  $statePath = Join-Path $stateDir "phoenix_proactive_state.json"
  New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
  $state = [ordered]@{}
  if (Test-Path -LiteralPath $statePath) {
    try {
      $existing = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
      foreach ($prop in $existing.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
    } catch {}
  }
  $state["version"] = 1
  $state["botName"] = $BotName
  $state["displayName"] = $Display
  $state["pm2Profile"] = $Pm2
  $state["readyNoticeAt"] = (Get-Date).ToUniversalTime().ToString("o")
  $state["firstUserMessageAfterReadyAt"] = $null
  if (-not $state.Contains("lastUserMessageAt")) { $state["lastUserMessageAt"] = $null }
  if (-not $state.Contains("proactiveSends")) { $state["proactiveSends"] = @() }
  $state["settings"] = [ordered]@{
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
    heartbeatEvery = "30m"
    timezone = "Asia/Seoul"
  }
  $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
}
function Test-Health {
  param([int]$Port)
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5
    return ($r.StatusCode -eq 200 -and $r.Content -match '"ok"\s*:\s*true')
  } catch {
    return $false
  }
}

function Send-TelegramText {
  param(
    [string]$Token,
    [string]$ChatId,
    [string]$Text
  )
  try {
    $payload = @{ chat_id = $ChatId; text = $Text } | ConvertTo-Json -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/sendMessage" -ContentType "application/json; charset=utf-8" -Body $body -TimeoutSec 10 | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-PhoenixModelFallbackNotice {
  param([string]$BotName)
  $statePath = Join-Path $root "$($BotName)_bot\.openclaw\phoenix_model_fallback.json"
  $lines = @((Decode-PhoenixText '7ZiE7J6sIOuMgO2ZlCDquLDspIA6IE9wZW5BSSBHUFQtNS41IChDb2RleC1pbXBvcnRlZCBDaGF0R1BUIE9BdXRoKQ=='))
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    return ($lines -join "`n")
  }
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $primaryProvider = if ($state.primary -and $state.primary.provider) { ([string]$state.primary.provider).ToLowerInvariant() } else { "" }
    if ($state.primary -and ($primaryProvider -eq 'google' -or $primaryProvider -eq 'gemini')) {
      $model = if ($state.primary.model) { [string]$state.primary.model } else { 'google/gemini-2.5-flash' }
      $lines = @("현재 대화 기준: Gemini API / $model")
    }
    foreach ($fallback in @($state.fallbacks)) {
      if ($fallback.configured -eq $true) {
        $lines += "$(Decode-PhoenixText 'ZmFsbGJhY2sg7ZuE67O0OiA=')$($fallback.visibleLabel)$(Decode-PhoenixText 'ICjrqoXsi5zsoIEgZmFsbGJhY2ssIEdQVC01LjUg7JWE64uYKQ==')"
      }
    }
  } catch {
    $lines += (Decode-PhoenixText 'ZmFsbGJhY2sg7IOB7YOcOiDsnb3quLAg7Iuk7Yyo')
  }
  return ($lines -join "`n")
}

function Get-PhoenixBotEnv {
  param([string]$BotName)
  $envPath = Join-Path $root "$($BotName)_bot\.env"
  $envMap = @{}
  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return $envMap }
  foreach ($raw in (Get-Content -LiteralPath $envPath -Encoding UTF8)) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith("#")) { continue }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { continue }
    $envMap[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
  }
  return $envMap
}

function Get-PhoenixModelPrimaryState {
  param([string]$BotName)
  $statePath = Join-Path $root "$($BotName)_bot\.openclaw\phoenix_model_fallback.json"
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function New-ReauthInstruction {
  param([string]$Pm2)
  $encodedLines = @(
    '7ZiE7J6sIFBob2VuaXgvT3BlbkNsYXcgVGVsZWdyYW0gQm907J2YIOuqqOuNuCDsnbjspp0g7IOB7YOc66W8IOuzteq1rO2VtCDso7zshLjsmpQu',
    '',
    '7KSR7JqUOg==',
    'LSBUZWxlZ3JhbSB0b2tlbiwgQVBJIEtleSwgT0F1dGggY3JlZGVudGlhbCDqsJLsnYAg7KCI64yAIOy2nOugpe2VmOyngCDrp4jshLjsmpQu',
    'LSDqsJLsnZgg7KG07J6sIOyXrOu2gOyZgCDshLHqs7Uv7Iuk7Yyo66eMIOuztOqzoO2VmOyEuOyalC4=',
    'LSDspIDruYQg7JmE66OMIOq4sOykgOydgCBQTTIgb25saW5lLCBHYXRld2F5IGhlYWx0aCBPSywgVGVsZWdyYW0gY29uZmlndXJlZC9lbmFibGVkLCBPcGVuQUkgcHJvdmlkZXIgKyBDb2RleC1pbXBvcnRlZCBDaGF0R1BUIE9BdXRoICsgb3BlbmFpL2dwdC01LjUgdXNhYmxlIOyDge2DnOq5jOyngCDtj6ztlajtlanri4jri6Qu',
    '',
    '7J6R7JeFOg==',
    'MS4g7ZW064u5IOu0h+ydmCBQTTIg7IOB7YOcLCBnYXRld2F5IGhlYWx0aCwgVGVsZWdyYW0gY2hhbm5lbCDsg4Htg5zrpbwg7ZmV7J247ZWp64uI64ukLg==',
    'Mi4gb3BlbmNsYXcgLS1wcm9maWxlIHtQTTJ9IG1vZGVscyBzdGF0dXMgLS1qc29uIOycvOuhnCBkZWZhdWx0TW9kZWwvcmVzb2x2ZWREZWZhdWx06rCAIG9wZW5haS9ncHQtNS417J247KeAIO2ZleyduO2VqeuLiOuLpC4=',
    'My4gcnVudGltZUF1dGhSb3V0ZXMg7JWI7JeQIHByb3ZpZGVyPW9wZW5haSwgcnVudGltZT1jb2RleCwgc3RhdHVzPXVzYWJsZSDqsr3roZzqsIAg7J6I64qU7KeAIO2ZleyduO2VqeuLiOuLpC4=',
    'NC4gdXNhYmxlIOqyveuhnOqwgCDsl4bsnLzrqbQg6rCZ7J2AIOy9lOuUqSDsl5DsnbTsoITtirgg7YSw66+464SQ7JeQ7IScIGNvZGV4IGxvZ2luIOyDge2DnOulvCDtmZXsnbjtlZjqs6Ag7ZWE7JqU7ZWY66m0IGNvZGV4IGxvZ2lu7J2EIOyLpO2Wie2VqeuLiOuLpC4=',
    'NS4g6re4IOuLpOydjCBvcGVuY2xhdyAtLXByb2ZpbGUge1BNMn0gcGx1Z2lucyBpbnN0YWxsIGNsYXdodWI6QG9wZW5jbGF3L2NvZGV4IC0tZm9yY2Ug66W8IOyLpO2Wie2VqeuLiOuLpC4=',
    'Ni4gb3BlbmNsYXcgLS1wcm9maWxlIHtQTTJ9IG1pZ3JhdGUgY29kZXggLS1mcm9tICRlbnY6VVNFUlBST0ZJTEVcLmNvZGV4IC0taW5jbHVkZS1zZWNyZXRzIC0teWVzIC0tbm8tYmFja3VwIC0tZm9yY2UgLS1qc29uIOycvOuhnCBDb2RleCDroZzqt7jsnbjsnYQgT3BlbkFJIHByb3ZpZGVyIE9BdXRo66GcIOqwgOyguOyYteuLiOuLpC4=',
    'Ny4gdjEuNiB1cGRhdGVy66W8IOuLpOyLnCDsi6TtlontlbQg66qo65OgIFBob2VuaXgg67SH7JeQIOqwmeydgCDquLDspIDsnYQg67CY7JiB7ZWp64uI64ukLg==',
    'OC4g7ZW064u5IFBNMiDtlITroZzshLjsiqTrpbwgcmVzdGFydCAtLXVwZGF0ZS1lbnYg7ZWY6rOgIHBtMiBzYXZlIC0tZm9yY2Xrpbwg7Iuk7ZaJ7ZWp64uI64ukLg==',
    'OS4g66eI7KeA66eJ7Jy866GcIFBNMiBvbmxpbmUsIGdhdGV3YXkgaGVhbHRoIE9LLCBUZWxlZ3JhbSBjb25maWd1cmVkL2VuYWJsZWQsIG9wZW5haS9ncHQtNS41IHVzYWJsZSDsg4Htg5zrpbwg64uk7IucIO2ZleyduO2VqeuLiOuLpC4=',
    'MTAuIFRlbGVncmFt7JeQ7ISc64qUIC9uZXcg7ZuEIDEwfjIw7LSIIOuSpCDsg4Htg5wg7ZmV7J24IOuplOyLnOyngOuhnCDthYzsiqTtirjtlanri4jri6Qu'
  )
  $lines = foreach ($item in $encodedLines) {
    if ($item) { (Decode-PhoenixText $item).Replace('{PM2}', $Pm2) } else { '' }
  }
  return ($lines -join "`n")
}

function Get-OpenClawCodexAuthStatus {
  param([string]$Pm2, [string]$BotName)
  $primaryState = Get-PhoenixModelPrimaryState -BotName $BotName
  $primaryProvider = if ($primaryState -and $primaryState.primary -and $primaryState.primary.provider) { ([string]$primaryState.primary.provider).ToLowerInvariant() } else { "" }
  if ($primaryState -and $primaryState.primary -and ($primaryProvider -eq 'google' -or $primaryProvider -eq 'gemini')) {
    $envMap = Get-PhoenixBotEnv -BotName $BotName
    $hasKey = $false
    if ($envMap.ContainsKey('PHOENIX_GEMINI_API_KEY') -and -not [string]::IsNullOrWhiteSpace($envMap['PHOENIX_GEMINI_API_KEY'])) { $hasKey = $true }
    if ($envMap.ContainsKey('GEMINI_API_KEY') -and -not [string]::IsNullOrWhiteSpace($envMap['GEMINI_API_KEY'])) { $hasKey = $true }
    if ($envMap.ContainsKey('GOOGLE_API_KEY') -and -not [string]::IsNullOrWhiteSpace($envMap['GOOGLE_API_KEY'])) { $hasKey = $true }
    if (-not $hasKey) {
      return [pscustomobject]@{ Ready = $false; Reason = "Gemini API key is not configured"; ExpiresText = "" }
    }
    try {
      $rawValidate = (openclaw --profile $Pm2 config validate --json) 2>$null | Out-String
      if ([string]::IsNullOrWhiteSpace($rawValidate)) {
        return [pscustomobject]@{ Ready = $false; Reason = "Gemini OpenClaw config validation returned empty output"; ExpiresText = "" }
      }
      $validation = $rawValidate | ConvertFrom-Json
      if ($validation.valid -eq $false) {
        return [pscustomobject]@{ Ready = $false; Reason = "Gemini OpenClaw config validation failed"; ExpiresText = "" }
      }
      return [pscustomobject]@{ Ready = $true; Reason = ""; ExpiresText = "" }
    } catch {
      return [pscustomobject]@{ Ready = $false; Reason = "Gemini OpenClaw config validation failed"; ExpiresText = "" }
    }
  }

  try {
    $raw = (openclaw --profile $Pm2 models status --json) 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return [pscustomobject]@{ Ready = $false; Reason = "models status returned empty output"; ExpiresText = "" }
    }
    $status = $raw | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ Ready = $false; Reason = "models status check failed"; ExpiresText = "" }
  }

  $resolved = ""
  if ($status.resolvedDefault) { $resolved = [string]$status.resolvedDefault }
  elseif ($status.defaultModel) { $resolved = [string]$status.defaultModel }
  if ($resolved -ne "openai/gpt-5.5") {
    return [pscustomobject]@{ Ready = $false; Reason = "default model is not openai/gpt-5.5"; ExpiresText = "" }
  }

  $usable = $false
  if ($status.auth -and $status.auth.runtimeAuthRoutes) {
    foreach ($route in @($status.auth.runtimeAuthRoutes)) {
      if ($route.provider -eq "openai" -and $route.runtime -eq "codex" -and $route.status -eq "usable") {
        $usable = $true
        break
      }
    }
  }
  if (-not $usable) {
    return [pscustomobject]@{ Ready = $false; Reason = "OpenAI provider via Codex runtime is not usable"; ExpiresText = "" }
  }

  return [pscustomobject]@{ Ready = $true; Reason = ""; ExpiresText = "openai/gpt-5.5 usable" }
}

function Send-ReadyNotice {
  param(
    [string]$Token,
    [string]$ChatId,
    [string]$BotName,
    [string]$Display,
    [string]$Pm2,
    [int]$Port,
    [string]$ModelAuthExpires = ""
  )
  $normal = Decode-PhoenixText '66qo6424IOyduOymnTog7KCV7IOB'
  $until = Decode-PhoenixText 'IOq5jOyngA=='
  $authLine = if ($ModelAuthExpires) { "`n$normal ($ModelAuthExpires$until)" } else { "`n$normal" }
  $fallbackNotice = Get-PhoenixModelFallbackNotice -BotName $BotName
  $text = "$(Decode-PhoenixText '7KO87J2464uYLCA=')$Display$(Decode-PhoenixText 'IOykgOu5hCDsmYTro4zsnoXri4jri6Qu')`nPM2: $Pm2`nGateway: http://127.0.0.1:$Port/health$authLine`n$fallbackNotice`n$(Decode-PhoenixText '7J207KCcIFRlbGVncmFt7JeQ7IScIC9uZXcg7ZuEIOyDge2DnCDtmZXsnbgg66mU7Iuc7KeA66W8IOuztOuCtOyFlOuPhCDrkKnri4jri6Qu')"
  return (Send-TelegramText -Token $Token -ChatId $ChatId -Text $text)
}

$initialDelaySeconds = 60
if ($env:PHOENIX_READY_INITIAL_DELAY_SECONDS -match '^\d+$') {
  $initialDelaySeconds = [Math]::Max(0, [int]$env:PHOENIX_READY_INITIAL_DELAY_SECONDS)
}
$timeoutMinutes = 15
if ($env:PHOENIX_READY_TIMEOUT_MINUTES -match '^\d+$') {
  $timeoutMinutes = [Math]::Max(1, [int]$env:PHOENIX_READY_TIMEOUT_MINUTES)
}

Start-Sleep -Seconds $initialDelaySeconds

$pending = @{}
foreach ($bot in $bots) { $pending[$bot.Pm2] = $bot }

$deadline = (Get-Date).AddMinutes($timeoutMinutes)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
  foreach ($key in @($pending.Keys)) {
    $bot = $pending[$key]
    $port = Get-BotPort -BotName $bot.Name -Pm2Name $bot.Pm2 -FallbackPort $bot.Port
    if (-not (Test-Health -Port $port)) { continue }

    $chatId = Get-ReadyChatId -BotName $bot.Name
    $token = Get-BotToken -BotName $bot.Name -Pm2Name $bot.Pm2
    if ($chatId -and $token) {
      $auth = Get-OpenClawCodexAuthStatus -Pm2 $bot.Pm2 -BotName $bot.Name
      if ($auth.Ready) {
        $readySent = Send-ReadyNotice -Token $token -ChatId $chatId -BotName $bot.Name -Display $bot.Display -Pm2 $bot.Pm2 -Port $port -ModelAuthExpires $auth.ExpiresText
        if ($readySent) { Update-ProactiveReadyState -BotName $bot.Name -Display $bot.Display -Pm2 $bot.Pm2 }
      } else {
        [void](Send-ModelAuthProblemNotice -Token $token -ChatId $chatId -BotName $bot.Name -Display $bot.Display -Pm2 $bot.Pm2 -Port $port -Auth $auth)
      }
    }
    $pending.Remove($key)
  }
  if ($pending.Count -gt 0) { Start-Sleep -Seconds 15 }
}

