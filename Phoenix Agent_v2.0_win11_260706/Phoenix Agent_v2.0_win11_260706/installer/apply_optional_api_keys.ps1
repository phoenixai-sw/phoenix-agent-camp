# Phoenix package release: v2.0_260706
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Set-PhoenixEnvValue {
  param(
    [Parameter(Mandatory=$true)][string]$EnvFile,
    [Parameter(Mandatory=$true)][string]$Key,
    [Parameter(Mandatory=$true)][string]$Value
  )

  $lines = @()
  if (Test-Path -LiteralPath $EnvFile) {
    $lines = [System.IO.File]::ReadAllText($EnvFile, [System.Text.Encoding]::UTF8).TrimEnd("`r","`n") -split '\r?\n'
  }
  $found = $false
  $lines = @($lines | ForEach-Object {
    if ($_ -eq $Key -or $_.StartsWith("$Key=") -or $_.StartsWith("# $Key=") -or $_.StartsWith("#$Key=")) {
      $found = $true
      "$Key=$Value"
    } else {
      $_
    }
  })
  if (-not $found) { $lines += "$Key=$Value" }
  [System.IO.File]::WriteAllText($EnvFile, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Confirm-PhoenixDeleteInstallerFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $name = Split-Path -Leaf $Path
  $answer = Read-Host "Action: delete $name from installer folder now for security? [Y/n]"
  if ($answer -notmatch '^[Nn]$') {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Write-Host "  OK: $name deleted from installer folder." -ForegroundColor Green
  } else {
    Write-Host "  SECURITY WARNING: $name remains in the installer folder." -ForegroundColor Yellow
  }
}

$workspace = Join-Path $env:USERPROFILE "antigravity\openclaw"
$changed = $false
$apiFile = Join-Path $PSScriptRoot "openai_api_key_image.txt"
$apiSourceFile = $null
if (Test-Path -LiteralPath $apiFile) {
  $apiSourceFile = $apiFile
}
if ($apiSourceFile) {
  $imageKey = (Get-Content -LiteralPath $apiSourceFile -Raw).Trim()
  $apiSourceName = Split-Path -Leaf $apiSourceFile
  if ($imageKey -notmatch '^sk-') { throw "$apiSourceName does not look like an OpenAI API key." }
  foreach ($bot in @("design","writer")) {
    $envFile = Join-Path $workspace "$($bot)_bot\.env"
    if (-not (Test-Path -LiteralPath $envFile)) { continue }
    Set-PhoenixEnvValue -EnvFile $envFile -Key "OPENAI_API_KEY_IMAGE" -Value $imageKey
    Set-PhoenixEnvValue -EnvFile $envFile -Key "GPT_IMAGE_PRIMARY" -Value "gpt-image-2-high"
    Set-PhoenixEnvValue -EnvFile $envFile -Key "GPT_IMAGE_FALLBACK" -Value "gpt-image-2-medium"
    Set-PhoenixEnvValue -EnvFile $envFile -Key "GPT_IMAGE_EMERGENCY" -Value "gpt-image-2-low"
    pm2 restart "pw_${bot}_bot" --update-env 2>$null | Out-Null
    Write-Host "  OK: $apiSourceName applied to $($bot)_bot .env. Value was not printed." -ForegroundColor Green
    $changed = $true
  }
  Confirm-PhoenixDeleteInstallerFile -Path $apiSourceFile
}

$falFile = Join-Path $PSScriptRoot "falai_api_key_video.txt"
$falSourceFile = $null
if (Test-Path -LiteralPath $falFile) {
  $falSourceFile = $falFile
}
if ($falSourceFile) {
  $videoKey = (Get-Content -LiteralPath $falSourceFile -Raw).Trim()
  $sourceName = Split-Path -Leaf $falSourceFile
  if ([string]::IsNullOrWhiteSpace($videoKey)) { throw "$sourceName is empty." }
  $envFile = Join-Path $workspace "video_bot\.env"
  if (Test-Path -LiteralPath $envFile) {
    Set-PhoenixEnvValue -EnvFile $envFile -Key "FALAI_API_KEY_VIDEO" -Value $videoKey
    pm2 restart "pw_video_bot" --update-env 2>$null | Out-Null
    Write-Host "  OK: $sourceName applied to video_bot .env as FALAI_API_KEY_VIDEO. Value was not printed." -ForegroundColor Green
    $changed = $true
  }
  Confirm-PhoenixDeleteInstallerFile -Path $falSourceFile
}

if ($changed) {
  pm2 save 2>$null | Out-Null
  Write-Host "Optional API key apply complete. Check PM2/gateway health after OpenClaw finishes prewarm." -ForegroundColor Green
} else {
  Write-Host "No installed target bot found, or no openai_api_key_image.txt / falai_api_key_video.txt was present." -ForegroundColor Yellow
}
