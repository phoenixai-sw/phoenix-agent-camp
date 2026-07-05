param(
  [switch]$CheckOnly,
  [switch]$ApplyAcOnly,
  [switch]$ApplyAcDc
)

$ErrorActionPreference = "Stop"
$LidActionGuid = "5ca83367-6e45-459f-a27b-476b1d01c936"

function Show-Header {
  Write-Host ""
  Write-Host "Phoenix Agent v2.0 Windows laptop awake-mode helper" -ForegroundColor Cyan
  Write-Host "Purpose: keep local Phoenix Agent bots running when the laptop lid is closed." -ForegroundColor Cyan
  Write-Host ""
  Write-Host "Important:" -ForegroundColor Yellow
  Write-Host "- This changes Windows power settings only when you choose an apply menu."
  Write-Host "- The laptop must still be powered on and connected to the internet."
  Write-Host "- If the power is off or the battery is drained, local bots cannot run."
  Write-Host ""
}

function Show-CurrentSettings {
  Write-Host "== Active power scheme =="
  powercfg /GETACTIVESCHEME
  Write-Host ""

  Write-Host "== Lid close action =="
  powercfg /ATTRIBUTES SUB_BUTTONS $LidActionGuid -ATTRIB_HIDE 2>$null | Out-Null
  powercfg /QUERY SCHEME_CURRENT SUB_BUTTONS $LidActionGuid
  Write-Host ""

  Write-Host "== Sleep timeout =="
  powercfg /QUERY SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
  Write-Host ""

  Write-Host "== Hibernate timeout =="
  powercfg /QUERY SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE
  Write-Host ""
}

function Apply-AcOnly {
  Write-Host "Applying AC-power settings..." -ForegroundColor Green
  powercfg /ATTRIBUTES SUB_BUTTONS $LidActionGuid -ATTRIB_HIDE 2>$null | Out-Null
  powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS $LidActionGuid 0
  powercfg /CHANGE standby-timeout-ac 0
  powercfg /CHANGE hibernate-timeout-ac 0
  powercfg /SETACTIVE SCHEME_CURRENT
}

function Apply-AcDc {
  Write-Host "Applying AC and battery settings..." -ForegroundColor Green
  Write-Host "Battery warning: bots can drain the battery if the lid is closed for a long time." -ForegroundColor Yellow
  powercfg /ATTRIBUTES SUB_BUTTONS $LidActionGuid -ATTRIB_HIDE 2>$null | Out-Null
  powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS $LidActionGuid 0
  powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS $LidActionGuid 0
  powercfg /CHANGE standby-timeout-ac 0
  powercfg /CHANGE standby-timeout-dc 0
  powercfg /CHANGE hibernate-timeout-ac 0
  powercfg /CHANGE hibernate-timeout-dc 0
  powercfg /SETACTIVE SCHEME_CURRENT
}

Show-Header

if ($CheckOnly) {
  Show-CurrentSettings
  exit 0
}

if ($ApplyAcOnly) {
  Apply-AcOnly
  Show-CurrentSettings
  exit 0
}

if ($ApplyAcDc) {
  Apply-AcDc
  Show-CurrentSettings
  exit 0
}

Write-Host "Choose a menu:" -ForegroundColor White
Write-Host "1. Check current lid/sleep/hibernate settings only"
Write-Host "2. Apply recommended AC-power mode only"
Write-Host "3. Apply AC + battery mode"
Write-Host "4. Exit"
Write-Host ""
$choice = Read-Host "Enter 1, 2, 3, or 4"

switch ($choice) {
  "1" { Show-CurrentSettings }
  "2" { Apply-AcOnly; Show-CurrentSettings }
  "3" { Apply-AcDc; Show-CurrentSettings }
  default { Write-Host "No change applied." }
}
