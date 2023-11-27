# version 2023-11-21
# process commandline arguments
[CmdletBinding()]
param (
    [Parameter(Mandatory)][string]$username = '', 
    [Parameter(Mandatory)][string]$region = '',
    [Parameter(Mandatory=$True)][string]$sourceServer,
    [Parameter()][string]$mfaCode = $null,
    [Parameter()][array]$sourceDB,
    [Parameter()][string]$sourceDBList,
    [Parameter()][switch]$allDBs,
    [Parameter()][switch]$includeSystemDBs,
    [Parameter()][string]$sourceInstance,
    [Parameter()][array]$sourceNodes,
    [Parameter()][string]$targetServer = $sourceServer,
    [Parameter()][string]$targetInstance,
    [Parameter()][string]$targetDB,
    [Parameter()][string]$prefix,
    [Parameter()][string]$suffix,
    [Parameter()][string]$mdfFolder,
    [Parameter()][string]$ldfFolder = $mdfFolder,
    [Parameter()][hashtable]$ndfFolders,
    [Parameter()][switch]$noRecovery,
    [Parameter()][switch]$noStop,
    [Parameter()][datetime]$logTime,
    [Parameter()][int64]$newerThan,
    [Parameter()][switch]$overwrite,
    [Parameter()][switch]$keepCdc,
    [Parameter()][switch]$captureTailLogs,
    [Parameter()][switch]$wait,
    [Parameter()][switch]$progress,
    [Parameter()][int64]$pageSize = 5,
    [Parameter()][int64]$dbsPerRecovery = 5,
    [Parameter()][int64]$sleepTime = 30,
    [Parameter()][switch]$exportPaths,
    [Parameter()][switch]$importPaths,
    [Parameter()][switch]$showPaths,
    [Parameter()][switch]$commit,
    [Parameter()][switch]$dbg
)

# Prechecks start
if($sleepTime -lt 30){
    $sleepTime = 30
}

if(! $commit -and ! $exportPaths -and ! $showPaths){
    Write-Host "Running in test mode. Please use the -commit switch to perform the recoveries" -ForegroundColor Yellow
}

# Check for Source DB input conflicts
$conflictingSelections = $False
if($allDBs){
    if($sourceDBList -ne '' -or $sourceDB.Count -gt 0){
        $conflictingSelections = $True
    }
}
if($sourceDBList -ne ''){
    if($sourceDB.Count -gt 0){
        $conflictingSelections = $True
    }
}
if($conflictingSelections -eq $True){
    Write-Host "Conflicting DB selections. Please use only one of -allDBs, -sourceDBList, -sourceDB" -ForegroundColor Yellow
    exit 1
}

# gather list from command line params and file
function gatherList($Param=$null, $FilePath=$null, $Required=$True, $Name='items'){
    $items = @()
    if($Param){
        $Param | ForEach-Object {$items += $_}
    }
    if($FilePath){
        if(Test-Path -Path $FilePath -PathType Leaf){
            Get-Content $FilePath | ForEach-Object {$items += [string]$_}
        }else{
            Write-Host "Text file $FilePath not found!" -ForegroundColor Yellow
            exit
        }
    }
    if($Required -eq $True -and $items.Count -eq 0){
        Write-Host "No $Name specified" -ForegroundColor Yellow
        exit
    }
    return ($items | Sort-Object -Unique)
}

$sourceDbNames = @(gatherList -Param $sourceDB -FilePath $sourceDBList -Name 'DBs' -Required $False)

# source the cohesity-api helper code
. $(Join-Path -Path $PSScriptRoot -ChildPath cohesity-api.ps1)

# authentication =============================================
# demand username for DMaaS
if(! $username){
    Write-Host "-username is required when connecting to CCS" -ForegroundColor Yellow
    exit 1
}
# demand region for DMaaS
if(! $region){
    Write-Host "-region is required when connecting to CCS" -ForegroundColor Yellow
    exit 1
}
# authenticate
apiauth -username $username -region $region
Write-Host "Connecting to CCS $region as $username"
# end authentication =========================================

# import file paths
$exportFilePath = Join-Path -Path $PSScriptRoot -ChildPath "$sourceServer.json"
$importedFileInfo = $null
if($importPaths){
    if(!(Test-Path -Path $exportFilePath)){
        Write-Host "Import file $exportFilePath not found" -ForegroundColor Yellow
        exit 1
    }
    $importedFileInfo = Get-Content -Path $exportFilePath | ConvertFrom-JSON
}

