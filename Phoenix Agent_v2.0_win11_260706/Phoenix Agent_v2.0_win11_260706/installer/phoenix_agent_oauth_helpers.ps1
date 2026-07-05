# Phoenix package release: v2.0_260706
function Write-PhoenixJsonNoBom {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][object]$Value
  )

  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $json = ($Value | ConvertTo-Json -Depth 50) + "`n"
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Update-PhoenixProcessPath {
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Set-PhoenixNpmCmdShim {
  $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($npmCmd) {
    Set-Alias -Name npm -Value $npmCmd.Source -Scope Global -Force
    return $npmCmd.Source
  }

  $npmAny = Get-Command npm -ErrorAction SilentlyContinue
  if ($npmAny) { return $npmAny.Source }

  return $null
}

$script:PhoenixNpmCommand = Set-PhoenixNpmCmdShim

function Get-PhoenixCommandSource {
  param([Parameter(Mandatory=$true)][string]$Command)

  foreach ($candidate in @("$Command.cmd", $Command)) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Invoke-PhoenixExternal {
  param(
    [Parameter(Mandatory=$true)][string]$Command,
    [string[]]$Arguments = @(),
    [switch]$IgnoreErrors
  )

  $source = Get-PhoenixCommandSource -Command $Command
  if (-not $source) {
    if ($IgnoreErrors) { return $null }
    throw "$Command command not found."
  }

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # Some CLIs print normal status/progress text to stderr. Do not fail only
    # because stderr was used; later checks judge by exit code and parsed state.
    $ErrorActionPreference = "Continue"
    & $source @Arguments
  } catch {
    if (-not $IgnoreErrors) { throw }
    return $null
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($LASTEXITCODE -ne 0 -and -not $IgnoreErrors) {
    throw "$Command failed: $($Arguments -join ' ')"
  }
  return $LASTEXITCODE
}

function Install-PhoenixWingetPackage {
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][string]$Label
  )

  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install Microsoft App Installer first, then rerun the installer."
  }

  Write-Host "  Installing $Label..." -ForegroundColor Cyan
  winget install -e --id $Id --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
  Update-PhoenixProcessPath
}

function Ensure-PhoenixNode22 {
  $nodeMajor = 0
  $nodeFull = $null
  try {
    $nodeFull = node --version 2>$null
    if ($nodeFull) { $nodeMajor = [int](($nodeFull -replace '^v','' -split '\.')[0]) }
  } catch {}

  if ($nodeMajor -lt 22) {
    Install-PhoenixWingetPackage -Id "OpenJS.NodeJS.LTS" -Label "Node.js 22 LTS"
    $nodeFull = node --version 2>$null
    $nodeMajor = [int](($nodeFull -replace '^v','' -split '\.')[0])
    if ($nodeMajor -lt 22) { throw "Node.js 22+ install/check failed. Current: $nodeFull" }
  }

  Write-Host "  OK: Node.js: $nodeFull" -ForegroundColor Green
}

function Ensure-PhoenixCommand {
  param(
    [Parameter(Mandatory=$true)][string]$Command,
    [string]$NpmPackage,
    [string]$WingetId,
    [string]$Label
  )

  if (Get-Command $Command -ErrorAction SilentlyContinue) {
    Write-Host "  OK: $Label found" -ForegroundColor Green
    return
  }

  if ($WingetId) {
    Install-PhoenixWingetPackage -Id $WingetId -Label $Label
  } elseif ($NpmPackage) {
    Write-Host "  Installing $Label..." -ForegroundColor Cyan
    if (-not $script:PhoenixNpmCommand) {
      $script:PhoenixNpmCommand = Set-PhoenixNpmCmdShim
    }
    if (-not $script:PhoenixNpmCommand) {
      throw "npm not found. Install Node.js LTS, reopen the terminal, then rerun the installer."
    }
    npm.cmd install -g $NpmPackage 2>&1 | Out-Null
    Update-PhoenixProcessPath
    $script:PhoenixNpmCommand = Set-PhoenixNpmCmdShim
  } else {
    throw "$Label not found and no installer configured."
  }

  if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
    throw "$Label install/check failed."
  }
  Write-Host "  OK: $Label found" -ForegroundColor Green
}

