param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
$runner=Join-Path $PSScriptRoot 'Invoke-PeerTest.ps1'
$hostExecutable=(Get-Process -Id $PID).Path
$checks=0
function Exercise([string]$Name,$Response,$Assertions,[string]$ExpectedStatus='FAIL',[hashtable]$CaseOptions=@{},[hashtable]$PlanOptions=@{}) {
  $directory=Join-Path $OutputDirectory $Name; [void][IO.Directory]::CreateDirectory($directory)
  $Response | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $directory 'response.json')
  $case=@{id='case';endpoint='/api/test';payload=@{};replayFile='response.json';assertions=$Assertions}
  foreach($key in $CaseOptions.Keys){$case[$key]=$CaseOptions[$key]}
  $plan=@{ticket='HARNESS';baseUrl='https://localhost:44301';state=$Name;cases=@($case)}
  foreach($key in $PlanOptions.Keys){$plan[$key]=$PlanOptions[$key]}
  $plan | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $directory 'plan.json')
  $output=& $hostExecutable -NoProfile -File $runner -PlanPath (Join-Path $directory 'plan.json') -OutputDirectory (Join-Path $directory 'results') -ReplayDirectory $directory
  $exitCode=$LASTEXITCODE
  $results=Get-Content (Join-Path $directory 'results/results.json') -Raw | ConvertFrom-Json
  if($results.cases[0].status -ne $ExpectedStatus -or (($ExpectedStatus -eq 'PASS') -ne ($exitCode -eq 0))) { throw "Unexpected harness result for $Name" }
  $script:checks++
}
# Missing/null collections must fail validation before evidence output is created.
foreach($field in @('cases','assertions')) {
  foreach($shape in @('missing','null','empty')) {
    $name=$shape+'-'+$field
    $case=@{id='case';endpoint='/api/test';payload=@{};replayFile='response.json';assertions=@(@{type='Present';path='Data'})}
    $plan=@{ticket='HARNESS';baseUrl='https://localhost:44301';cases=@($case)}
    $target=if($field -eq 'cases'){$plan}else{$case}
    switch($shape) {
      'missing' {$target.Remove($field)}
      'null' {$target[$field]=$null}
      'empty' {$target[$field]=@()}
    }
    $planPath=Join-Path $OutputDirectory ($name+'.json')
    $resultPath=Join-Path $OutputDirectory ($name+'-results')
    $plan | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $planPath
    $output=& $hostExecutable -NoProfile -File $runner -PlanPath $planPath -OutputDirectory $resultPath -ReplayDirectory $OutputDirectory 2>&1
    $exitCode=$LASTEXITCODE
    $expectedMessage=if($field -eq 'cases'){'Plan must contain cases.'}else{'Each case must declare assertions.'}
    if($exitCode -eq 0 -or ($output -join "`n") -notmatch [regex]::Escape($expectedMessage) -or (Test-Path -LiteralPath $resultPath)) {
      throw "Collection validation failed: $name"
    }
    $checks++
  }
}
$response=@{ResultCode=0;Data=@{List=@(@{Id=7;Additional='Expected';Other='Expected';Nullable=$null;C1='a';C50='b'});TotalCount=1}}
$equals=@(@{type='Equals';path='Data.List';whereProperty='Id';whereEquals=7;property='Additional';expected='Expected'})
Exercise 'positive' $response ($equals+@(@{type='IsNull';path='Data.List';property='Nullable'},@{type='EqualField';path='Data.List';property='Additional';otherProperty='Other'},@{type='Present';path='Data.List';property='C50'},@{type='Count';path='Data.List';expected=1},@{type='MinCount';path='Data.List';expected=1})) 'PASS'
Exercise 'wrong-value' $response @(@{type='Equals';path='Data.List';property='Additional';expected='Wrong'})
# Equality assertions compare scalar fields; arrays must not become filtering expressions.
foreach($shape in @(
  @{name='empty';value=@()},
  @{name='single';value=@('Expected')},
  @{name='repeated';value=@('Expected','Expected')}
)) {
  $arrayResponse=@{ResultCode=0;Data=@{Actual=$shape.value;Scalar='Expected';Other=$shape.value}}
  Exercise ('equals-array-actual-'+$shape.name) $arrayResponse @(@{type='Equals';path='Data';property='Actual';expected='Expected'})
  Exercise ('equals-array-expected-'+$shape.name) $arrayResponse @(@{type='Equals';path='Data';property='Scalar';expected=$shape.value})
  Exercise ('equal-field-array-left-'+$shape.name) $arrayResponse @(@{type='EqualField';path='Data';property='Actual';otherProperty='Scalar'})
  Exercise ('equal-field-array-right-'+$shape.name) $arrayResponse @(@{type='EqualField';path='Data';property='Scalar';otherProperty='Actual'})
  Exercise ('equal-field-both-arrays-'+$shape.name) $arrayResponse @(@{type='EqualField';path='Data';property='Actual';otherProperty='Other'})
}
Exercise 'equals-case-sensitive' $response @(@{type='Equals';path='Data.List';property='Additional';expected='expected'})
Exercise 'equal-field-case-sensitive' @{ResultCode=0;Data=@{Actual='Expected';Other='expected'}} @(@{type='EqualField';path='Data';property='Actual';otherProperty='Other'})
Exercise 'equals-null-scalar' $response @(@{type='Equals';path='Data.List';property='Nullable';expected=$null}) 'PASS'
Exercise 'equal-field-null-scalars' @{ResultCode=0;Data=@{Actual=$null;Other=$null}} @(@{type='EqualField';path='Data';property='Actual';otherProperty='Other'}) 'PASS'
Exercise 'missing-record' $response @(@{type='Equals';path='Data.List';whereProperty='Id';whereEquals=999;property='Additional';expected='Expected'})
Exercise 'missing-is-not-null' $response @(@{type='IsNull';path='Data.List';property='Missing'})
Exercise 'missing-path' $response @(@{type='Present';path='Data.Missing';property='Id'})
Exercise 'forbidden-property' $response @(@{type='AbsentPattern';path='Data.List';pattern='^C[0-9]+$'})
Exercise 'field-mismatch' $response @(@{type='EqualField';path='Data.List';property='Additional';otherProperty='C1'})
Exercise 'empty-list-not-vacuous-pass' @{ResultCode=0;Data=@{List=@();TotalCount=0}} $equals
Exercise 'empty-list-count' @{ResultCode=0;Data=@{List=@();TotalCount=0}} @(@{type='Count';path='Data.List';expected=0},@{type='Equals';path='Data.TotalCount';expected=0}) 'PASS'
Exercise 'api-error' @{ResultCode=10;Data=$response.Data} $equals
Exercise 'unknown-assertion' $response @(@{type='WrongType';path='Data.List'})
Exercise 'redaction' @{ResultCode=0;AccessToken='synthetic-secret';Data=@{List=@(@{Id=7;Password='synthetic-password'})}} @(@{type='Present';path='Data.List';property='Id'}) 'PASS'
Exercise 'missing-response' $response @(@{type='Equals';path='Data.TotalCount';expected=1}) 'PASS'
$missingDirectory=Join-Path $OutputDirectory 'missing-response'
$missingPlan=Get-Content (Join-Path $missingDirectory 'plan.json') -Raw | ConvertFrom-Json
$missingPlan.cases[0].replayFile='absent.json';$missingPlan | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $missingDirectory 'plan.json')
$ignored=& $hostExecutable -NoProfile -File $runner -PlanPath (Join-Path $missingDirectory 'plan.json') -OutputDirectory (Join-Path $missingDirectory 'blocked') -ReplayDirectory $missingDirectory
$missingResult=Get-Content (Join-Path $missingDirectory 'blocked/results.json') -Raw | ConvertFrom-Json
if($LASTEXITCODE -eq 0 -or $missingResult.blocked -ne 1){throw 'Missing evidence must be blocked.'};$checks++
foreach($guard in @('remote-url','plaintext-http','credential-in-plan','endpoint-traversal','replay-only','key-in-plan','key-in-payload','invalid-method','invalid-mode','get-without-key-auth','invalid-http-status','reserved-results','reserved-results-mixed-case')) {
  $guardPlan=Get-Content (Join-Path $OutputDirectory 'positive/plan.json') -Raw | ConvertFrom-Json
  switch($guard) {
    'reserved-results' {$guardPlan.cases[0].id='results'}
    'reserved-results-mixed-case' {$guardPlan.cases[0].id='ReSuLtS'}
    'remote-url' {$guardPlan.baseUrl='https://example.com'}
    'plaintext-http' {$guardPlan.baseUrl='http://localhost:44301'}
    'credential-in-plan' {$guardPlan.cases[0].payload | Add-Member NoteProperty Password 'synthetic-password'}
    'endpoint-traversal' {$guardPlan.cases[0].endpoint='/api/../outside'}
    'key-in-plan' {$guardPlan | Add-Member NoteProperty ApiKey 'synthetic-key'}
    'key-in-payload' {$guardPlan.cases[0].payload | Add-Member NoteProperty ApiKey 'synthetic-key'}
    'invalid-method' {$guardPlan.cases[0] | Add-Member NoteProperty method 'DELETE'}
    'invalid-mode' {$guardPlan.cases[0] | Add-Member NoteProperty responseMode 'unknown'}
    'get-without-key-auth' {$guardPlan.cases[0] | Add-Member NoteProperty method 'GET'}
    'invalid-http-status' {$guardPlan.cases[0] | Add-Member NoteProperty expectedStatus 999}
    'replay-only' {$guardPlan | Add-Member NoteProperty replayOnly $true}
  }
  $guardPath=Join-Path $OutputDirectory ($guard+'.json');$guardPlan | ConvertTo-Json -Depth 15 | Set-Content $guardPath
  $parameters=@('-NoProfile','-File',$runner,'-PlanPath',$guardPath,'-OutputDirectory',(Join-Path $OutputDirectory ($guard+'-results')))
  if($guard -in @('credential-in-plan','endpoint-traversal','reserved-results','reserved-results-mixed-case')){$parameters+=@('-ReplayDirectory',(Join-Path $OutputDirectory 'positive'))}
  $ignored=& $hostExecutable @parameters 2>&1
  if($LASTEXITCODE -eq 0){throw "Guard failed: $guard"}
  if($guard -like 'reserved-results*') {
    if(($ignored -join "`n") -notmatch 'reserved for the summary filename' -or (Test-Path (Join-Path $OutputDirectory ($guard+'-results')))){throw "Reserved ID must be rejected before output is created: $guard"}
  }
  $checks++
}
$raw=@{method='GET';responseMode='raw';expectedStatus=400};$keyAuth=@{auth='apiKey'}
Exercise 'raw-expected-error' @{statusCode=400;body='Overall API limit reached 2/2'} @(@{type='Matches';path='';pattern='limit.*2/2'}) 'PASS' $raw $keyAuth
Exercise 'raw-wrong-status' @{statusCode=500;body='Overall API limit reached 2/2'} @(@{type='Matches';path='';pattern='limit'}) 'FAIL' $raw $keyAuth
Exercise 'raw-wrong-error' @{statusCode=400;body='Unexpected error'} @(@{type='Matches';path='';pattern='limit'}) 'FAIL' $raw $keyAuth
Exercise 'raw-missing-status' @{body='limit reached'} @(@{type='Matches';path='';pattern='limit'}) 'FAIL' $raw $keyAuth
Exercise 'raw-object' @{statusCode=200;body=@{RecordId=7}} @(@{type='Equals';path='RecordId';expected=7}) 'PASS' @{method='GET';responseMode='raw'} $keyAuth
Exercise 'raw-array' @{statusCode=200;body=@(@{Id=7},@{Id=8})} @(@{type='Count';path='';expected=2},@{type='Equals';path='';whereProperty='Id';whereEquals=7;property='Id';expected=7}) 'PASS' @{method='GET';responseMode='raw'} $keyAuth
# Exercise the production live-response parser without making network requests.
$parseTokens=$null;$parseErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$parseTokens,[ref]$parseErrors)
$liveParser=$runnerAst.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'ConvertFrom-Json' -and $node.Extent.Text -match '\$content'},$true)
if(!$liveParser){throw 'Live response parser was not found.'}
foreach($sample in @(
  @{name='empty';json='[]';count=0},
  @{name='single';json='[{"Id":7}]';count=1},
  @{name='multiple';json='[{"Id":7},{"Id":8}]';count=2},
  @{name='object';json='{"Id":7}'},
  @{name='null';json='null'}
)) {
  $content=$sample.json
  $parsed=& ([scriptblock]::Create($liveParser.Extent.Text))
  if($sample.ContainsKey('count')) {
    if($parsed -isnot [array] -or $parsed.Count -ne $sample.count){throw "Live parser changed array shape: $($sample.name)"}
    $assertions=@(@{type='Count';path='';expected=$sample.count})
  } elseif($sample.name -eq 'null') {
    if($null -ne $parsed){throw 'Live parser changed null.'}
    $assertions=@(@{type='IsNull';path=''})
  } else {
    if($parsed -is [array] -or $parsed.Id -ne 7){throw 'Live parser changed object.'}
    $assertions=@(@{type='Equals';path='Id';expected=7})
  }
  Exercise ('shape-'+$sample.name) @{statusCode=200;body=$parsed} $assertions 'PASS' @{method='GET';responseMode='raw'} $keyAuth
  $savedShape=Get-Content (Join-Path $OutputDirectory ('shape-'+$sample.name+'/results/case.json')) -Raw | ConvertFrom-Json
  if($sample.ContainsKey('count')) {
    if($savedShape.body -isnot [array] -or $savedShape.body.Count -ne $sample.count){throw "Evidence changed array shape: $($sample.name)"}
  } elseif($sample.name -eq 'null') {
    if($null -ne $savedShape.body){throw 'Evidence changed null.'}
  } elseif($savedShape.body -is [array] -or $savedShape.body.Id -ne 7){throw 'Evidence changed object.'}
  $checks++
}
Exercise 'empty-array-is-not-null' @{statusCode=200;body=@()} @(@{type='IsNull';path=''}) 'FAIL' @{method='GET';responseMode='raw'} $keyAuth
Exercise 'expected-business-error' @{ResultCode=10;Message='Denied'} @(@{type='Equals';path='Message';expected='Denied'}) 'PASS' @{expectedResultCode=10}
Exercise 'result-code-http-failure' @{evidenceVersion=1;statusCode=500;body=$response} $equals
Exercise 'result-code-http-success' @{evidenceVersion=1;statusCode=200;body=$response} $equals 'PASS'
$savedEnvelope=Get-Content (Join-Path $OutputDirectory 'positive/results/case.json') -Raw | ConvertFrom-Json
if($savedEnvelope.evidenceVersion -ne 1 -or $savedEnvelope.statusCode -ne 200 -or $savedEnvelope.body.ResultCode -ne 0){throw 'ResultCode evidence must preserve HTTP status and body.'};$checks++
$failureDirectory=Join-Path $OutputDirectory 'result-code-http-failure'
$failurePlan=Get-Content (Join-Path $failureDirectory 'plan.json') -Raw | ConvertFrom-Json
$failurePlan.cases[0].replayFile='case.json'
$failurePlan | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $failureDirectory 'replay-plan.json')
$ignored=& $hostExecutable -NoProfile -File $runner -PlanPath (Join-Path $failureDirectory 'replay-plan.json') -OutputDirectory (Join-Path $failureDirectory 'second-replay') -ReplayDirectory (Join-Path $failureDirectory 'results')
$replayedFailure=Get-Content (Join-Path $failureDirectory 'second-replay/results.json') -Raw | ConvertFrom-Json
if($LASTEXITCODE -eq 0 -or $replayedFailure.failed -ne 1 -or $replayedFailure.cases[0].failures -notcontains 'Unexpected HTTP status: 500; expected 200'){throw 'Saved HTTP failure must remain a failure when replayed.'};$checks++
Exercise 'api-key-redaction' @{statusCode=200;body=@{ApiKey='synthetic-key';Nested=@{api_key='synthetic-key'}}} @(@{type='Present';path='ApiKey'}) 'PASS' @{method='GET';responseMode='raw'} $keyAuth
if((Get-Content (Join-Path $OutputDirectory 'api-key-redaction/results/case.json') -Raw) -match 'synthetic-key'){throw 'API key property redaction failed'};$checks++
$saved=Get-Content (Join-Path $OutputDirectory 'redaction/results/case.json') -Raw
if($saved -match 'synthetic-secret|synthetic-password'){throw 'Redaction failed'};$checks++
$markdown=Get-Content (Join-Path $OutputDirectory 'positive/results/report.md')
if($markdown[0] -ne '# HARNESS API results' -or $markdown -notcontains '| Case | Result | Evidence |'){throw 'Report layout failed'};$checks++
foreach($name in @('Invoke-PeerTest.ps1','Invoke-LocalFixture.ps1')) {
  $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw "Syntax errors in $name"};$checks++
}
@{validation='PASS';checks=$checks;requests=0;output=$OutputDirectory} | ConvertTo-Json -Compress