if($newerThan){
    $newerThanUsecs = timeAgo $newerThan days
}

#Initialise and Populate the DB List
Write-host "Finding registered sources filtered by SQL servers only"
$searchAll = api get "protectionSources/applicationServers?application=kSQL&environment=kSQL"
$DBInfo = @()
$DBObject = @()
$DBObjectFound = @()
$dbFiles = @()
$appServer = @()
$instance = @()
foreach ($appServer in $searchAll.applicationServer) {
    foreach ($node in $appServer.applicationNodes.nodes) {
        $serverName = $appServer.protectionSource.name
        $serverId = $appServer.protectionSource.id
		$dbId = $node.protectionSource.id
        $parentId = $node.protectionSource.parentId
        $dbLongName = $node.protectionSource.name
        $dbShortName = $node.protectionSource.sqlProtectionSource.databaseName
        $instanceName = $node.protectionSource.sqlProtectionSource.name
        #$dbRole = $node.protectionSource.sqlProtectionSource.dbFileGroups[0]
		$dbFiles = $node.protectionSource.sqlProtectionSource.dbFiles
        $DBInfo = @($DBInfo + @{
            'serverName' = $serverName
			'serverId' = $serverId
            'dbId' = $dbId
            'dbLongName' = $dbLongName
            'dbShortName' = $dbShortName
            'instanceName' = $instanceName
			'dbFiles' = $dbFiles
            })
    }
	$DBObject = @($DBObject + @{
		'DBInfo' = $DBInfo
	})
}
#$DBInfo
#$DBObject.DBInfo.dbId # = $dbAllInfo | ConvertTo-JSON -Depth 99

# find all databases on server
if($allDBs -or $exportPaths){
    $from = 0
	$allSearch = @()
	$thisallSearch = @()
	$appServerId = @()
	$appServerId = $DBObject.DBInfo.serverId | Sort-Object -Unique
    while($appServerId.Count -gt $from){
		$ID=$appServerId[$from]
		$from += 1
		$thisallSearch = (api get -v2 "data-protect/search/objects?sourceIds=$ID&isProtected=true&environments=kSQL")
		$allSearch = @($allSearch + $thisallSearch)
	}
	$allSearch
	#if ($allSearch.objects.name -eq $DBObject.DBInfo.dbLongName -and $allSearch.sourceInfo.name -eq $DBObject.DBInfo.serverName){$DBObjectFound.DBInfo = $DBObject.DBInfo}
	if ($allSearch){
		$allSearch = $allSearch | Where-Object {$_.name -eq $DBObject.DBInfo.dbLongName -and $_.sourceInfo.name -eq $DBObject.DBInfo.serverName}
		#if ($allSearch.objects){$server = $DBObject.DBInfo.serverName}
	}
	$allSearch
	
# exportFileInfo
	if($exportPaths){
		$fileInfoVec = @()
		foreach($obj in $exportPaths){
			if($obj.dbFiles){
				$dbName = $obj.instanceName
				$fileInfo = $obj.dbFiles
				$fileInfoVec = @($fileInfoVec + @{
					'name' = $dbName
					'fileInfo' = $fileInfo
				})
			}
		}
		$fileInfoVec | ConvertTo-JSON -Depth 99 | Out-File -FilePath $exportFilePath
		"Exported file paths to $exportFilePath"
		exit 0
	}
	
	if(! $appServer ){
		Write-Host "no protected DBs found for $sourceServer" -ForegroundColor Yellow
		exit
	}

    # filter by source instance
    if($sourceInstance){
        $instance = $instance | Where-Object {($_.name -split '/')[0] -eq $sourceInstance}
        if(! $instance ){
            Write-Host "no DBs found for $sourceServer/$sourceInstance" -ForegroundColor Yellow
            exit
        }
    }
    # filter by age of most recent backup
	<#if($newerThan){
        $dbresults.applicationServer = $dbresults.applicationServer | Where-Object {$_.vmDocument.versions[0].instanceId.jobStartTimeUsecs -ge $newerThanUsecs}
        if(! $dbresults.vms){
            Write-Host "no DBs found newer than $newerThan days" -ForegroundColor Yellow
            exit
        }
    }#>
	
	#Populate all Instance/Databases names
	$sourceDbNames = $instance | Sort-Object -Unique
    if(! $includeSystemDBs){
        $sourceDbNames = $sourceDbNames | Where-Object {($_ -split '/')[-1] -notin @('Master', 'Model', 'MSDB')}
    }
}

