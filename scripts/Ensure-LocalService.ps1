[CmdletBinding()]
param(
  [Parameter(Mandatory)][Uri]$Url,
  [Parameter(Mandatory)][string]$ApplicationHostConfig,
  [Parameter(Mandatory)][string]$ExpectedPhysicalPath,
  [string]$IisExpressPath='C:\Program Files\IIS Express\iisexpress.exe',
  [ValidateRange(5,120)][int]$WaitSeconds=30,
  [switch]$CheckOnly,
  [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
if($Url.Scheme -ne 'https' -or !$Url.IsLoopback -or $Url.UserInfo -or $Url.Query -or $Url.Fragment){throw 'Service checks require loopback HTTPS without credentials, query or fragment.'}
foreach($file in @($ApplicationHostConfig,$IisExpressPath)){if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw 'Required host configuration or IIS Express executable is missing.'}}
$hostConfigPath=[IO.Path]::GetFullPath($ApplicationHostConfig)
$expected=[IO.Path]::GetFullPath($ExpectedPhysicalPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
if(!(Test-Path -LiteralPath $expected -PathType Container)){throw 'Expected application directory is missing.'}
[xml]$config=Get-Content -LiteralPath $hostConfigPath -Raw
$matchingSites=@()
foreach($site in $config.configuration.'system.applicationHost'.sites.site){
  $bindingMatches=@($site.bindings.binding | Where-Object {
    $binding=[regex]::Match([string]$_.bindingInformation,'^(.*):(\d+):(.*)$')
    $_.protocol -eq 'https' -and $binding.Success -and [int]$binding.Groups[2].Value -eq $Url.Port -and ($binding.Groups[3].Value -eq '' -or $binding.Groups[3].Value -ieq $Url.DnsSafeHost)
  })
  if(!$bindingMatches.Count){continue}
  $roots=@($site.application | Where-Object path -eq '/' | ForEach-Object {$_.virtualDirectory | Where-Object path -eq '/'})
  if($roots.Count -ne 1){throw 'Matching site needs one root application directory.'}
  $physical=[Environment]::ExpandEnvironmentVariables([string]$roots[0].physicalPath)
  $physical=[IO.Path]::GetFullPath($physical).TrimEnd([IO.Path]::DirectorySeparatorChar)
  if(![string]::Equals($physical,$expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Configured service physical path does not match the expected application.'}
  $matchingSites+= $site
}
if($matchingSites.Count -ne 1){throw 'Expected exactly one IIS Express site matching the requested HTTPS host/port.'}
$siteName=[string]$matchingSites[0].name
if($hostConfigPath.Contains('"') -or $siteName.Contains('"')){throw 'Quotes are unsupported in host configuration path/site name.'}
if($ValidateOnly){@{state='ValidConfiguration';site=$siteName;origin=$Url.GetLeftPart([UriPartial]::Authority);started=$false}|ConvertTo-Json -Compress;return}
function Test-Listening {
  $tcp=[Net.Sockets.TcpClient]::new()
  try{$task=$tcp.ConnectAsync($Url.DnsSafeHost,$Url.Port);return $task.Wait(1000) -and $tcp.Connected}catch{return $false}finally{$tcp.Dispose()}
}
Add-Type -AssemblyName System.Net.Http
$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(3)
function Get-HttpStatus {
  $response=$null
  try{$response=$client.GetAsync($Url).GetAwaiter().GetResult();return [int]$response.StatusCode}finally{if($response){$response.Dispose()}}
}
$started=$false;$process=$null;$lastFailure='No HTTP response'
try{
  if(Test-Listening){
    try{$status=Get-HttpStatus}catch{throw 'Port already listens but HTTPS probe failed; inspect TLS/service configuration. Refusing duplicate startup.'}
    if($status -ge 200 -and $status -lt 500){
      @{state='AlreadyRunning';site=$siteName;origin=$Url.GetLeftPart([UriPartial]::Authority);httpStatus=$status;started=$false}|ConvertTo-Json -Compress;return
    }
    throw "Service responds HTTP $status; diagnose the application/dependency or probe route. Refusing duplicate startup."
  }
  if($CheckOnly){@{state='Stopped';site=$siteName;origin=$Url.GetLeftPart([UriPartial]::Authority);started=$false}|ConvertTo-Json -Compress;return}
  $arguments=@(('/config:"'+$hostConfigPath+'"'),('/site:"'+$siteName+'"'),'/systray:false')
  $process=Start-Process -FilePath $IisExpressPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $started=$true;$timer=[Diagnostics.Stopwatch]::StartNew()
  while($timer.Elapsed.TotalSeconds -lt $WaitSeconds){
    if($process.HasExited){throw 'Started IIS Express process exited before readiness; inspect the configured site.'}
    try{
      $status=Get-HttpStatus
      if($status -ge 200 -and $status -lt 500){
        @{state='Started';site=$siteName;origin=$Url.GetLeftPart([UriPartial]::Authority);httpStatus=$status;started=$true;processId=$process.Id}|ConvertTo-Json -Compress;return
      }
      $lastFailure='HTTP '+$status
    }catch{$lastFailure='HTTPS probe failed ('+$_.Exception.GetType().Name+')'}
    Start-Sleep -Milliseconds 500
  }
  throw "Started process $($process.Id) did not become ready within $WaitSeconds seconds: $lastFailure. It was left running; record its ID and diagnose before retrying."
}finally{$client.Dispose();if($process){$process.Dispose()}}
