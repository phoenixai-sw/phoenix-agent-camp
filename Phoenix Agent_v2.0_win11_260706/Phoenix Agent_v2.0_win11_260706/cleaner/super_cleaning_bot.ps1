# Phoenix package release: v2.0_260706
param(
  [string]$Bot = "",
  [switch]$All,
  [ValidateSet('Ask','Yes','No')]
  [string]$BackupOutputs = 'Ask',
  [string]$ConfirmText = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $scriptDir
$packageName = Split-Path -Leaf $packageRoot

Write-Host "" -ForegroundColor Cyan
Write-Host "[User checkpoints] Before running Super Cleaning Bot, confirm these items." -ForegroundColor Cyan
Write-Host "  1. Cleaner is a deletion tool, not an install/auth tool." -ForegroundColor White
Write-Host "  2. For skill/rule updates only, do not run cleaner. Use pm2 restart." -ForegroundColor White
Write-Host "  3. Choose deletion scope: one installed bot or all currently installed bots." -ForegroundColor White
Write-Host "  4. Choose whether to back up outputs for each target bot before deletion." -ForegroundColor White
Write-Host "  5. Type the exact final confirmation phrase before deletion proceeds." -ForegroundColor White
Write-Host "  6. If running inside Antigravity Terminal/Codex, keep this in the current terminal." -ForegroundColor White
Write-Host "  Security: cleaner deletes installed bot runtime credentials, but keeps installer key folders and never prints token/API key/OAuth credential values." -ForegroundColor Yellow
$workspace = Join-Path $env:USERPROFILE "antigravity\openclaw"

function Normalize-BotName {
  param([string]$Name)
  $n = [string]$Name
  $n = $n.Trim().ToLowerInvariant()
  $n = $n -replace '^\.openclaw-', ''
  $n = $n -replace '^openclaw-', ''
  $n = $n -replace '^pw_', ''
  $n = $n -replace '_bot$', ''
  $n = $n -replace '-bot$', ''
  return $n
}

function Test-Pm2StateExists {
  $pm2Root = Join-Path $env:USERPROFILE ".pm2"
  $paths = @(
    $pm2Root,
    (Join-Path $pm2Root "dump.pm2"),
    (Join-Path $pm2Root "dump.pm2.bak"),
    (Join-Path $pm2Root "rpc.sock"),
    (Join-Path $pm2Root "pub.sock")
  )
  foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) { return $true }
  }
  return $false
}

function Get-InstalledPhoenixBots {
  $set = [ordered]@{}

  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($pm2 -and (Test-Pm2StateExists)) {
    try {
      $node = Get-Command node -ErrorAction SilentlyContinue
      if ($node) {
        $pm2Names = pm2 jlist 2>$null | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{const a=JSON.parse(s);for(const p of a){const n=String(p.name||'');const m=n.match(/^pw_(.+)_bot$/);if(m) console.log(m[1]);}}catch(e){}});"
        foreach ($name in $pm2Names) {
          if (-not [string]::IsNullOrWhiteSpace($name)) { $set[(Normalize-BotName $name)] = $true }
        }
      }
    } catch {}
  }

  if (Test-Path -LiteralPath $workspace) {
    Get-ChildItem -LiteralPath $workspace -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Name -match '(.+)_bot$') { $set[(Normalize-BotName $_.Name)] = $true }
    }
  }

  Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match '^\.openclaw-pw_(.+?)(?:_bot)?$') { $set[(Normalize-BotName $_.Name)] = $true }
  }

  $stateRoot = Join-Path $env:USERPROFILE ".openclaw-state"
  if (Test-Path -LiteralPath $stateRoot) {
    Get-ChildItem -LiteralPath $stateRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Name -match '^pw_(.+?)(?:_bot)?$') { $set[(Normalize-BotName $_.Name)] = $true }
    }
  }

  return @($set.Keys | Sort-Object)
}