if($sourceDbNames.Count -eq 0){
    Write-Host "No DBs specified for restore" -ForegroundColor Yellow
    exit
}

if($sourceDbNames.Count -gt 1 -and $targetDB){
    Write-Host "Can't specify -targetDB when more than one database is speficified. Please use -prefix or -suffix for renaming" -ForegroundColor Yellow
    exit
}

# find target server
$targetEntity = (api get protectionSources/registrationInfo?environments=kSQL).rootNodes | Where-Object { $_.rootNode.name -eq $targetServer }
if($null -eq $targetEntity -and ! $showPaths){
    Write-Host "Target Server $targetServer Not Found" -ForegroundColor Yellow
    exit 1
}

$restoreDate = Get-Date -UFormat '%Y-%m-%d_%H:%M:%S'

if($logTime){
    $logTimeUsecs = dateToUsecs $logTime
}

# recovery params
$skippedDBs = @()
$recoveryParamNum = 1
$dbsSelected = 0
$recoveryIds = @()
$recoveryParams = @{
    "name" = "Recover_MS_SQL_$($sourceServer)_$($restoreDate)_$($recoveryParamNum)";
    "snapshotEnvironment" = "kSQL";
    "mssqlParams" = @{
        "recoveryAction" = "RecoverApps";
        "recoverAppParams" = @()
    }
}

