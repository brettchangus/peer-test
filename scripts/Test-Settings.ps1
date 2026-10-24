param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$workspace=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($workspace)
$initializer=Join-Path $PSScriptRoot 'Initialize-Settings.ps1'
$result=& $initializer -WorkspacePath $workspace
if($result.status -ne 'NeedsConfiguration' -or !(Test-Path -LiteralPath $result.settingsPath)){throw 'Missing settings were not created and blocked.'}
$expected=Join-Path $workspace '.agents/skills/peer-review/settings.local.json'
if([IO.Path]::GetFullPath($result.settingsPath) -ne [IO.Path]::GetFullPath($expected)){throw 'Settings were created outside the workspace location.'}
$example=Join-Path $PSScriptRoot '../examples/settings.example.json'
if((Get-FileHash $example).Hash -ne (Get-FileHash $expected).Hash){throw 'Example copy differs.'}
$before=(Get-FileHash $expected).Hash
$result=& $initializer -WorkspacePath $workspace
if($result.status -ne 'NeedsConfiguration' -or (Get-FileHash $expected).Hash -ne $before){throw 'Unconfigured settings were overwritten or allowed.'}
$settings=Get-Content $expected -Raw | ConvertFrom-Json
$settings.configured=$true
$settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $expected
$before=(Get-FileHash $expected).Hash
$result=& $initializer -WorkspacePath $workspace
if($result.status -ne 'Configured' -or (Get-FileHash $expected).Hash -ne $before){throw 'Configured settings were overwritten or rejected.'}
'invalid JSON' | Set-Content -LiteralPath $expected
$before=(Get-FileHash $expected).Hash
$result=& $initializer -WorkspacePath $workspace
if($result.status -ne 'NeedsConfiguration' -or (Get-FileHash $expected).Hash -ne $before){throw 'Invalid settings were overwritten or allowed.'}
$ignorePath=Join-Path $workspace '.agents/skills/peer-review/.gitignore'
[IO.File]::WriteAllText($ignorePath,'/existing-rule')
$null=& $initializer -WorkspacePath $workspace
$ignore=[IO.File]::ReadAllText($ignorePath)
if($ignore.EndsWith("`n") -or !$ignore.StartsWith('/existing-rule')){throw 'Existing ignore content or trailing newline changed.'}
foreach($rule in @('/settings.local.json','/hints.local.md','/.history/')){
  if($rule -notin ($ignore -split '\r?\n')){throw 'Required local ignore rule missing.'}
}
@{validation='PASS';checks=7;requests=0;output=$workspace} | ConvertTo-Json -Compress