function Test-SafeDeletePath {
  param([string]$Path, [string]$BotName)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $full = [System.IO.Path]::GetFullPath($Path)
  $userHome = [System.IO.Path]::GetFullPath($env:USERPROFILE)
  if ($full -eq $userHome -or $full -eq "$userHome\") { return $false }
  if ($full -in @("C:\", "C:")) { return $false }
  if ($full.Length -lt 20) { return $false }
  if (-not $full.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  if ($full -notmatch [Regex]::Escape($BotName)) { return $false }
  return $true
}

function Test-CurrentPackageArtifact {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  try {
    $full = [System.IO.Path]::GetFullPath($Path)
    $pkg = [System.IO.Path]::GetFullPath($packageRoot)
    $pkgParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $packageRoot))
    $downloadZip = Join-Path ([Environment]::GetFolderPath('UserProfile')) "Downloads\$packageName.zip"
    if ($full -ieq $pkg) { return $true }
    if ($full -ieq (Join-Path $pkgParent "$packageName.zip")) { return $true }
    if ($full -ieq ([System.IO.Path]::GetFullPath($downloadZip))) { return $true }
  } catch {}
  return $false
}

function Remove-SafeResidualPath {
  param([string]$Path, [string]$Label = "residual")
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
  if (Test-CurrentPackageArtifact -Path $Path) {
    Write-Host "Kept current package artifact: $Path"
    return
  }
  try {
    $full = [System.IO.Path]::GetFullPath($Path)
    $home = [System.IO.Path]::GetFullPath($env:USERPROFILE)
    if ($full -eq $home -or $full -eq "$home\" -or $full -in @("C:\", "C:") -or $full.Length -lt 10 -or -not $full.StartsWith($home, [System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Host "Skipped unsafe $Label path: $Path"
      return
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $full)) { Write-Host "Deleted ${Label}: $full" }
  } catch {
    Write-Host "Skipped $Label path: $Path"
  }
}

function Get-PhoenixCredentialInputs {
  $roots = @(
    $workspace,
    (Join-Path $env:USERPROFILE ".openclaw"),
    (Join-Path $env:USERPROFILE ".openclaw-state")
  )
  $names = @(
    'telegram_access_token.txt',
    'telegram_chat_id.txt',
    'telegram_pairing_code.txt',
    'bot_access_token.txt',
    'chat_id.txt',
    'pairing_code.txt',
    'openai_api_key_image.txt',
    'falai_api_key_video.txt',
    'gemini_api_key.txt',
    'local_llm_api_key.txt',
    'conversation_api_key.txt',
    'api_key.txt',
    'pal_api_key.txt',
    '.env'
  )
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $names -contains $_.Name -or $_.Name -like '.env.*' } |
      Select-Object -ExpandProperty FullName
  }
  Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '.openclaw-*' -or $_.Name -eq '.openclaw-state' } |
    ForEach-Object {
      Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $names -contains $_.Name -or $_.Name -like '.env.*' }
    } |
      Select-Object -ExpandProperty FullName
}

function Remove-PhoenixCredentialInputs {
  Write-Host ""
  Write-Host "Removing installed Phoenix/OpenClaw runtime credential files without printing values..."
  Write-Host "Keeping installer/package key folders such as 인증키_API 키 모음 and 인증키_에이전트 모델 인증 키 모음; installer/package key folders are preserved."
  $items = @(Get-PhoenixCredentialInputs | Sort-Object -Unique)
  foreach ($item in $items) { Remove-SafeResidualPath -Path $item -Label "installed runtime credential input file" }
  if ($items.Count -eq 0) { Write-Host "No Phoenix/OpenClaw installed runtime credential input files found." }
}

function Get-LegacyPhoenixPackages {
  @()
}

function Remove-LegacyPhoenixPackages {
  Write-Host ""
  Write-Host "Preserved Phoenix Agent package folders and installer key folders. Cleaner only removes installed bot runtime state."
}

function Get-PhoenixDeveloperToolResiduals {
  $roots = @(
    (Join-Path $env:USERPROFILE ".claude\projects"),
    (Join-Path $env:USERPROFILE ".gemini\antigravity"),
    (Join-Path $env:USERPROFILE ".config"),
    (Join-Path $env:USERPROFILE ".cache"),
    (Join-Path $env:APPDATA "clawhub"),
    (Join-Path $env:LOCALAPPDATA "clawhub")
  )
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '(?i)openclaw|phoenix|clawhub|pw_.*_bot|powerbot|publish_bot' } |
      Select-Object -ExpandProperty FullName
  }
  $npxRoot = Join-Path $env:USERPROFILE ".npm\_npx"
  if (Test-Path -LiteralPath $npxRoot) {
    Get-ChildItem -LiteralPath $npxRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      $hit = Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '(?i)node_modules\\(openclaw|clawhub|@openclaw\\codex)|\\.bin\\(openclaw|clawhub)' } |
        Select-Object -First 1
      if ($hit) { $_.FullName }
    }
  }
}

