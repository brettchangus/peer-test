param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-LocalFixture.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture syntax errors.'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-TestAndRestore'},$true)
if(!$function){throw 'Fixture test/restoration handler missing.'}
# Load the production handler alone; fixture settings and database operations are not executed.
. ([scriptblock]::Create($function.Extent.Text))
$executable=(Get-Process -Id $PID).Path
$exitScript=Join-Path $OutputDirectory 'exit-test.ps1'
'exit 7' | Set-Content -LiteralPath $exitScript
$script:restored=$false
$global:LASTEXITCODE=9
Invoke-TestAndRestore {} {$script:restored=$true}
if(!$script:restored){throw 'Successful test was not restored.'}
$checks=1
foreach($scenario in @('exit-failure','script-exit-failure','throw-failure','restore-failure','both-fail')) {
  $script:restored=$false;$failure=$null
  $testBlock=switch($scenario) {
    'exit-failure' {{& $executable -NoProfile -Command 'exit 1'}}
    'script-exit-failure' {{& $exitScript}}
    'throw-failure' {{throw 'Synthetic test failure'}}
    'restore-failure' {{}}
    'both-fail' {{throw 'Synthetic test failure'}}
  }
  $restoreBlock={
    $script:restored=$true
    if($scenario -in @('restore-failure','both-fail')){throw 'Synthetic restoration failure'}
  }
  try {Invoke-TestAndRestore $testBlock $restoreBlock}catch{$failure=$_.Exception}
  if(!$script:restored -or !$failure){throw "Failure or restoration lost: $scenario"}
  if($scenario -eq 'exit-failure' -and $failure.Message -notmatch 'exit code 1'){throw 'External test exit status was lost.'}
  if($scenario -eq 'script-exit-failure' -and $failure.Message -notmatch 'exit code 7'){throw 'PowerShell test exit status was lost.'}
  if($scenario -eq 'both-fail'){
    if($failure -isnot [AggregateException] -or $failure.InnerExceptions.Count -ne 2){throw 'Combined failure must retain both exceptions.'}
    if($failure.InnerExceptions[0].Message -ne 'Synthetic test failure' -or $failure.InnerExceptions[1].Message -ne 'Synthetic restoration failure'){throw 'Combined failure details were lost.'}
  }
  $checks++
}
# Check the process exit status callers receive when the production handler throws after cleanup.
$driver=Join-Path $OutputDirectory 'outcome-driver.ps1'
$function.Extent.Text + "`r`nInvoke-TestAndRestore { throw 'Synthetic test failure' } { }" | Set-Content -LiteralPath $driver
$ignored=& $executable -NoProfile -File $driver 2>&1
if($LASTEXITCODE -eq 0){throw 'Fixture failure must produce a nonzero process exit status.'};$checks++
@{validation='PASS';checks=$checks;requests=0;output=$OutputDirectory} | ConvertTo-Json -Compress
