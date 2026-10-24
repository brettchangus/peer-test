[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$PlanPath,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [PSCredential]$Credential,
  [Security.SecureString]$ApiKey,
  [string]$ReplayDirectory
)
$ErrorActionPreference='Stop'
$clock=[Diagnostics.Stopwatch]::StartNew()
$plan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if($plan.replayOnly -and !$ReplayDirectory) { throw 'This historical plan is replay-only.' }
if ($null -eq $plan.cases -or @($plan.cases).Count -eq 0) { throw 'Plan must contain cases.' }
$base=[Uri]$plan.baseUrl
if (!$ReplayDirectory -and ($base.Scheme -ne 'https' -or !$base.IsLoopback -or $base.UserInfo -or $base.Query -or $base.Fragment)) { throw 'Live testing requires a loopback HTTPS base URL without credentials, query or fragment.' }
$auth=if($plan.auth){[string]$plan.auth}else{'credential'}
if($auth -notin @('credential','apiKey')) { throw 'Unsupported authentication mode.' }
if($plan.PSObject.Properties.Name -match '(?i)^(Password|Credential|ApiKey|Authorization|Token|Secret)$'){throw 'Pass credentials and keys in memory, not in plan fields.'}
$seen=@{}
foreach($case in $plan.cases) {
  if($case.id -notmatch '^[a-zA-Z0-9_-]+$' -or $seen.ContainsKey($case.id)) { throw 'Case IDs must be unique safe filenames.' }
  if($case.id -ieq 'results') { throw 'Case ID results is reserved for the summary filename.' }
  $seen[$case.id]=$true
  $method=if($case.method){[string]$case.method}else{'POST'}
  $mode=if($case.responseMode){[string]$case.responseMode}else{'resultCode'}
  if($method -notin @('GET','POST') -or ($method -eq 'GET' -and $auth -ne 'apiKey')) { throw 'GET requires apiKey authentication; only GET and POST are supported.' }
  if($mode -notin @('raw','resultCode')) { throw 'Unsupported response mode.' }
  if($case.expectedStatus -and ([int]$case.expectedStatus -lt 100 -or [int]$case.expectedStatus -gt 599)) { throw 'Expected HTTP status must be 100-599.' }
  if($method -eq 'GET' -and @($case.payload.PSObject.Properties).Count) { throw 'GET payloads are unsupported; declare the relative endpoint.' }
  if($null -eq $case.assertions -or @($case.assertions).Count -eq 0) { throw 'Each case must declare assertions.' }
  if($case.endpoint -notmatch '^/api/[a-zA-Z0-9/_-]+$') { throw 'Endpoint must be a relative API path.' }
  if($case.payload.PSObject.Properties.Name -match '(?i)^(Password|Email|ApiKey|Authorization|Token|Secret)$') { throw 'Pass credentials or keys in memory, not in the payload.' }
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
if(!$ReplayDirectory -and $auth -eq 'credential' -and !$Credential) { $Credential=Get-Credential -Message 'Local application test account (not saved)' }
if(!$ReplayDirectory -and $auth -eq 'apiKey' -and !$ApiKey) { throw 'Pass ApiKey as an in-memory SecureString; never store it in the plan.' }
$knownSecrets=@()
if($Credential){$knownSecrets+= $Credential.GetNetworkCredential().Password}
if($ApiKey){$knownSecrets+= ([PSCredential]::new('api',$ApiKey)).GetNetworkCredential().Password}
# Capture HTTP errors as testable responses; never follow redirects with credentials.
$client=$null
if(!$ReplayDirectory){
  Add-Type -AssemblyName System.Net.Http
  $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
  $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(30)
}
function Get-Value($Object,[string]$Path) {
  if([string]::IsNullOrEmpty($Path)){return @{Found=$true;Value=$Object}}
  $current=$Object
  foreach($segment in $Path.Split('.')) {
    if($null -eq $current -or !$current.PSObject.Properties[$segment]) { return @{Found=$false;Value=$null} }
    $current=$current.PSObject.Properties[$segment].Value
  }
  return @{Found=$true;Value=$current}
}
function Redact($Value) {
  if($null -eq $Value) { return $null }
  if($Value -is [string]) { foreach($secret in $knownSecrets){if($secret){$Value=$Value.Replace($secret,'[REDACTED]')}};return $Value }
  if($Value -is [ValueType]) { return $Value }
  if($Value -is [System.Collections.IDictionary]) {
    $clean=[ordered]@{}
    foreach($key in $Value.Keys){$clean[$key]=if([string]$key -match '(?i)password|token|secret|authorization|cookie|apikey|api_key'){'[REDACTED]'}else{Redact $Value[$key]}}
    return $clean
  }
  if($Value -is [System.Collections.IList]) { return ,@($Value | ForEach-Object { Redact $_ }) }
  $clean=[ordered]@{}
  foreach($p in $Value.PSObject.Properties) {
    $clean[$p.Name]=if($p.Name -match '(?i)password|token|secret|authorization|cookie|apikey|api_key') {'[REDACTED]'} else { Redact $p.Value }
  }
  return $clean
}
function Assert-Response($Response,$Assertion) {
  $target=Get-Value $Response $Assertion.path
  if(!$target.Found) { return 'Missing path: '+$Assertion.path }
  $items=@($target.Value)
  if($Assertion.type -in @('Count','MinCount')) {
    $count=if($null -eq $target.Value){0}else{$items.Count}
    if(($Assertion.type -eq 'Count' -and $count -ne $Assertion.expected) -or ($Assertion.type -eq 'MinCount' -and $count -lt $Assertion.expected)) { return 'Count assertion failed at '+$Assertion.path }
    return $null
  }
  if($Assertion.whereProperty) { $items=@($items | Where-Object { $v=Get-Value $_ $Assertion.whereProperty; $v.Found -and $v.Value -ceq $Assertion.whereEquals }) }
  if($items.Count -eq 0) { return 'No records matched at '+$Assertion.path }
  foreach($item in $items) {
    $value=if($Assertion.property){Get-Value $item $Assertion.property}else{@{Found=$true;Value=$item}}
    switch($Assertion.type) {
      'Present' { if(!$value.Found){return 'Missing property: '+$Assertion.property} }
      'Equals' {
        if(!$value.Found -or
           $value.Value -is [System.Collections.IList] -or
           $Assertion.expected -is [System.Collections.IList] -or
           $value.Value -cne $Assertion.expected){return 'Unexpected value at '+$Assertion.path+'.'+$Assertion.property}
      }
      'IsNull' { if(!$value.Found -or $null -ne $value.Value){return 'Expected explicit null at '+$Assertion.path+'.'+$Assertion.property} }
      'EqualField' {
        $other=Get-Value $item $Assertion.otherProperty
        if(!$value.Found -or !$other.Found -or
           $value.Value -is [System.Collections.IList] -or
           $other.Value -is [System.Collections.IList] -or
           $value.Value -cne $other.Value){return 'Field comparison failed: '+$Assertion.property+' / '+$Assertion.otherProperty}
      }
      'Matches' { if(!$value.Found -or !$Assertion.pattern -or [string]$value.Value -notmatch $Assertion.pattern){return 'Pattern assertion failed at '+$Assertion.path} }
      'AbsentPattern' { if(!$Assertion.pattern){return 'Missing property pattern'}; if(@($item.PSObject.Properties.Name | Where-Object {$_ -match $Assertion.pattern}).Count){return 'Unexpected property matching '+$Assertion.pattern} }
      default { return 'Unknown assertion type: '+$Assertion.type }
    }
  }
  return $null
}
$results=@(); $requestCount=0; $assertionCount=0
foreach($case in $plan.cases) {
  $timer=[Diagnostics.Stopwatch]::StartNew(); $failures=@(); $status='PASS'; $evidence=$case.id+'.json'
  try {
    if($ReplayDirectory) {
      if(!$case.replayFile -or [IO.Path]::GetFileName($case.replayFile) -ne $case.replayFile) { throw 'Replay filename must be a plain filename.' }
      $response=Get-Content -LiteralPath (Join-Path $ReplayDirectory $case.replayFile) -Raw | ConvertFrom-Json -NoEnumerate
    } else {
      $body=@{};$request=$null;$httpResponse=$null
      try {
        $method=if($case.method){[string]$case.method}else{'POST'}
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method),($base.GetLeftPart([UriPartial]::Authority)+$case.endpoint))
        if($auth -eq 'credential'){$body.Email=$Credential.UserName;$body.Password=$Credential.GetNetworkCredential().Password}
        else {[void]$request.Headers.TryAddWithoutValidation('Authorization',([PSCredential]::new('api',$ApiKey)).GetNetworkCredential().Password)}
        foreach($p in $case.payload.PSObject.Properties){$body[$p.Name]=$p.Value}
        if($method -eq 'POST'){$request.Content=[Net.Http.StringContent]::new(($body|ConvertTo-Json -Depth 12 -Compress),[Text.Encoding]::UTF8,'application/json')}
        $requestCount++;$httpResponse=$client.SendAsync($request).GetAwaiter().GetResult()
        $statusCode=[int]$httpResponse.StatusCode
        $content=$httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try{$response=ConvertFrom-Json -InputObject $content -NoEnumerate -ErrorAction Stop}catch{$response=$content}
      } finally {$body.Clear();if($httpResponse){$httpResponse.Dispose()};if($request){$request.Dispose()}}
    }
    $mode=if($case.responseMode){[string]$case.responseMode}else{'resultCode'}
    if($ReplayDirectory){
      if($mode -eq 'raw' -or ($response.evidenceVersion -eq 1 -and $response.PSObject.Properties['body'])){$statusCode=$response.statusCode;$response=$response.body}
      else {$statusCode=200} # Legacy replay files contain body only.
    }
    $expectedStatus=if($case.expectedStatus){[int]$case.expectedStatus}else{200}
    $assertionCount++
    if($statusCode -ne $expectedStatus){$failures+='Unexpected HTTP status: '+$statusCode+'; expected '+$expectedStatus}
    $savedResponse=@{evidenceVersion=1;statusCode=$statusCode;body=$response}
    Redact $savedResponse | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath (Join-Path $OutputDirectory $evidence) -Encoding UTF8
    if($mode -eq 'resultCode'){
      $assertionCount++
      $code=Get-Value $response 'ResultCode'
      $expectedCode=if($case.PSObject.Properties['expectedResultCode']){$case.expectedResultCode}else{0}
      if(!$code.Found -or $code.Value -ne $expectedCode){$failures+='API ResultCode was missing or unexpected.'}
    }
    foreach($assertion in $case.assertions) { $assertionCount++; $failure=Assert-Response $response $assertion; if($failure){$failures+=$failure} }
    if($failures.Count){$status='FAIL'}
  } catch { $status='BLOCKED'; $failures+='Request/evidence error ('+$_.Exception.GetType().Name+'); inspect locally. No response assertions completed for this case.' }
  $results+=@{id=$case.id;status=$status;failures=$failures;evidence=$evidence;elapsedMs=$timer.ElapsedMilliseconds}
}
if($client){$client.Dispose()}
$knownSecrets=@()
$summary=[ordered]@{ticket=$plan.ticket;mode=$(if($ReplayDirectory){'replay'}else{'live'});state=$plan.state;startedUtc=[DateTime]::UtcNow.Subtract($clock.Elapsed).ToString('o');elapsedMs=$clock.ElapsedMilliseconds;requests=$requestCount;assertions=$assertionCount;passed=@($results | Where-Object status -eq PASS).Count;failed=@($results | Where-Object status -eq FAIL).Count;blocked=@($results | Where-Object status -eq BLOCKED).Count;cases=$results}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding UTF8
$lines=@("# $($plan.ticket) API results",'',"Mode: $($summary.mode)","State: $($plan.state)",'','| Case | Result | Evidence |','|---|---|---|')
foreach($result in $results) { $lines+='| '+$result.id+' | '+$result.status+' | ['+$result.evidence+']('+$result.evidence+') |'; foreach($failure in $result.failures){$lines+='';$lines+='- '+$result.id+': '+$failure} }
$lines+=@('',"Requests: $requestCount; assertions: $assertionCount; elapsed milliseconds: $($summary.elapsedMs).",'','This report covers declared API assertions only. Add browser evidence, code revision, fixture restoration and untested scope to the ticket report.')
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'report.md') -Encoding UTF8
@{ticket=$summary.ticket;mode=$summary.mode;passed=$summary.passed;failed=$summary.failed;blocked=$summary.blocked;requests=$requestCount;assertions=$assertionCount;elapsedMs=$summary.elapsedMs;report=(Join-Path $OutputDirectory 'report.md')} | ConvertTo-Json -Compress
if($summary.failed -or $summary.blocked){exit 1}