function Remove-PhoenixDeveloperToolResiduals {
  Write-Host ""
  Write-Host "Removing Phoenix/OpenClaw developer tool residuals..."
  $items = @(Get-PhoenixDeveloperToolResiduals | Sort-Object -Unique)
  foreach ($item in $items) { Remove-SafeResidualPath -Path $item -Label "developer tool residual" }
  if ($items.Count -eq 0) { Write-Host "No Phoenix/OpenClaw developer tool residuals found." }
}

function Backup-Outputs {
  param([string[]]$Bots)
  $backupRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) ("phoenix_super_cleaning_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
  $made = $false
  foreach ($bot in $Bots) {
    $outputs = Join-Path $workspace "${bot}_bot\outputs"
    if (Test-Path -LiteralPath $outputs) {
      $files = Get-ChildItem -LiteralPath $outputs -Recurse -File -ErrorAction SilentlyContinue
      if ($files -and $files.Count -gt 0) {
        if (-not $made) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null; $made = $true }
        Copy-Item -LiteralPath $outputs -Destination (Join-Path $backupRoot "${bot}_outputs") -Recurse -Force
      }
    }
  }
  if ($made) { Write-Host "Backed up outputs: $backupRoot" } else { Write-Host "No outputs found to back up." }
}

function Invoke-PerBotOutputsBackup {
  param(
    [string[]]$Bots,
    [ValidateSet('Ask','Yes','No')]
    [string]$Choice
  )

  $backupRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) ("phoenix_super_cleaning_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
  $made = $false

  foreach ($bot in $Bots) {
    $outputs = Join-Path $workspace "${bot}_bot\outputs"
    $files = @()
    if (Test-Path -LiteralPath $outputs) {
      $files = @(Get-ChildItem -LiteralPath $outputs -Recurse -File -ErrorAction SilentlyContinue)
    }

    if (-not $files -or $files.Count -eq 0) {
      Write-Host "No outputs found for $bot."
      continue
    }

    if ($Choice -eq 'Ask') {
      $answer = Read-Host "Action: back up $bot outputs before deleting this bot? Type Y to back up, or n to delete without backup [Y/n]"
    } else {
      $answer = if ($Choice -eq 'No') { 'n' } else { 'Y' }
      Write-Host "Action: backup $bot outputs before deletion = $Choice"
    }

    if ($answer -match '^[Nn]') {
      Write-Host "Skipped outputs backup for $bot."
      continue
    }

    if (-not $made) {
      New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
      $made = $true
    }
    Copy-Item -LiteralPath $outputs -Destination (Join-Path $backupRoot "${bot}_outputs") -Recurse -Force
    Write-Host "Backed up $bot outputs."
  }

  if ($made) {
    Write-Host "Backed up outputs root: $backupRoot"
  } else {
    Write-Host "No outputs were backed up."
  }
}

function Remove-OneBot {
  param([string]$BotName)
  $pm2Name = "pw_${BotName}_bot"
  $workdir = Join-Path $workspace "${BotName}_bot"
  $profiles = @(
    (Join-Path $env:USERPROFILE ".openclaw-$pm2Name"),
    (Join-Path $env:USERPROFILE ".openclaw-pw_$BotName"),
    (Join-Path $env:USERPROFILE ".openclaw-pw_${BotName}_bot"),
    (Join-Path $env:USERPROFILE ".openclaw-$BotName"),
    (Join-Path $env:USERPROFILE ".openclaw-${BotName}_bot"),
    (Join-Path $env:USERPROFILE ".openclaw-${BotName}-bot")
  )
  $states = @(
    (Join-Path $env:USERPROFILE ".openclaw-state\$pm2Name"),
    (Join-Path $env:USERPROFILE ".openclaw-state\pw_$BotName"),
    (Join-Path $env:USERPROFILE ".openclaw-state\$BotName"),
    (Join-Path $env:USERPROFILE ".openclaw-state\${BotName}_bot")
  )

  Write-Host ""
  Write-Host "Removing: $pm2Name"
  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($pm2) {
    pm2 stop $pm2Name 2>$null | Out-Null
    pm2 delete $pm2Name 2>$null | Out-Null
    Remove-Item -Path (Join-Path $env:USERPROFILE ".pm2\logs\*$pm2Name*") -Force -ErrorAction SilentlyContinue
  }

  foreach ($path in @($profiles + $states + @($workdir))) {
    if (Test-Path -LiteralPath $path) {
      if (Test-SafeDeletePath -Path $path -BotName $BotName) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Deleted: $path"
      } else {
        Write-Host "Skipped unsafe path: $path"
      }
    }
  }
}

