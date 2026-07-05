# Phoenix package release: v1.9
param(
  [ValidateSet('openai','gemini','google','google-gemini','gemini-selected')]
  [string]$AuthMode = ''
)
if (-not [string]::IsNullOrWhiteSpace($AuthMode)) {
  $env:PHOENIX_MODEL_AUTH_MODE = $AuthMode
}
$PhoenixBotName = 'video'
$PhoenixDisplayName = 'Video Bot'
. $PSScriptRoot\phoenix_agent_install_core.ps1