function Ensure-PhoenixWmic {
  $wmic = Get-Command wmic -ErrorAction SilentlyContinue
  if ($wmic) {
    Write-Host "  OK: WMIC is available" -ForegroundColor Green
    return
  }

  Write-Host "  WARNING: WMIC is missing. Repairing with DISM. This can take 1-3 minutes..."
  Start-Process cmd -ArgumentList "/c DISM /Online /Add-Capability /CapabilityName:WMIC~~~~" -Verb RunAs -Wait
  if (-not (Get-Command wmic -ErrorAction SilentlyContinue)) {
    throw "WMIC repair failed."
  }
  Write-Host "  OK: WMIC repair complete" -ForegroundColor Green
}

function Ensure-PhoenixWin11Base {
  param([switch]$IncludePython, [switch]$IncludeFFmpeg)

  Write-Host "Phoenix Agent v2.0 Win11 base tool check." -ForegroundColor Yellow
  Ensure-PhoenixNode22
  Ensure-PhoenixCommand -Command "git" -WingetId "Git.Git" -Label "Git"
  Ensure-PhoenixWmic
  Ensure-PhoenixCommand -Command "openclaw" -NpmPackage "openclaw@latest" -Label "OpenClaw"
  Ensure-PhoenixCommand -Command "clawhub" -NpmPackage "clawhub@latest" -Label "clawhub"
  Ensure-PhoenixCommand -Command "claude" -NpmPackage "@anthropic-ai/claude-code@latest" -Label "Claude Code"
  Ensure-PhoenixCommand -Command "pm2" -NpmPackage "pm2@latest" -Label "PM2"
  if ($IncludePython) { Ensure-PhoenixCommand -Command "python" -WingetId "Python.Python.3.12" -Label "Python 3.12" }
  if ($IncludeFFmpeg) { Ensure-PhoenixCommand -Command "ffmpeg" -WingetId "Gyan.FFmpeg" -Label "FFmpeg" }
  Write-Host "OK: Phoenix Agent v2.0 Win11 base tool check complete" -ForegroundColor Green
}

function Clear-PhoenixBotRuntimeTraces {
  param(
    [Parameter(Mandatory=$true)][string]$BotId,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [Parameter(Mandatory=$true)][string]$ProfileDir,
    [string]$StateDir = "",
    [switch]$RemoveProfile,
    [switch]$RemoveWorkDir
  )

  Write-Host "  Cleaning previous runtime traces: $BotId" -ForegroundColor Cyan

  $pm2 = Get-PhoenixCommandSource -Command "pm2"
  if ($pm2) {
    Invoke-PhoenixExternal -Command "pm2" -Arguments @("stop", $BotId) -IgnoreErrors *> $null
    Invoke-PhoenixExternal -Command "pm2" -Arguments @("delete", $BotId) -IgnoreErrors *> $null
    Remove-Item -Path (Join-Path $env:USERPROFILE ".pm2\logs\*$BotId*") -Force -ErrorAction SilentlyContinue
  }

  foreach ($eco in @(
    (Join-Path $WorkDir "ecosystem.config.js"),
    (Join-Path $env:USERPROFILE "antigravity\openclaw\ecosystem.config.js")
  )) {
    if (Test-Path -LiteralPath $eco) {
      $ecoEsc = $eco -replace '\\','/'
      $botEsc = $BotId.Replace("'","")
      $nodeScript = @"
const fs = require('fs');
const p = '$ecoEsc';
const bot = '$botEsc';
try {
  delete require.cache[require.resolve(p)];
  const cfg = require(p);
  cfg.apps = (cfg.apps || []).filter(a => a && a.name !== bot);
  fs.writeFileSync(p, 'module.exports = ' + JSON.stringify(cfg, null, 2) + ';\n');
} catch {}
"@
      $nodeScript | node 2>$null | Out-Null
    }
  }

  $globalConf = Join-Path $env:USERPROFILE ".openclaw\openclaw.json"
  if (Test-Path -LiteralPath $globalConf) {
    $confEsc = $globalConf -replace '\\','/'
    $botEsc = $BotId.Replace("'","")
    $nodeScript = @"
const fs = require('fs');
const p = '$confEsc';
const bot = '$botEsc';
try {
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
  if (cfg.agents && Array.isArray(cfg.agents.list)) {
    cfg.agents.list = cfg.agents.list.filter(a => a && a.id !== bot && a.name !== bot);
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
  }
} catch {}
"@
    $nodeScript | node 2>$null | Out-Null
  }

  $pathsToRemove = @()
  if ($RemoveProfile) { $pathsToRemove += $ProfileDir }
  if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $pathsToRemove += $StateDir }

  foreach ($path in $pathsToRemove) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
      $full = [System.IO.Path]::GetFullPath($path)
      $userHome = [System.IO.Path]::GetFullPath($env:USERPROFILE)
      if ($full.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase) -and $full -match [Regex]::Escape($BotId)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  if ($RemoveWorkDir -and (Test-Path -LiteralPath $WorkDir)) {
    $full = [System.IO.Path]::GetFullPath($WorkDir)
    $userHome = [System.IO.Path]::GetFullPath($env:USERPROFILE)
    if ($full.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase) -and $full -match '_bot$') {
      Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  if ($pm2) { Invoke-PhoenixExternal -Command "pm2" -Arguments @("save") -IgnoreErrors *> $null }
}