function Remove-ProactiveRunner {
  Write-Host ""
  Write-Host "Removing Phoenix proactive runner..."
  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($pm2) {
    pm2 stop phoenix_proactive_nudge 2>$null | Out-Null
    pm2 delete phoenix_proactive_nudge 2>$null | Out-Null
    Remove-Item -Path (Join-Path $env:USERPROFILE ".pm2\logs\*phoenix_proactive_nudge*") -Force -ErrorAction SilentlyContinue
  }

  $expected = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE "antigravity\openclaw"))
  if ((Test-Path -LiteralPath $workspace) -and ([System.IO.Path]::GetFullPath($workspace) -eq $expected)) {
    foreach ($path in @(
      (Join-Path $workspace "Phoenix_Proactive_Nudge.cjs"),
      (Join-Path $workspace "Phoenix_Ready_Notice.ps1"),
      (Join-Path $workspace "logs\phoenix_proactive_nudge.log")
    )) {
      if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host "Deleted: $path"
      }
    }
  }

  $startupFolder = [Environment]::GetFolderPath('Startup')
  if (-not [string]::IsNullOrWhiteSpace($startupFolder)) {
    $startupVbs = Join-Path $startupFolder "Phoenix_PM2_Stealth.vbs"
    if (Test-Path -LiteralPath $startupVbs) {
      Remove-Item -LiteralPath $startupVbs -Force -ErrorAction SilentlyContinue
      Write-Host "Deleted startup resurrect script: $startupVbs"
    }
  }
}

function Update-Ecosystem {
  param([string[]]$Pm2Names)
  $ecosystem = Join-Path $workspace "ecosystem.config.js"
  if (-not (Test-Path -LiteralPath $ecosystem)) { return }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return }
  node -e "const fs=require('fs'); const p=process.argv[1]; const names=new Set(process.argv.slice(2)); let cfg=require(p); cfg.apps=(cfg.apps||[]).filter(a=>!names.has(a.name)); fs.writeFileSync(p,'module.exports = '+JSON.stringify(cfg,null,2)+';\n');" $ecosystem @Pm2Names 2>$null
}

function Update-GlobalOpenClawConfig {
  param([string[]]$Pm2Names)
  $globalConf = Join-Path $env:USERPROFILE ".openclaw\openclaw.json"
  if (-not (Test-Path -LiteralPath $globalConf)) { return }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return }
  node -e "const fs=require('fs'); const p=process.argv[1]; const names=new Set(process.argv.slice(2)); try{const cfg=JSON.parse(fs.readFileSync(p,'utf8').replace(/^\uFEFF/,'')); if(cfg.agents&&Array.isArray(cfg.agents.list)){cfg.agents.list=cfg.agents.list.filter(a=>a&&!names.has(a.id)&&!names.has(a.name)); fs.writeFileSync(p,JSON.stringify(cfg,null,2)+'\n','utf8');}}catch{}" $globalConf @Pm2Names 2>$null
}

function Remove-AllOpenClawState {
  Write-Host ""
  Write-Host "Removing global OpenClaw state for clean reinstall..."
  $paths = @(
    (Join-Path $env:USERPROFILE ".openclaw"),
    (Join-Path $env:USERPROFILE ".openclaw-state")
  )
  $paths += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\.openclaw-(?:pw_)?(?:genesis|power|design|video|writer)(?:_bot|-bot)?$' } |
    Select-Object -ExpandProperty FullName)

  foreach ($path in ($paths | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $path) {
      $full = [System.IO.Path]::GetFullPath($path)
      $userHome = [System.IO.Path]::GetFullPath($env:USERPROFILE)
      if ($full.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase) -and $full -ne $userHome -and $full.Length -gt 10) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Deleted: $full"
      }
    }
  }

  $startupFolder = [Environment]::GetFolderPath('Startup')
  if (-not [string]::IsNullOrWhiteSpace($startupFolder)) {
    $startupVbs = Join-Path $startupFolder "Phoenix_PM2_Stealth.vbs"
    if (Test-Path -LiteralPath $startupVbs) {
      Remove-Item -LiteralPath $startupVbs -Force -ErrorAction SilentlyContinue
      Write-Host "Deleted startup resurrect script: $startupVbs"
    }
  }
}