foreach($sourceDbName in $sourceDbNames | Sort-Object){
    if(! $sourceDbName -match '/'){
        if($sourceInstance){
            $sourceDbName = "$sourceInstance/$sourceDbName"
        }else{
            $sourceDbName = "MSSQLSERVER/$sourceDbName"
        }
    }
    $thisSourceInstance, $shortDbName = $sourceDbName -split '/'    
    $search = api get -v2 "data-protect/search/protected-objects?snapshotActions=RecoverApps&searchString=$sourceDbName&environments=kSQL"
    $search.objects = $search.objects | Where-Object {$_.name -eq $sourceDbName}
    $search.objects = $search.objects | Where-Object {$_.mssqlParams.hostInfo.name -eq $sourceServer -or $_.mssqlParams.aagInfo.name -eq $sourceServer}
    if($newerThan){
        $search.objects = $search.objects | Where-Object {$_.latestSnapshotsInfo.protectionRunStartTimeUsecs -ge $newerThanUsecs}
        if($search.objects.Count -eq 0){
            ##### Uncomment
			# Write-Host "Snapshots newer than $newerThan days are not found for $sourceDbName on $sourceServer" -ForegroundColor Yellow
            continue
        }
    }
    if($search.objects.Count -eq 0){
        Write-Host "$sourceDbName not found on server $sourceServer" -ForegroundColor Yellow
        continue
    }
    if(! $logTime){
        $latest = $True
        $search.objects = @(($search.objects | Sort-Object -Property {$_.latestSnapshotsInfo.protectionRunStartTimeUsecs})[-1])
    }else{
        # find object with correct time range
        if($search.objects.Count -gt 1){
            foreach($o in $search.objects | Sort-Object -Property {$_.latestSnapshotsInfo.protectionRunStartTimeUsecs} -Descending){
                $thisSourceServer = $o.mssqlParams.hostInfo.name
                $latestSnapshotInfo = ($o.latestSnapshotsInfo | Sort-Object -Property protectionRunStartTimeUsecs)[-1]
                $clusterId, $clusterIncarnationId, $jobId = $latestSnapshotInfo.archivalSnapshotsInfo.archivalTaskId -split ':'
				$jobId = "-1"
            
                # PIT lookup
                $pitQuery = @{
                    "jobUids" = @(
                        @{
                            "clusterId" = [int64]$clusterId;
                            "clusterIncarnationId" = [int64]$clusterIncarnationId;
                            "id" = [int64]$jobId
                        }
                    );
                    "environment" = "kSQL";
                    "protectionSourceId" = $o.id;
                    "startTimeUsecs" = 0;
                    "endTimeUsecs" = $logTimeUsecs
                }
                $logs = api post restore/pointsForTimeRange $pitQuery
				#DEBUG
				Write-Host "Checking for logs" -Foreground Red
				$logs
				#END DEBUG
                $fullSnapshotInfo = $logs.fullSnapshotInfo | Where-Object {$_.restoreInfo.startTimeUsecs -le $logTimeUsecs}
                if($fullSnapshotInfo){
                    $search.objects = $o
                    break
                }
            }
        }
    }
    Write-Host "`n$($search.objects[0].name)"
    $thisSourceServer = $search.objects[0].mssqlParams.hostInfo.name
    $latestSnapshotInfo = ($search.objects[0].latestSnapshotsInfo | Sort-Object -Property protectionRunStartTimeUsecs)[-1]
    $clusterId, $clusterIncarnationId, $jobId = $latestSnapshotInfo.archivalSnapshotsInfo.archivalTaskId -split ':'
	$jobId = "-1"
	
    # PIT lookup
    $queryTime = dateToUsecs
    if($logTime){
        $queryTime = $logTimeUsecs
    }
    $pitQuery = @{
        "jobUids" = @(
            @{
                "clusterId" = [int64]$clusterId;
                "clusterIncarnationId" = [int64]$clusterIncarnationId;
                "id" = [int64]$jobId
            }
        );
        "environment" = "kSQL";
        "protectionSourceId" = $search.objects[0].id;
        "startTimeUsecs" = 0;
        "endTimeUsecs" = $queryTime
    }
    $logsAvailable = $True
    $logs = api post restore/pointsForTimeRange $pitQuery
    $timeRanges = $logs.timeRanges
    if(!$timeRanges){
        $logsAvailable = $False
    }
    $fullSnapshotInfo = $logs.fullSnapshotInfo
    if($logTime){
        $fullSnapshotInfo = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending | Where-Object {$_.restoreInfo.startTimeUsecs -le $logTimeUsecs})
        if(! $fullSnapshotInfo){
            Write-Host "    No snapshots for $logTime, skipping" -ForegroundColor Yellow
            continue
        }
    }
    if($logsAvailable){
        $logTimeValid = $False
        if($logTime -or $latest){
            foreach($timeRange in $timeRanges | Sort-Object -Property endTimeUsecs -Descending){
                if($latest){
                    $selectedPIT = $timeRange.endTimeUsecs
                    $logTimeValid = $True
                    break
                }
                if($logTimeUsecs -ge $timeRange.startTimeUsecs){
                    if($logTimeUsecs -ge $timeRange.endTimeUsecs){
                        $selectedPIT = $timeRange.endTimeUsecs
                    }else{
                        $selectedPIT = $logTimeUsecs
                    }
                    $logTimeValid = $True
                    break
                }
                $lastTimeRange = $timeRange
            }
            if($logTimeValid -eq $False){
                $selectedPIT = $lastTimeRange.startTimeUsecs
            }
            $fullSnapshot = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending | Where-Object {$_.restoreInfo.startTimeUsecs -le $selectedPIT})[0]
            $runStartTimeUsecs = $fullSnapshot.restoreInfo.startTimeUsecs
        }else{
            $fullSnapshot = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending)[0]
            $selectedPIT = $runStartTimeUsecs = $fullSnapshot.restoreInfo.startTimeUsecs
        }
    }else{
        if($logTime){
            $fullSnapshot = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending | Where-Object {$_.restoreInfo.startTimeUsecs -le $logTimeUsecs})
            if(! $fullSnapshot){
                Write-Host "    No snapshots for $logTime, skipping" -ForegroundColor Yellow
                continue
            }else{
                $fullSnapshot = $fullSnapshot[0]
            }
            $selectedPIT = $runStartTimeUsecs = $fullSnapshot.restoreInfo.startTimeUsecs
        }else{
            $selectedPIT = $runStartTimeUsecs = $search.objects[0].latestSnapshotsInfo[0].protectionRunStartTimeUsecs
        }       
    }
    if(! $showPaths){
        Write-Host " Selected Snapshot $(usecsToDate $runStartTimeUsecs)"
        if($logTimeUsecs -and $logTimeUsecs -gt $selectedPIT){
            Write-Host " Best available PIT is $(usecsToDate $selectedPIT)" -ForegroundColor Yellow
        }elseif($logTimeUsecs -and $logTimeUsecs -lt $selectedPIT){
            Write-Host " Best lesser available PIT is $(usecsToDate $selectedPIT)" -ForegroundColor Yellow
        }
        Write-Host " Selected PIT $(usecsToDate $selectedPIT)"
    }
	# $clusterId, $clusterIncarnationId, $jobId = $latestSnapshotInfo.archivalSnapshotsInfo.archivalTaskId -split ':'
	# $jobId = "-1"
	#
	$protectionGroupId = $clusterId, $clusterIncarnationId, $jobId -join ':'
    $search2 = api get -v2 "data-protect/search/protected-objects?snapshotActions=RecoverApps&searchString=$sourceDbName&protectionGroupIds=$protectionGroupId&filterSnapshotToUsecs=$runStartTimeUsecs&filterSnapshotFromUsecs=$runStartTimeUsecs&environments=kSQL"
    $search2.objects = $search2.objects | Where-Object {$_.mssqlParams.hostInfo.name -eq $thisSourceServer}
    $search2.objects = $search2.objects | Where-Object {$_.name -eq $sourceDbName}

    # recover to original instance
    $thisParam  = @{
        "snapshotId" = $search2.objects[0].latestSnapshotsInfo[0].archivalSnapshotsInfo.snapshotId;
        "targetEnvironment" = "kSQL";
        "sqlTargetParams" = @{
            "recoverToNewSource" = $false;
            "originalSourceConfig" = @{
                "keepCdc" = $false;
                "withNoRecovery" = $false;
                "captureTailLogs" = $false
            }
        }
    }
    if($logsAvailable){
        if($noStop){
            $thisParam['pointInTimeUsecs'] = (3600 + (datetousecs (Get-Date)) / 1000000)
            $thisParam.sqlTargetParams.originalSourceConfig['restoreTimeUsecs'] = (3600 + (datetousecs (Get-Date)) / 1000000)
        }else{
            $thisParam['pointInTimeUsecs'] = $selectedPIT
            $thisParam.sqlTargetParams.originalSourceConfig['restoreTimeUsecs'] = $selectedPIT
        }
    }
    $targetConfig = $thisParam.sqlTargetParams.originalSourceConfig
	
    if($captureTailLogs){
        $targetConfig.captureTailLogs = $True        
    }

    # rename DB
    $newDbName = $shortDbName
    $renameDB = $false
    if($targetDB -or $prefix -or $suffix){
        $renameDB = $True
        if($targetDB){
            $newDbName = $targetDB
        }
        if($prefix){
            $newDbName = "$($prefix)-$($newDbName)"
        }
        if($suffix){
            $newDbName = "$($newDbName)-$($suffix)"
        }
        $thisParam.sqlTargetParams.originalSourceConfig.newDatabaseName = $newDbName
    }

    # recover to alternate instance
    $alternateInstance = $false
    if($targetServer -ne $thisSourceServer -or ($targetInstance -and $targetInstance -ne $thisSourceInstance)){
        $alternateInstance = $True
        if(! $targetInstance){
            $targetInstance = 'MSSQLSERVER'
        }
        $thisParam.sqlTargetParams = @{
            "recoverToNewSource" = $true;
            "newSourceConfig" = @{
                "host" = @{
                    "id" = $targetEntity.rootNode.id
                };
                "instanceName" = $targetInstance;
                "keepCdc" = $false;
                "withNoRecovery" = $false;
                "databaseName" = $newDbName
            }
        }

        $targetConfig = $thisParam.sqlTargetParams.newSourceConfig

        if($logsAvailable){
            if($noStop){
                $targetConfig['restoreTimeUsecs'] = (3600 + (datetousecs (Get-Date)) / 1000000)
            }else{
                $targetConfig['restoreTimeUsecs'] = $selectedPIT
            }
        }
        if($overWrite){
            $targetConfig['overwritingPolicy'] = 'Overwrite'
        }
    }else{
        if($renameDB -eq $false){
            if(! $overWrite -and ! $showPaths){
                Write-Host "Please use -overwrite to overwrite original database(s)" -ForegroundColor Yellow
                exit 1
            }
        }
    }

    # file destinations
    if($alternateInstance -eq $True -or $renameDB -eq $True -or $showPaths){
        # use source paths
        $secondaryFileLocation = $null
        if(! $mdfFolder){
            $useSourcePaths = $True
        }
        if($useSourcePaths -or $showPaths){
            $FileInfoVec = $null
            if($importedFileInfo){
                $importedDBFileInfo = $importedFileInfo | Where-Object {$_.name -eq $sourceDbName}
                if($importedDBFileInfo){
                    $FileInfoVec = $importedDBFileInfo.fileInfo ##### CHECK THIS                    
                }
            }
			else{
				$fileInfo = (api get "protectionSources/applicationServers?application=kSQL&environment=kSQL").applicationServer.applicationNodes | Where-Object { $_.nodes.protectionSource.id -eq "$($search2.objects[0].id)" -and $_.nodes.protectedSourcesSummary.totalLogicalSize -ge "1" }
				Write-Host "fileInfo after leaves" -ForegroundColor Red
				$fileInfo.nodes.protectionSource.id
				#####
				if($fileInfo.nodes.protectionSource.sqlProtectionSource.PSObject.Properties['dbFiles']){
                $FileInfoVec = $fileInfo.nodes.protectionSource.sqlProtectionSource.dbFiles
                }
            }
            if(! $FileInfoVec){
                if(! $mdfFolder){
                    Write-Host "    Skipping: File info not found, please use -mdfFolder, -ldfFolder, -ndfFolders (or -importPaths)" -ForegroundColor Yellow
                    $skippedDBs = @($skippedDBs + $sourceDbName)
                    continue
                }
            }
            if($showPaths){
                $FileInfoVec | Format-Table -Property fileType, @{l='Size (MiB)'; e={$_.sizeBytes / (1024 * 1024)}}, fullPath
                # exit 0
            }
            $mdfFolderFound = $False
            $ldfFolderFound = $False
            $secondaryFileLocation = @()
            foreach($datafile in $FileInfoVec){
                $path = $datafile.fullPath.subString(0, $datafile.fullPath.LastIndexOf('\'))
                if($datafile.fileType -eq "kRows"){
                    if($mdfFolderFound -eq $False){
                        $mdfFolder = $path
                        $mdfFolderFound = $True
                    }else{
                        $secondaryFileLocation = @($secondaryFileLocation + @{"filenamePattern" = $datafile.fullPath; "directory" = $path})
                    }
                }
                if($datafile.fileType -eq "kLog"){
                    if($ldfFolderFound -eq $False){
                        $ldfFolder = $path
                        $ldfFolderFound = $True
                    }
                }
            }
        }
        if(! $mdfFolder -or ! $ldfFolder){
            Write-Host "    Skipping: File info not found, please use -mdfFolder, -ldfFolder, -ndfFolders (or -importPaths)" -ForegroundColor Yellow
            $skippedDBs = @($skippedDBs + $sourceDbName)
            continue
        }
        $targetConfig['dataFileDirectoryLocation'] = $mdfFolder
        $targetConfig['logFileDirectoryLocation'] = $ldfFolder
        if($secondaryFileLocation){
            $targetConfig['secondaryDataFilesDirList'] = $secondaryFileLocation
        }elseif($ndfFolders){
            $ndfParams = @()
            foreach($key in $ndfFolders.Keys){
                $ndfParams = @($ndfParams + @{"filenamePattern" = "$key"; "directory" = $ndfFolders["$key"]})
            }
            $targetConfig['secondaryDataFilesDirList'] = @($ndfParams)
        }
    }

    # no recovery
    if($noRecovery){
        $targetConfig['withNoRecovery'] = $True
    }

    # keep CDC
    if($keepCdc){
        $targetConfig['keepCdc'] = $True
    }

    # add this param to recovery params
    if(! $showPaths -and $commit){
        $recoveryParams.mssqlParams.recoverAppParams = @($recoveryParams.mssqlParams.recoverAppParams + $thisParam)
        $dbsSelected += 1
    }

    # perform recovery group
    if($dbsSelected -ge $dbsPerRecovery){
        # perform this recovery
        $recovery = api post -v2 data-protect/recoveries $recoveryParams
        if(! $recovery.id){
            exit 1
        }
        $recoveryIds = @($recoveryIds + $recovery.id)
        # reset params for next recovery
        $recoveryParamNum += 1
        $dbsSelected = 0
        $recoveryParams = @{
            "name" = "Recover_MS_SQL_$($sourceServer)_$($restoreDate)_$($recoveryParamNum)";
            "snapshotEnvironment" = "kSQL";
            "mssqlParams" = @{
                "recoveryAction" = "RecoverApps";
                "recoverAppParams" = @()
            }
        }
    }
}

if($dbg){
    $recoveryParams | toJson | Out-File -FilePath debug.json
    exit
}

# perform last recovery group (if any)
if($recoveryParams.mssqlParams.recoverAppParams.Count -gt 0){
    $recovery = api post -v2 data-protect/recoveries $recoveryParams
    if(! $recovery.id){
        exit 1
    }
    $recoveryIds = @($recoveryIds + $recovery.id)
}

# wait for completion
$failuresDetected = $False
if(($wait -or $progress) -and $recoveryIds.Count -gt 0){
    $finishedStates = @('Succeeded', 'Canceled', 'Failed', 'Warning', 'SucceededWithWarning')
    Write-Host "`nWaiting for recoveries to complete...`n"
    Start-Sleep 10
    foreach($recoveryId in $recoveryIds){
        $thisRecovery = api get -v2 "data-protect/recoveries/$recoveryId"
        $finishedDBs = @()
        while($thisRecovery.status -notin $finishedStates){
            if($progress){
                $dbStatus = 'unknown'
                while($dbStatus -notin $finishedStates){
                    $dbStatus = 'Succeeded'
                    $childRecoveries = api get -v2 "data-protect/recoveries?returnOnlyChildRecoveries=true&ids=$recoveryId"
                    foreach($childRecovery in $childRecoveries.recoveries | Sort-Object -Property {$_.mssqlParams.recoverAppParams[0].objectInfo.name}){
                        $dbName = $childRecovery.mssqlParams.recoverAppParams[0].objectInfo.name
                        $status = $childRecovery.status
                        if(! $status){
                            $dbStatus = 'unknown'
                        }
                        if($status -notin $finishedStates){
                            $dbStatus = $status
                        }
                        $progressTaskId = $childRecovery.progressTaskId
                        $progressMonitor = api get "/progressMonitors?taskPathVec=$progressTaskId&excludeSubTasks=true&includeFinishedTasks=true&includeEventLogs=false&fetchLogsMaxLevel=0"
                        $percentComplete = $progressMonitor.resultGroupVec[0].taskVec[0].progress.percentFinished
                        if($percentComplete -gt 0){
                            if($dbName -notin $finishedDBs){
                                Write-Host "`r$($dbName): $([math]::Round($percentComplete, 0))%" -NoNewLine
                                if([math]::Round($percentComplete, 0) -eq 100){
                                    Write-Host " $status"
                                    $finishedDBs = @($finishedDBs + $dbName)
                                }
                            }
                        }
                    }
                    if($dbStatus -notin $finishedStates){
                        Start-Sleep $sleepTime
                    }
                }
                Write-Host ""
            }else{
                Start-Sleep $sleepTime
            }
            $thisRecovery = api get -v2 "data-protect/recoveries/$recoveryId"
        }
        $childRecoveries = api get -v2 "data-protect/recoveries?returnOnlyChildRecoveries=true&ids=$recoveryId"
        foreach($childRecovery in $childRecoveries.recoveries | Sort-Object -Property {$_.mssqlParams.recoverAppParams[0].objectInfo.name}){
            $dbName = $childRecovery.mssqlParams.recoverAppParams[0].objectInfo.name
            $status = $childRecovery.status
            Write-Host "$dbName completed with status: $status"
            if($childRecovery.messages){
                Write-Host "$($childRecovery.messages[0])" -ForegroundColor Yellow
            }
            if($status -ne 'Succeeded'){
                $failuresDetected = $True
            }
        }
    }
    if($failuresDetected -or $recoveryIds.Count -eq 0){
        Write-Host "`nFailures Detected`n" -ForegroundColor Yellow
        if($skippedDBs.Count -gt 0){
            Write-Host "Skipped DBs (missing file paths):`n`n$($skippedDBs -join "`n")`n" -ForegroundColor Yellow
        }
        exit 1
    }else{
        Write-Host "`nRestores Completed Successfully`n" -ForegroundColor Green
        if($skippedDBs.Count -gt 0){
            Write-Host "Skipped DBs (missing file paths):`n`n$($skippedDBs -join "`n")`n" -ForegroundColor Yellow
            exit 1
        }
        exit 0
    }
}elseif($recoveryIds.Count -gt 0){
    Write-Host "`nPerforming recoveries...`n"
}else{
    Write-Host ""
}

if(! $commit){
    Write-Host "Exiting without recovering. Please use the -commit switch to perform the recoveries" -ForegroundColor Yellow
    exit 0
}
if($skippedDBs.Count -gt 0){
    Write-Host "Skipped DBs (missing file paths):`n`n$($skippedDBs -join "`n")`n" -ForegroundColor Yellow
    exit 1
}

exit 0