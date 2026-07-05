# Phoenix package release: v2.0_260706
param(
  [ValidateSet('openai','gemini','google','google-gemini','gemini-selected')]
  [string]$AuthMode = ''
)
if (-not [string]::IsNullOrWhiteSpace($AuthMode)) {
  $env:PHOENIX_MODEL_AUTH_MODE = $AuthMode
}
$PhoenixBotName = 'writer'
$PhoenixDisplayName = 'Writer Bot'
. $PSScriptRoot\phoenix_agent_install_core.ps1