function Remove-PhoenixGlobalRuntimeTools {
  Write-Host ""
  Write-Host "Removing Phoenix OpenClaw runtime packages for clean reinstall..."
  $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if (-not $npm) { Write-Host "npm.cmd not found. Skipping global runtime uninstall."; return }
  $packages = @('openclaw','clawhub','@openclaw/codex')
  & $npm.Source uninstall -g @packages 2>$null | Out-Null
  Write-Host "Global OpenClaw runtime uninstall attempted. OpenAI Codex CLI is kept to avoid replacing a running codex.exe."

  $scopeCandidates = New-Object System.Collections.Generic.List[string]
  try {
    $npmRoot = (& $npm.Source root -g 2>$null | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($npmRoot)) { $scopeCandidates.Add((Join-Path $npmRoot "@openclaw")) }
  } catch {}
  if ($env:APPDATA) { $scopeCandidates.Add((Join-Path $env:APPDATA "npm\node_modules\@openclaw")) }
  foreach ($scope in ($scopeCandidates | Sort-Object -Unique)) {
    if ((Test-Path -LiteralPath $scope) -and -not (Get-ChildItem -LiteralPath $scope -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      Remove-Item -LiteralPath $scope -Recurse -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $scope)) { Write-Host "Deleted empty OpenClaw npm scope: $scope" }
    }
  }

  if ($env:APPDATA) {
    $npmBin = Join-Path $env:APPDATA "npm"
    foreach ($shim in @('openclaw','openclaw.cmd','openclaw.ps1','clawhub','clawhub.cmd','clawhub.ps1')) {
      $path = Join-Path $npmBin $shim
      if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $path)) { Write-Host "Deleted OpenClaw runtime shim residue: $path" }
      }
    }
  }
}

function Clear-PhoenixPm2Dump {
  param(
    [string[]]$Pm2Names = @(),
    [switch]$AllPhoenix
  )
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return }
  $mode = if ($AllPhoenix) { "all" } else { "selected" }
  $names = @($Pm2Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if (-not $AllPhoenix -and $names.Count -eq 0) { return }
  foreach ($pm2Dump in @((Join-Path $env:USERPROFILE ".pm2\dump.pm2"), (Join-Path $env:USERPROFILE ".pm2\dump.pm2.bak"))) {
    if (-not (Test-Path -LiteralPath $pm2Dump)) { continue }
    $result = node -e "const fs=require('fs');const p=process.argv[1];const mode=process.argv[2];const names=new Set(process.argv.slice(3));let a=[];try{a=JSON.parse((fs.readFileSync(p,'utf8')||'[]').replace(/^\uFEFF/,''))}catch(e){process.exit(0)}if(!Array.isArray(a))process.exit(0);const isPhoenix=n=>/^pw_.*_bot$/.test(n)||n==='phoenix_proactive_nudge';const keep=a.filter(x=>{const n=String(x&&x.name||'');return mode==='all' ? !isPhoenix(n) : !names.has(n)});if(keep.length!==a.length){fs.writeFileSync(p,JSON.stringify(keep,null,2)+'\n','utf8');console.log(a.length-keep.length)}" $pm2Dump $mode @names 2>$null
    if ($result) { Write-Host "Updated PM2 dump $(Split-Path -Leaf $pm2Dump): removed $result Phoenix entries." }
  }
}

