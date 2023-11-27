# Restore a SQL Database Using PowerShell

Warning: this code is provided on a best effort basis and is not in any way officially supported or sanctioned by Cohesity. The code is intentionally kept simple to retain value as example code. The code in this repository is provided as-is and the author accepts no liability for damages resulting from its use.

`Note:` This script is designed for Cohesity Bacckup as a Service only (DMaaS), it is not suitable for Cohesity Clusters.

This script demonstrates how to perform an restore of a SQL database. The script can restore the database to the original server, or a different server. 
It can overwrite the existing database or restore with a different database name.  

## Warning

This script can overwrite production data if you ask it to. Make sure you know what you are doing and test thoroughly before using in production!!!

## Download the script

Run these commands from PowerShell to download the script(s) into your current directory

```powershell
# Download Commands
$scriptName = 'restoreSQL_DMaaS'
$repoURLbrian = 'https://raw.githubusercontent.com/bseltz-cohesity/scripts/master'
$repoURLmauro = 'https://raw.githubusercontent.com/mauceano/scripts/master/'
(Invoke-WebRequest -UseBasicParsing -Uri "$repoURLmauro/dmaas/SQL/$scriptName/$scriptName.ps1").content | Out-File "$scriptName.ps1"; (Get-Content "$scriptName.ps1") | Set-Content "$scriptName.ps1"
(Invoke-WebRequest -UseBasicParsing -Uri "$repoURLbrian/powershell/cohesity-api/cohesity-api.ps1").content | Out-File cohesity-api.ps1; (Get-Content cohesity-api.ps1) | Set-Content cohesity-api.ps1
# End Download Commands
```

## Components

* restoreSQLDBs_DMaaS.ps1: the main powershell script
* cohesity-api.ps1: the Cohesity REST API helper module

Place both files in a folder together and run the main script like so:

```powershell
# examples

# restore to the original location
./restoreSQL_DMaaS.ps1 -region mydmaasregion `
                 -username myusername `
                 -sourceServer mysqlserver `
                 -sourceDB mydb `
                 -overwrite `
                 -latest

# restore to an alternate location
./restoreSQL_DMaaS.ps1 -region mydmaasregion `
                 -username myusername `
                 -sourceServer mysqlserver `
                 -sourceDB mydb `
                 -targetServer sqlserver2 `
                 -targetDB restoredb `
                 -mdfFolder c:\sqldata `
                 -ldfFolder c:\sqllogs `
                 -latest
# end examples
```

## Authenticating to DMaaS

DMaaS uses an API key for authentication. To acquire an API key:

* log onto DMaaS
* click Settings -> access management -> API Keys
* click Add API Key
* enter a name for your key
* click Save

## Basic Parameters

* -sourceServer: Server name (or AAG name) where the database was backed up
* -sourceDB: Original database name e.g. MYDB or MYINSTANCE/MYDB
* -overwrite: Overwrites an existing database (default is no overwrite)
* -sourceInstance: one or more instance names (see below)
* -sourceNodes: (optional) Limit source results to these AAG nodes (comma separated)

## Alternate Target Parameters

* -mdfFolder: Location to place the primary data file (e.g. C:\SQLData)
* -targetServer: Server name to restore to (defaults to same as sourceServer)
* -targetDB: New database name (defaults to same as sourceDB)
* -targetInstance: Instance name to restore to (defaults to MSSQLSERVER)
* -showPaths: show data/log file paths and exit
* -useSourcePaths: use same paths to restore to target server
* -ldfFolder: Location to place the log files (defaults to same as mdfFolder)
* -ndfFolder: Location to place the secondary files (defaults to same as ndfFolder)
* -ndfFolders: Locations to place various ndf files (see below)

## Point in Time Parameters

* -logTime: Point in time to replay the logs to during the restore (e.g. '2019-04-10 22:31:05')
* -latest: Replay the logs to the latest log backup date
* -noStop: Replay the logs to the last transaction available
* -captureTailLogs: Replay logs that haven't been backed up yet (only applies when overwriting original database)

## Restore Options

* -keepCdc: Keep change data capture during restore (default is false)
* -withClause: VDI with clause e.g. `-withClause "WITH BUFFERCOUNT = 256,MAXTRANSFERSIZE = 4194304"`
* -noRecovery: Restore the DB with NORECOVER option (default is to recover)
* -resume: Resume recovery of previously restored database (left in NORECOVERY mode)
* -update: short hand for -resume -noRecovery -latest

## Other Parameters

* -wait: Wait for the restore to complete and report end status (e.g. kSuccess)
* -progress: display percent complete
* -sleepTimeSecs: sleep between status queries (default is 30 seconds)

## Source Intances

By default, the script will default to MSSQLSERVER as the source instance. You can specify a source instance in a few ways:

* You can specify the source instance as part of the -sourceDB parameter, like `-sourceDB MYINSTANCE/MYDB`
* You can specify the source instance using the -sourceInstance parameter, like `-sourceInstance MYINSTANCE`

## Removed - Self-Managed Cluster Parameters

These parameters existed in the Cohesity Clusters version of script, which are not applicable to DMaaS

* -vip: Not applicable to DMaaS
* -domain: Not applicable to DMaaS
* -password: Not applicable to DMaaS
* -useApiKey: Removed and defaulted as in DMaaS all connections require API Keys
* -noPrompt: Not applicable to DMaaS
* -tenant: Not applicable to DMaaS
* -mcm: Not applicable to DMaaS
* -clusterName: Not applicable to DMaaS
* -restoreFromArchive: Removed and defaulted as in DMaaS all backup copies are considered Archives

## Overwrite Warning

Including the **-overwrite** parameter will overwrite an existing database. Use this parameter with extreme caution.

## Multiple Folders for Secondary NDF Files

```powershell
-ndfFolders @{ '.*DataFile1.ndf' = 'E:\SQLData'; '.*DataFile2.ndf' = 'F:\SQLData'; }
```

## Point in Time Recovery

If you want to replay the logs to the very latest available point in time, use the **-latest** parameter.

Or, if you want to replay logs to a specific point in time, use the **-logTime** parameter and specify a date and time in military format like so:

```powershell
-logTime '2019-01-20 23:47:02'
```

Note that when the -logTime parameter is used with databases where no log backups exist, the full/incremental backup that occured at or before the specified log time will be used.
