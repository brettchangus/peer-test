param([Parameter(Mandatory)][string]$WorkspacePath)
$ErrorActionPreference='Stop'
$workspace=(Resolve-Path -LiteralPath $WorkspacePath).Path
if(!(Test-Path -LiteralPath $workspace -PathType Container)){throw 'WorkspacePath must be an existing application workspace directory.'}
$directory=Join-Path $workspace '.agents/skills/peer-review'
[void][IO.Directory]::CreateDirectory($directory)
$settingsPath=Join-Path $directory 'settings.local.json'
$ignorePath=Join-Path $directory '.gitignore'
$utf8=New-Object System.Text.UTF8Encoding($false)
$ignoreText=if(Test-Path -LiteralPath $ignorePath){[IO.File]::ReadAllText($ignorePath)}else{''}
$hadNewline=$ignoreText.EndsWith("`n")
$updated=$ignoreText
foreach($rule in @('/settings.local.json','/hints.local.md','/.history/')) {
  if($rule -notin ($updated -split '\r?\n')) {
    if($updated.Length -gt 0 -and !$updated.EndsWith("`n")){$updated+="`r`n"}
    $updated+=$rule+"`r`n"
  }
}
if((Test-Path -LiteralPath $ignorePath) -and !$hadNewline){$updated=$updated.TrimEnd("`r","`n")}
if($updated -cne $ignoreText){
  $bom=$false
  if(Test-Path -LiteralPath $ignorePath){$bytes=[IO.File]::ReadAllBytes($ignorePath);$bom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191}
  [IO.File]::WriteAllText($ignorePath,$updated,(New-Object System.Text.UTF8Encoding($bom)))
}
if(!(Test-Path -LiteralPath $settingsPath)) {
  $example=Join-Path $PSScriptRoot '../examples/settings.example.json'
  # CreateNew prevents overwriting a file created concurrently.
  $stream=[IO.File]::Open($settingsPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
  try{$bytes=[IO.File]::ReadAllBytes($example);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
  [pscustomobject]@{status='NeedsConfiguration';settingsPath=$settingsPath;message='Example copied. Ask the user to configure this file before proceeding with testing.'}
  return
}
try{$settings=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json}catch{
  [pscustomobject]@{status='NeedsConfiguration';settingsPath=$settingsPath;message='Settings JSON is invalid. Ask the user to repair it before proceeding.'}
  return
}
if($settings.schemaVersion -ne 1 -or $settings.configured -isnot [bool] -or !$settings.configured) {
  [pscustomobject]@{status='NeedsConfiguration';settingsPath=$settingsPath;message='Ask the user to complete configuration and set configured to true before proceeding.'}
  return
}
[pscustomobject]@{status='Configured';settingsPath=$settingsPath;message='Validate the selected environment, account role and required settings before testing.'}