function Test-NonPhoenixPm2DumpState {
  foreach ($pm2Dump in @((Join-Path $env:USERPROFILE ".pm2\dump.pm2"), (Join-Path $env:USERPROFILE ".pm2\dump.pm2.bak"))) {
    if (-not (Test-Path -LiteralPath $pm2Dump)) { continue }
    try {
      $text = [System.IO.File]::ReadAllText($pm2Dump, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $apps = @($text | ConvertFrom-Json)
      foreach ($app in $apps) {
        $name = [string]$app.name
        if ($name -and $name -notmatch '^pw_.*_bot$' -and $name -ne 'phoenix_proactive_nudge') { return $true }
      }
    } catch {}
  }
  return $false
}

function Test-NonPhoenixPm2LiveState {
  if (-not (Test-Pm2StateExists)) { return $false }
  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if (-not $pm2) { return $false }
  try {
    $json = (pm2 jlist 2>$null) -join ""
    if ([string]::IsNullOrWhiteSpace($json)) { return $false }
    $apps = @($json | ConvertFrom-Json)
    foreach ($app in $apps) {
      $name = [string]$app.name
      if ($name -and $name -notmatch '^pw_.*_bot$' -and $name -ne 'phoenix_proactive_nudge') { return $true }
    }
  } catch {}
  return $false
}

function Test-NonPhoenixPm2State {
  return ((Test-NonPhoenixPm2DumpState) -or (Test-NonPhoenixPm2LiveState))
}

function Remove-Pm2GlobalShellsIfSafe {
  if (Test-NonPhoenixPm2State) {
    Write-Host "Preserved PM2 global state because non-Phoenix PM2 entries exist."
    return
  }

  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($pm2 -and (Test-Pm2StateExists)) {
    pm2 kill 2>$null | Out-Null
    Write-Host "Stopped PM2 daemon because no non-Phoenix PM2 state remains."
  }

  $pm2Root = Join-Path $env:USERPROFILE ".pm2"
  if (Test-Path -LiteralPath $pm2Root) {
    Remove-Item -LiteralPath $pm2Root -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $pm2Root)) { Write-Host "Deleted PM2 global state: $pm2Root" }
  }
}

function Save-Pm2ProcessList {
  param(
    [string[]]$Pm2Names = @(),
    [switch]$AllPhoenix
  )
  Clear-PhoenixPm2Dump -Pm2Names $Pm2Names -AllPhoenix:$AllPhoenix
  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($AllPhoenix) {
    if (Test-NonPhoenixPm2State) {
      if ($pm2 -and (Test-Pm2StateExists)) { pm2 save --force 2>$null | Out-Null }
      Clear-PhoenixPm2Dump -Pm2Names $Pm2Names -AllPhoenix:$AllPhoenix
    } else {
      Remove-Pm2GlobalShellsIfSafe
    }
  } else {
    if ($pm2 -and (Test-Pm2StateExists)) { pm2 save --force 2>$null | Out-Null }
    Clear-PhoenixPm2Dump -Pm2Names $Pm2Names -AllPhoenix:$AllPhoenix
  }
}

function Remove-ResidualPhoenixWorkspace {
  if (-not (Test-Path -LiteralPath $workspace)) { return }
  $expected = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE "antigravity\openclaw"))
  $full = [System.IO.Path]::GetFullPath($workspace)
  if ($full -ne $expected) { return }

  Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $workspace)) { Write-Host "Deleted residual workspace root: $workspace" }
}

