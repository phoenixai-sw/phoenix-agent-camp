# Phoenix package release: v2.0_260706
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("genesis","power","design","video","writer")]
  [string]$BotName
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$pairingFile = Join-Path $PSScriptRoot "telegram_pairing_code.txt"
if (-not (Test-Path -LiteralPath $pairingFile)) {
  throw "telegram_pairing_code.txt was not found in the installer folder. Put only the Telegram pairing code in that file."
}

$pairingCode = (Get-Content -LiteralPath $pairingFile -Raw).Trim()
if ($pairingCode -notmatch '^[A-Za-z0-9_-]{4,32}$') {
  throw "telegram_pairing_code.txt format looks invalid. Put only the pairing code on one line, with no label or extra text."
}

$profile = "pw_${BotName}_bot"
Write-Host "Approving Telegram pairing from telegram_pairing_code.txt for $profile. The code value will not be printed." -ForegroundColor Yellow
& openclaw --profile $profile pairing approve telegram $pairingCode
if ($LASTEXITCODE -ne 0) { throw "Pairing approve failed for $profile." }

if ($env:PHOENIX_AUTO_DELETE_PAIRING_FILE -eq '1') {
  Remove-Item -LiteralPath $pairingFile -Force -ErrorAction SilentlyContinue
  Write-Host "  OK: telegram_pairing_code.txt deleted from installer folder." -ForegroundColor Green
  exit 0
}

$answer = Read-Host "Action: delete telegram_pairing_code.txt from installer folder now for security? [Y/n]"
if ($answer -notmatch '^[Nn]$') {
  Remove-Item -LiteralPath $pairingFile -Force -ErrorAction SilentlyContinue
  Write-Host "  OK: telegram_pairing_code.txt deleted from installer folder." -ForegroundColor Green
} else {
  Write-Host "  SECURITY WARNING: telegram_pairing_code.txt remains in the installer folder." -ForegroundColor Yellow
}
