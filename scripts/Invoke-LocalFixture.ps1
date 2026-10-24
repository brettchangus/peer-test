[CmdletBinding(DefaultParameterSetName='Run')]
param(
  [Parameter(Mandatory)][string]$SettingsPath,
  [string]$WebConfigPath,
  [Parameter(Mandatory,ParameterSetName='Validate')][switch]$ValidateOnly,
  [Parameter(Mandatory,ParameterSetName='Validate')]
  [Parameter(Mandatory,ParameterSetName='Run')][string]$ChangesPath,
  [Parameter(Mandatory,ParameterSetName='Run')][string]$BackupPath,
  [Parameter(Mandatory,ParameterSetName='Run')][scriptblock]$Test,
  [Parameter(Mandatory,ParameterSetName='Restore')][string]$RestoreBackupPath
)
$ErrorActionPreference='Stop'
$settings=Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
if($settings.schemaVersion -ne 1 -or $settings.configured -isnot [bool] -or !$settings.configured){throw 'Configure settings.local.json before using fixtures.'}
$fixtureConfig=$settings.fixture
if(!$fixtureConfig){throw 'Configure the fixture section in settings.local.json before using fixtures.'}
function Assert-Identifier($Value) {
  if($Value -isnot [string] -or $Value -notmatch '^[A-Za-z_][A-Za-z0-9_]*$'){throw 'Invalid configured SQL identifier.'}
}
if($fixtureConfig.schemaVersion -ne 1 -or !$fixtureConfig.connectionName -or !$fixtureConfig.expectedServer -or !$fixtureConfig.expectedDatabase){throw 'Fixture configuration requires version, connection name and expected database destination.'}
if($fixtureConfig.expectedServer -notmatch '^(\(LocalDB\)\\[A-Za-z0-9_]+|(?:localhost|\.|\(local\))(?:\\[A-Za-z0-9_]+)?)$'){throw 'Fixtures require an explicitly configured local SQL server.'}
if(!$WebConfigPath){$WebConfigPath=$fixtureConfig.webConfigPath}
if(!$WebConfigPath){throw 'Supply WebConfigPath or configure webConfigPath.'}
$tableMappings=@{}
foreach($mapping in $fixtureConfig.tables) {
  foreach($identifier in @($mapping.name,$mapping.idColumn,$mapping.scopeColumn)){Assert-Identifier $identifier}
  if(@($mapping.columns).Count -eq 0){throw 'Each fixture table needs an explicit column allowlist.'}
  foreach($column in $mapping.columns){Assert-Identifier $column}
  if($tableMappings.ContainsKey($mapping.name)){throw 'Duplicate configured fixture table.'}
  $tableMappings[$mapping.name]=$mapping
}
if($tableMappings.Count -eq 0){throw 'Fixture configuration must allow at least one table.'}
function Get-ScopeId($Cell) {
  $value=$Cell.scopeId
  if($null -eq $value -and $fixtureConfig.legacyScopeProperty){$value=$Cell.($fixtureConfig.legacyScopeProperty)}
  if($null -eq $value -or [string]$value -notmatch '^[1-9][0-9]*$' -or [long]$value -gt [int]::MaxValue){throw 'Explicit positive scope ID required.'}
  return [int]$value
}
[xml]$config=Get-Content -LiteralPath $WebConfigPath
$connections=@($config.configuration.connectionStrings.add | Where-Object name -eq $fixtureConfig.connectionName)
if($connections.Count -ne 1){throw 'Expected exactly one configured connection entry.'}
$connection=New-Object System.Data.SqlClient.SqlConnection($connections[0].connectionString)
$builder=New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connection.ConnectionString)
if($builder.DataSource -ne $fixtureConfig.expectedServer -or $builder.InitialCatalog -ne $fixtureConfig.expectedDatabase -or !$builder.IntegratedSecurity){throw 'Fixtures require the configured local test database with integrated authentication.'}
function Validate-Cell($Cell) {
  $scopeId=Get-ScopeId $Cell
  if($null -eq $Cell.id -or [string]$Cell.id -notmatch '^[1-9][0-9]*$' -or [long]$Cell.id -gt [int]::MaxValue){throw 'Explicit positive record ID required.'}
  if(!$Cell.table -or !$tableMappings.ContainsKey([string]$Cell.table)){throw 'Unsupported fixture table.'}
  $mapping=$tableMappings[$Cell.table]
  if($Cell.column -notin $mapping.columns){throw 'Unsupported fixture column.'}
  if($mapping.scopeIsId -and $Cell.id -ne $scopeId){throw 'Scope record ID must equal the scope ID.'}
  return $mapping
}
function Read-Cell($Cell,$Transaction) {
  $mapping=Validate-Cell $Cell
  $idColumn=$mapping.idColumn;$scopeColumn=$mapping.scopeColumn
  $command=$connection.CreateCommand(); if($Transaction){$command.Transaction=$Transaction}
  $command.CommandText="SELECT CONVERT(nvarchar(max),[$($Cell.column)]) FROM dbo.[$($Cell.table)] WHERE [$scopeColumn]=@scope AND [$idColumn]=@id"
  [void]$command.Parameters.AddWithValue('@scope',(Get-ScopeId $Cell)); [void]$command.Parameters.AddWithValue('@id',[int]$Cell.id)
  try { $reader=$command.ExecuteReader(); try { if(!$reader.Read()){throw 'Fixture record not found.'}; $value=if($reader.IsDBNull(0)){$null}else{$reader.GetString(0)}; if($reader.Read()){throw 'Fixture record is not unique.'}; return @{value=$value} } finally{$reader.Dispose()} } finally{$command.Dispose()}
}
function Write-Cell($Cell,$Value,$Expected,$Transaction) {
  $mapping=Validate-Cell $Cell
  $idColumn=$mapping.idColumn;$scopeColumn=$mapping.scopeColumn
  $command=$connection.CreateCommand(); $command.Transaction=$Transaction
  $command.CommandText="DECLARE @changed TABLE (Id int); UPDATE dbo.[$($Cell.table)] SET [$($Cell.column)]=@value OUTPUT inserted.[$idColumn] INTO @changed WHERE [$scopeColumn]=@scope AND [$idColumn]=@id AND ((CONVERT(nvarchar(max),[$($Cell.column)]) COLLATE Latin1_General_100_BIN2 = @expected COLLATE Latin1_General_100_BIN2 AND DATALENGTH(CONVERT(nvarchar(max),[$($Cell.column)]))=DATALENGTH(@expected)) OR ([$($Cell.column)] IS NULL AND @expected IS NULL)); SELECT COUNT(*) FROM @changed;"
  [void]$command.Parameters.AddWithValue('@scope',(Get-ScopeId $Cell)); [void]$command.Parameters.AddWithValue('@id',[int]$Cell.id)
  foreach($entry in @{value=$Value;expected=$Expected}.GetEnumerator()) { $parameter=$command.Parameters.Add('@'+$entry.Key,[Data.SqlDbType]::NVarChar,-1); $parameter.Value=if($null -eq $entry.Value){[DBNull]::Value}else{[string]$entry.Value} }
  try { if($command.ExecuteScalar() -ne 1){throw 'Fixture value changed concurrently; refusing to overwrite.'} } finally{$command.Dispose()}
}
function Restore-Cells($Cells) {
  $transaction=$connection.BeginTransaction()
  try {
    foreach($cell in $Cells) {
      $current=(Read-Cell $cell $transaction).value
      if($current -ceq $cell.original) { continue }
      if($current -cne $cell.applied) { throw 'Fixture restoration conflict; recovery backup retained. Review current data before restoring.' }
      Write-Cell $cell $cell.original $cell.applied $transaction
    }
    foreach($cell in $Cells) { if((Read-Cell $cell $transaction).value -cne $cell.original){throw 'Restoration verification failed.'} }
    $transaction.Commit()
    'Fixture restored and all original values verified.'
  } catch { $transaction.Rollback(); throw } finally{$transaction.Dispose()}
}
function Invoke-TestAndRestore([scriptblock]$TestBlock,[scriptblock]$RestoreBlock) {
  $testFailure=$null;$restoreFailure=$null
  try {
    # Clear a stale status from earlier commands; external programs do not necessarily throw on failure.
    $global:LASTEXITCODE=0
    & $TestBlock
    $testSucceeded=$?;$testExitCode=$global:LASTEXITCODE
    if(!$testSucceeded -or $testExitCode -ne 0){throw "Fixture test failed (exit code $testExitCode)."}
  } catch {$testFailure=$_.Exception}
  finally {
    try {& $RestoreBlock} catch {$restoreFailure=$_.Exception}
  }
  if($testFailure -and $restoreFailure){throw [AggregateException]::new('Fixture test and restoration both failed.',[Exception[]]@($testFailure,$restoreFailure))}
  if($restoreFailure){throw $restoreFailure}
  if($testFailure){throw $testFailure}
}
try {
  if($ValidateOnly) {
    $changes=Get-Content -LiteralPath $ChangesPath -Raw | ConvertFrom-Json
    if(@($changes.cells).Count -eq 0){throw 'Fixture must declare cells.'}
    foreach($change in $changes.cells){[void](Validate-Cell $change)}
    'Fixture configuration and cell mappings validated without opening a database connection.'
    return
  }
  $connection.Open()
  if($RestoreBackupPath) {
    $backup=Get-Content -LiteralPath $RestoreBackupPath -Raw | ConvertFrom-Json
    if($backup.server -ne $connection.DataSource -or $backup.database -ne $connection.Database){throw 'Recovery destination mismatch.'}
    Restore-Cells $backup.cells
  } else {
    if(Test-Path -LiteralPath $BackupPath){throw 'Use a new backup path; existing backups are never overwritten.'}
    $changes=Get-Content -LiteralPath $ChangesPath -Raw | ConvertFrom-Json
    if(@($changes.cells).Count -eq 0){throw 'Fixture must declare cells.'}
    $cells=@();$seen=@{}
    foreach($change in $changes.cells) {
      [void](Validate-Cell $change)
      $key="$($change.table)/$(Get-ScopeId $change)/$($change.id)/$($change.column)"
      if($seen.ContainsKey($key)){throw 'Duplicate fixture cell.'};$seen[$key]=$true
      $original=(Read-Cell $change $null).value
      if(!$change.PSObject.Properties['expected'] -or $original -cne $change.expected){throw 'Fixture baseline differs from declared expected value.'}
      if(!$change.PSObject.Properties['value']){throw 'Fixture must declare value (explicit null is allowed).'}
      if($null -ne $change.value -and $change.value -isnot [string]){throw 'Fixture values must be strings or null.'}
      $cells+=@{table=$change.table;scopeId=(Get-ScopeId $change);id=$change.id;column=$change.column;original=$original;applied=$change.value}
    }
    $backup=@{server=$connection.DataSource;database=$connection.Database;createdUtc=[DateTime]::UtcNow.ToString('o');cells=$cells}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($BackupPath)))
    $backup | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    $applied=$false;$restoreAttempted=$false
    try {
      $transaction=$connection.BeginTransaction()
      try {
        foreach($cell in $cells){Write-Cell $cell $cell.applied $cell.original $transaction}
        # SQL XML serialization can normalize a supplied XML string. Capture the actual stored values for guarded recovery.
        foreach($cell in $cells){$cell.applied=(Read-Cell $cell $transaction).value}
        $backup | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
        $transaction.Commit();$applied=$true
      } catch{$transaction.Rollback();throw} finally{$transaction.Dispose()}
      $restoreAttempted=$true
      Invoke-TestAndRestore -TestBlock $Test -RestoreBlock {Restore-Cells $cells}
    } finally { if($applied -and !$restoreAttempted){Restore-Cells $cells} }
  }
} finally{$connection.Dispose()}
