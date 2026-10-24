param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
$fixture=Join-Path $PSScriptRoot 'Invoke-LocalFixture.ps1'
$executable=(Get-Process -Id $PID).Path
$webConfigPath=Join-Path $OutputDirectory 'Web.config'
'<configuration><connectionStrings><add name="ApplicationDatabase" connectionString="Data Source=(LocalDB)\TestInstance;Initial Catalog=Application.Test;Integrated Security=True" /></connectionStrings></configuration>' | Set-Content -LiteralPath $webConfigPath
$checks=0
function Exercise($Name,[scriptblock]$Modify,[bool]$ShouldPass=$false) {
  $config=@{schemaVersion=1;webConfigPath=$webConfigPath;connectionName='ApplicationDatabase';expectedServer='(LocalDB)\TestInstance';expectedDatabase='Application.Test';tables=@(@{name='Records';idColumn='RecordId';scopeColumn='ScopeId';scopeIsId=$false;columns=@('Status')})}
  $cell=@{table='Records';scopeId=1;id=7;column='Status';expected='Pending';value='Active'}
  & $Modify $config $cell
  $configPath=Join-Path $OutputDirectory ($Name+'-config.json')
  $changesPath=Join-Path $OutputDirectory ($Name+'-changes.json')
  @{schemaVersion=1;configured=$true;fixture=$config} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
  @{cells=@($cell)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $changesPath
  $output=& $executable -NoProfile -File $fixture -SettingsPath $configPath -ValidateOnly -ChangesPath $changesPath 2>&1
  $exitCode=$LASTEXITCODE
  $output | Out-String | Set-Content -LiteralPath (Join-Path $OutputDirectory ($Name+'-output.txt'))
  if(($exitCode -eq 0) -ne $ShouldPass){throw "Unexpected fixture validation result: $Name"}
  if($ShouldPass -and ($output -join ' ') -notmatch 'without opening a database connection'){throw 'Validation mode did not finish as expected.'}
  $script:checks++
}
Exercise 'valid' {} $true
Exercise 'legacy-scope' {param($config,$cell) $config.legacyScopeProperty='legacyScopeId';$cell.legacyScopeId=$cell.scopeId;$cell.Remove('scopeId')} $true
Exercise 'scope-record' {param($config,$cell) $config.tables[0].scopeIsId=$true;$cell.id=$cell.scopeId} $true
Exercise 'invalid-version' {param($config,$cell) $config.schemaVersion=2}
Exercise 'remote-server' {param($config,$cell) $config.expectedServer='production.example.com'}
Exercise 'wrong-database' {param($config,$cell) $config.expectedDatabase='Other.Test'}
Exercise 'wrong-connection' {param($config,$cell) $config.connectionName='OtherDatabase'}
Exercise 'unsafe-identifier' {param($config,$cell) $config.tables[0].scopeColumn='ScopeId];DROP TABLE Records;--'}
Exercise 'duplicate-table' {param($config,$cell) $config.tables+=@($config.tables[0])}
Exercise 'empty-allowlist' {param($config,$cell) $config.tables[0].columns=@()}
Exercise 'missing-scope' {param($config,$cell) $cell.Remove('scopeId')}
Exercise 'negative-scope' {param($config,$cell) $cell.scopeId=-1}
Exercise 'invalid-record-id' {param($config,$cell) $cell.id='7;DROP TABLE Records'}
Exercise 'unsupported-table' {param($config,$cell) $cell.table='OtherRecords'}
Exercise 'unsupported-column' {param($config,$cell) $cell.column='UnlistedField'}
Exercise 'scope-record-mismatch' {param($config,$cell) $config.tables[0].scopeIsId=$true}
@{validation='PASS';checks=$checks;requests=0;output=$OutputDirectory} | ConvertTo-Json -Compress
