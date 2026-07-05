# Phoenix package release: v1.9
param(
  [ValidateSet('genesis','power','design','video','writer')]
  [string]$Bot = "",

  [ValidateSet('openai','gemini','google','google-gemini','gemini-selected')]
  [string]$AuthMode = ""
)

$ErrorActionPreference = "Stop"

$botLabels = [ordered]@{
  genesis = "Genesis Bot - command center, service design, coding prompts"
  power   = "Power Bot   - reports, research, market/trend analysis"
  design  = "Design Bot  - images, landing pages, thumbnails, PPT visuals"
  video   = "Video Bot   - video concepts, short-form, fal.ai generation"
  writer  = "Writer Bot  - manuscripts, publishing, copywriting, editing"
}

if (-not $Bot) {
  Write-Host ""
  Write-Host "Phoenix Agent v1.9 Installer"
  Write-Host "Choose one bot to install. Run this installer once per bot."
  Write-Host ""
  Write-Host "Before install:"
  Write-Host "  - Fill telegram_access_token.txt in 1. 인증키_API 키 모음, then copy/move it into installer before running."
  Write-Host "  - Fill telegram_chat_id.txt in 1. 인증키_API 키 모음, then copy/move it into installer before running."
  Write-Host "  - If either required file is missing, the installer stops and names the missing file."
  Write-Host "  - Optional: the installer asks whether to add image/video API keys only for bots that use them."
  Write-Host "  - Default conversation auth is OpenAI/Codex. To choose Gemini API, run this installer with -AuthMode gemini."
  Write-Host "  - Secret values are never printed."
  Write-Host ""
  Write-Host "Install options:"
  Write-Host "  [1] $($botLabels.genesis)"
  Write-Host "  [2] $($botLabels.power)"
  Write-Host "  [3] $($botLabels.design)"
  Write-Host "  [4] $($botLabels.video)"
  Write-Host "  [5] $($botLabels.writer)"
  Write-Host "  [Q] Cancel"
  $choice = Read-Host "Type 1, 2, 3, 4, 5, or Q, then press Enter"

  switch -Regex ($choice.Trim().ToLowerInvariant()) {
    '^(1|genesis)$' { $Bot = 'genesis'; break }
    '^(2|power)$'   { $Bot = 'power'; break }
    '^(3|design)$'  { $Bot = 'design'; break }
    '^(4|video)$'   { $Bot = 'video'; break }
    '^(5|writer)$'  { $Bot = 'writer'; break }
    default {
      Write-Host "Cancelled."
      exit 0
    }
  }
}

$target = Join-Path $PSScriptRoot ("install_{0}_bot.ps1" -f $Bot)
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "Bot installer not found: $target"
}

Write-Host ""
Write-Host ("Starting Phoenix Agent v1.9 installer: {0}" -f $botLabels[$Bot])
if (-not [string]::IsNullOrWhiteSpace($AuthMode)) {
  & $target -AuthMode $AuthMode
} else {
  & $target
}
exit $LASTEXITCODE