function Get-PhoenixNextGatewayPort {
  param(
    [int]$StartPort = 18790,
    [string[]]$EcosystemPaths = @()
  )

  $used = New-Object 'System.Collections.Generic.HashSet[int]'

  try {
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalPort -ge $StartPort -and $_.LocalPort -lt 19000 } |
      ForEach-Object { [void]$used.Add([int]$_.LocalPort) }
  } catch {}

  try {
    $pm2Raw = pm2 jlist 2>$null | Out-String
    foreach ($m in [regex]::Matches($pm2Raw, '"--port"\s*,\s*"(?<p>\d+)"')) { [void]$used.Add([int]$m.Groups["p"].Value) }
    foreach ($m in [regex]::Matches($pm2Raw, '--port\s+(?<p>\d+)')) { [void]$used.Add([int]$m.Groups["p"].Value) }
    foreach ($m in [regex]::Matches($pm2Raw, '"OPENCLAW_PORT"\s*:\s*"?(?<p>\d+)"?')) { [void]$used.Add([int]$m.Groups["p"].Value) }
  } catch {}

  foreach ($eco in $EcosystemPaths) {
    if ($eco -and (Test-Path -LiteralPath $eco)) {
      $ecoRaw = Get-Content -LiteralPath $eco -Raw
      foreach ($m in [regex]::Matches($ecoRaw, '--port\s+(?<p>\d+)')) { [void]$used.Add([int]$m.Groups["p"].Value) }
      foreach ($m in [regex]::Matches($ecoRaw, 'OPENCLAW_PORT["'']?\s*:\s*["'']?(?<p>\d+)')) { [void]$used.Add([int]$m.Groups["p"].Value) }
    }
  }

  for ($p = $StartPort; $p -lt 19000; $p++) {
    if (-not $used.Contains($p)) { return $p }
  }

  throw "No available OpenClaw gateway port found from $StartPort."
}

function Set-PhoenixTelegramTokenInEcosystem {
  param(
    [Parameter(Mandatory=$true)][string]$EcosystemPath,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [Parameter(Mandatory=$true)][string]$BotId
  )

  $envPath = Join-Path $WorkDir ".env"
  if (-not (Test-Path -LiteralPath $EcosystemPath) -or -not (Test-Path -LiteralPath $envPath)) {
    Write-Host "  WARNING: ecosystem/.env not found; skipping sensitive-value storage check" -ForegroundColor Yellow
    return
  }

  $ecosystemEsc = $EcosystemPath -replace '\\','/'
  $envEsc = $envPath -replace '\\','/'
  $nodeScript = @"
const fs = require('fs');
const ecosystem = '$ecosystemEsc';
delete require.cache[require.resolve(ecosystem)];
const cfg = require(ecosystem);
const envText = fs.readFileSync('$envEsc', 'utf8');
const tg = (envText.match(/TELEGRAM_BOT_TOKEN=(.+)/) || [])[1];
if (tg && tg.trim()) {
  for (const app of (cfg.apps || [])) {
    if (app.name === '$BotId') {
      app.env = app.env || {};
      delete app.env.TELEGRAM_BOT_TOKEN;
    }
  }
  fs.writeFileSync(ecosystem, 'module.exports = ' + JSON.stringify(cfg, null, 2) + ';\n');
  console.log('  OK: ecosystem.config.js does not store sensitive values');
} else {
  console.log('  WARNING: TELEGRAM_BOT_TOKEN is empty');
}
"@
  $nodeScript | node
}