function Confirm-PhoenixCleanState {
  param(
    [switch]$FullReset,
    [string[]]$RemovedBots = @(),
    [string[]]$RemovedPm2Names = @()
  )

  Write-Host ""
  Write-Host "Post-clean verification..."

  $residual = New-Object System.Collections.Generic.List[string]

  if ($FullReset) {
    if (Test-Path -LiteralPath $workspace) {
      Get-ChildItem -LiteralPath $workspace -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '_bot$|^pw_' } |
        ForEach-Object { $residual.Add($_.FullName) }
    }

    Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\.openclaw-(?:pw_)?(?:genesis|power|design|video|writer)(?:_bot|-bot)?$' } |
      ForEach-Object { $residual.Add($_.FullName) }
  } else {
    foreach ($bot in $RemovedBots) {
      $pm2Name = "pw_${bot}_bot"
      $paths = @(
        (Join-Path $workspace "${bot}_bot"),
        (Join-Path $env:USERPROFILE ".openclaw-$pm2Name"),
        (Join-Path $env:USERPROFILE ".openclaw-pw_$bot"),
        (Join-Path $env:USERPROFILE ".openclaw-pw_${bot}_bot"),
        (Join-Path $env:USERPROFILE ".openclaw-$bot"),
        (Join-Path $env:USERPROFILE ".openclaw-${bot}_bot"),
        (Join-Path $env:USERPROFILE ".openclaw-${bot}-bot"),
        (Join-Path $env:USERPROFILE ".openclaw-state\$pm2Name"),
        (Join-Path $env:USERPROFILE ".openclaw-state\pw_$bot"),
        (Join-Path $env:USERPROFILE ".openclaw-state\$bot"),
        (Join-Path $env:USERPROFILE ".openclaw-state\${bot}_bot")
      )
      foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { $residual.Add($path) }
      }
    }
  }

  foreach ($pm2Dump in @((Join-Path $env:USERPROFILE ".pm2\dump.pm2"), (Join-Path $env:USERPROFILE ".pm2\dump.pm2.bak"))) {
    if (-not (Test-Path -LiteralPath $pm2Dump)) { continue }
    try {
      $node = Get-Command node -ErrorAction SilentlyContinue
      if ($node) {
        $mode = if ($FullReset) { "all" } else { "selected" }
        $names = @($RemovedPm2Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $pm2Left = node -e "const fs=require('fs');const p=process.argv[1];const mode=process.argv[2];const names=new Set(process.argv.slice(3));const a=JSON.parse((fs.readFileSync(p,'utf8')||'[]').replace(/^\uFEFF/,''));for(const x of a){const n=String(x.name||'');if(mode==='all'){if(/^pw_.*_bot$/.test(n)||n==='phoenix_proactive_nudge') console.log(n)}else if(names.has(n)){console.log(n)}}" $pm2Dump $mode @names 2>$null
        foreach ($name in $pm2Left) { if ($name) { $residual.Add("PM2 $(Split-Path -Leaf $pm2Dump) entry: $name") } }
      }
    } catch {}
  }

  if ($FullReset) {
    foreach ($path in @((Join-Path $env:USERPROFILE ".openclaw"), (Join-Path $env:USERPROFILE ".openclaw-state"))) {
      if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $path) { $residual.Add($path) }
      }
    }
    if (Test-Path -LiteralPath $workspace) { $residual.Add($workspace) }
    foreach ($item in @(Get-PhoenixCredentialInputs)) { $residual.Add("credential input residual: $item") }
    foreach ($item in @(Get-LegacyPhoenixPackages)) { $residual.Add("legacy package residual: $item") }
    foreach ($item in @(Get-PhoenixDeveloperToolResiduals)) { $residual.Add("developer tool residual: $item") }
    if (-not (Test-NonPhoenixPm2State)) {
      $pm2Root = Join-Path $env:USERPROFILE ".pm2"
      if (Test-Path -LiteralPath $pm2Root) { $residual.Add($pm2Root) }
    }
  }

  if ($residual.Count -eq 0) {
    Write-Host "Clean verification passed: no Phoenix bot/OpenClaw residual state found."
  } else {
    Write-Host "WARNING: residual items still found after cleanup:"
    $residual | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
  }
}

$installedBots = @(Get-InstalledPhoenixBots)
if ($installedBots.Count -eq 0 -and -not $All) {
  Write-Host "No installed Phoenix bots were found."
  exit 0
}

if (-not $All -and -not $Bot) {
  Write-Host "Phoenix Agent v2.0 Super Cleaning Bot"
  Write-Host "Installed bots: $($installedBots -join ', ')"
  Write-Host "  [1] Remove one installed bot"
  Write-Host "  [2] Remove all currently installed bots"
  Write-Host "  [Q] Cancel"
  $mode = Read-Host "Action: type 1 to delete one installed bot, type 2 to delete all currently installed bots, or type Q to cancel"
  if ($mode -eq "2") { $All = $true }
  elseif ($mode -eq "1") {
    for ($i = 0; $i -lt $installedBots.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $installedBots[$i]) }
    $choice = Read-Host "Action: type the number or exact bot name you want to delete, then press Enter"
    if ($choice -match '^\d+$') {
      $idx = [int]$choice - 1
      if ($idx -ge 0 -and $idx -lt $installedBots.Count) { $Bot = $installedBots[$idx] }
    } else { $Bot = $choice }
  } else {
    Write-Host "Cancelled."
    exit 0
  }
}

$targets = @()
if ($All) {
  $targets = $installedBots
} else {
  $Bot = Normalize-BotName $Bot
  if ($installedBots -notcontains $Bot) {
    Write-Host "Bot not found among installed bots. Installed: $($installedBots -join ', ')"
    exit 1
  }
  $targets = @($Bot)
}

Write-Host ""
Write-Host "Phoenix Agent v2.0 Super Cleaning Bot"
Write-Host "Targets: $($targets -join ', ')"
Write-Host "Deletes: PM2 process, bot work folder, bot-specific OpenClaw profile, .openclaw-state, PM2 logs."
Write-Host "Also removes bot-local Telegram token/chat-id/channel config, Telegram pairing state, ecosystem entries, and legacy global openclaw.json bot entries."
Write-Host "Credential cleanup: installed bot runtime Telegram/OpenClaw credential files are deleted with the target bot/profile, but installer key folders are kept and values are never printed."
if ($All) {
  Write-Host "Full reset mode also deletes global OpenClaw state, OpenClaw runtime packages, Phoenix_PM2_Stealth.vbs, empty @openclaw npm scopes, OpenClaw shims, and PM2 global shells when no non-Phoenix PM2 state remains."
}
Write-Host "Keeps: installer/package key folders, Phoenix Agent zip/folders, Node.js, Git, PM2 binary, OpenAI Codex CLI, Claude Code, Antigravity, unrelated files. Full reset removes OpenClaw/clawhub/@openclaw/codex packages so the installer can reinstall a clean matched set."
Invoke-PerBotOutputsBackup -Bots $targets -Choice $BackupOutputs

if ($All) {
  $confirm = if ($ConfirmText) { $ConfirmText } else { Read-Host "Action: to permanently delete all currently installed bots, type DELETE ALL INSTALLED PHOENIX BOTS exactly" }
  if ($confirm -ne "DELETE ALL INSTALLED PHOENIX BOTS") { Write-Host "Cancelled."; exit 0 }
} else {
  $confirm = if ($ConfirmText) { $ConfirmText } else { Read-Host "Action: to permanently delete this bot, type DELETE $($targets[0]) exactly" }
  if ($confirm -ne "DELETE $($targets[0])") { Write-Host "Cancelled."; exit 0 }
}

foreach ($bot in $targets) { Remove-OneBot -BotName $bot }
$pm2Targets = @($targets | ForEach-Object { "pw_${_}_bot" })
Update-Ecosystem -Pm2Names $pm2Targets
Update-GlobalOpenClawConfig -Pm2Names $pm2Targets
$removeProactive = $false
if ($All -or (@(Get-InstalledPhoenixBots).Count -eq 0)) {
  Remove-ProactiveRunner
  $removeProactive = $true
}
if ($All) {
  Remove-AllOpenClawState
  Remove-PhoenixCredentialInputs
  Remove-LegacyPhoenixPackages
  Remove-PhoenixDeveloperToolResiduals
  Remove-PhoenixGlobalRuntimeTools
  Remove-ResidualPhoenixWorkspace
}
$dumpTargets = @($pm2Targets)
if ($removeProactive) { $dumpTargets += "phoenix_proactive_nudge" }
Save-Pm2ProcessList -Pm2Names $dumpTargets -AllPhoenix:$All
Confirm-PhoenixCleanState -FullReset:$All -RemovedBots $targets -RemovedPm2Names $dumpTargets
Write-Host ""
Write-Host "Super cleaning complete."
Write-Host "" -ForegroundColor Cyan
Write-Host "[Operation note] PM2 restart after skill updates" -ForegroundColor Cyan
Write-Host "  Super Cleaning Bot is a deletion tool. Do not run it for skill/rule updates only." -ForegroundColor White
Write-Host "  After editing SOUL.md, USER.md, AGENTS.md, skills\SKILL.md, or skills\scripts, restart the bot." -ForegroundColor White
Write-Host "     pm2 restart <bot PM2 name>" -ForegroundColor Yellow
Write-Host "  Example: pm2 restart pw_writer_bot" -ForegroundColor Gray
Write-Host "  Restart all active bots:" -ForegroundColor White
Write-Host "     pm2 restart pw_genesis_bot pw_power_bot pw_design_bot pw_video_bot pw_writer_bot" -ForegroundColor Yellow
Write-Host "  Check:" -ForegroundColor White
Write-Host "     pm2 list" -ForegroundColor Gray