function Test-PhoenixGatewayReady {
  param(
    [Parameter(Mandatory=$true)][string]$BotId,
    [Parameter(Mandatory=$true)][int]$Port,
    [int]$TimeoutSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      $health = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
      if ($health.StatusCode -eq 200) {
        Write-Host "  OK: Gateway health passed (:$Port)" -ForegroundColor Green
        return $true
      }
    } catch {}
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  Write-Host "  ERROR: Gateway health failed (:$Port)" -ForegroundColor Red
  pm2 logs $BotId --lines 30 --nostream
  return $false
}

function Read-PhoenixJsonFile {
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  try {
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $raw = $raw.TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Copy-PhoenixJsonObject {
  param([Parameter(Mandatory=$true)][object]$Value)
  return ($Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json)
}

function Test-PhoenixCodexCredentialMaterial {
  param([object]$Candidate)

  if (-not $Candidate) { return $false }

  $props = @($Candidate.PSObject.Properties.Name)
  if ($props.Count -eq 0) { return $false }

  $placeholderKeys = @("provider", "type", "mode", "name", "label")
  $meaningful = @($props | Where-Object { $placeholderKeys -notcontains $_ })
  if ($meaningful.Count -eq 0) { return $false }

  foreach ($key in $meaningful) {
    if ($key -match '(?i)token|credential|account|session|auth|expires|refresh|access|id') {
      return $true
    }
  }

  return $true
}

function Invoke-PhoenixOpenAICodexImportRepair {
  param(
    [Parameter(Mandatory=$true)][string]$BotId
  )

  $repair = Join-Path $PSScriptRoot "phoenix_v20_auth_order_repair.cjs"
  if (-not (Test-Path -LiteralPath $repair -PathType Leaf)) {
    throw "v1.9 auth repair script is missing: $repair"
  }
  $botKey = $BotId -replace '^pw_', '' -replace '_bot$', ''
  Invoke-PhoenixExternal -Command "node" -Arguments @($repair, "--bot", $botKey) -IgnoreErrors *> $null
}

function Test-PhoenixCodexCliLogin {
  try {
    $codex = Get-PhoenixCommandSource -Command "codex"
    if (-not $codex) { return $false }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
    $status = (& $codex login status) 2>&1 | Out-String
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    return ($status -match '(?i)logged in|authenticated|chatgpt' -and $status -notmatch '(?i)not logged|not authenticated')
  } catch {
    return $false
  }
}

function Sync-PhoenixCodexOAuth {
  param(
    [Parameter(Mandatory=$true)][string]$ProfileDir,
    [Parameter(Mandatory=$true)][string]$BotId,
    [string]$Provider,
    [string]$ModelStr
  )

  if ($ModelStr -notlike "openai/*" -and $Provider -ne "openai") {
    Write-Host "  INFO: Not OpenAI provider route; skipping Codex import." -ForegroundColor DarkGray
    return $true
  }

  if (-not (Test-PhoenixCodexCliLogin)) {
    Write-Host "  ACTION: Complete Codex CLI ChatGPT login in the browser when prompted." -ForegroundColor Cyan
    Write-Host "  Security: OAuth credential values are not printed." -ForegroundColor DarkGray
    Invoke-PhoenixExternal -Command "codex" -Arguments @("login") -IgnoreErrors *> $null
  }
  if (-not (Test-PhoenixCodexCliLogin)) {
    throw "Codex CLI ChatGPT login is not confirmed yet. Run codex login in this same terminal, then rerun this installer."
  }

  Invoke-PhoenixOpenAICodexImportRepair -BotId $BotId
  Write-Host "  OK: OpenAI provider auth repaired from Codex login for $BotId. Values were not printed." -ForegroundColor Green
  return $true
}
