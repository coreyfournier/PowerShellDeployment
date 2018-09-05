###############################################################################################################################################################
#Applies the latest migrations for entity framework
# The intent of $workingDirectory vs $EFrameworkPath is so the migrations can be run from TFS build or TFS release using built artifacts. As the artifacts
# lack the nuget packages containing the EF tools.
###############################################################################################################################################################

Param(
  <#(Optional) base working directory that has all of the source files in it. This must contain the nuget package folder and is used to find the EF Framework folder to get the tools out of. If this is not supplied then the efFramework needs to be specified.#>
  [string]$workingDirectory,
  <#(Optional) Folder to the Entity Framework tools. If this is not set then the $workingDirectory needs to be set #>
  [string]$EFrameworkPath,
  <#Compiled code to run the migrations against, usually the bin directory. Exe or Dll that has the migration folder. Must be the full path.#>
  [string]$projectMigrationExe,
  <#Optional. If not supplied it uses the config file of the (projectMigrationExe) #>
  [string]$connectionString
)

#Stop execution on the first error
$ErrorActionPreference = "Stop"
[string] $migrateFile = "migrate.exe"
[string] $efTools = ""
[string]$projectMigrationSource = ""

if([string]::IsNullOrEmpty($projectMigrationExe))
{
    Write-Output "projectMigrationExe parameter not set as expected. This is required as I need it to know what migrations to apply"
    Exit 1
}
else
{
    $projectMigrationSource = "$((get-item $projectMigrationExe).DirectoryName)\"
}


if([string]::IsNullOrEmpty($EFrameworkPath) -and [string]::IsNullOrEmpty($workingDirectory))
{
	Write-Output "Both $workingDirectory and $EFrameworkPath are not set, at least one must be specified so i can find the tools to run the migrations"
	Exit 1
}
elseif([string]::IsNullOrEmpty($EFrameworkPath)) # Using $workingDirectory
{
	Write-Output "Working Directory set, attempting to find the EF folder in the nuget package folder"	

	#Find the entity framework directory
	$entityFrameworkFolder = Get-ChildItem "$($workingDirectory)\packages" | Where-Object {$_.PSIsContainer -eq $true -and $_.Name -like "EntityFramework*"}
	[string] $packagesFolder = "$($workingDirectory)\packages"

	if($entityFrameworkFolder.Length -eq 0)
	{
		Write-Output "Entity framwork folder not found in $($packagesFolder)"
		Exit 1
	}
	else
	{
        
        $efTools = $($entityFrameworkFolder[0].FullName)	
        
	}
}
else #using $EFrameworkPath
{
    Write-Output "Using explicity set Entity Framework tools path"
	$efTools = $EFrameworkPath
} 

Write-Output "Found Entity Framework tools in $efTools going to copy them to $($projectMigrationSource)"
#EF tools need to be in the same directory as the project output files (dll / exe)
Copy-Item "$($efTools)\*" $projectMigrationSource

[string] $migrationExePath = "$($projectMigrationSource)$($migrateFile)"

#Make sure the file is really there
if(Test-Path $migrationExePath)
{
    [string] $startupExe = (get-item $projectMigrationExe).name         
    [string] $commandToRun

    #No connection string supplied
    if($connectionString -eq "")
    {
        ####Assume the dll has the config file for the connection information#####
            
        #default it as if it's an exe project and not a website
        [string] $startupConfigurationFile = "$($startupExe).config"

        if($startupExe -like "*.dll")
        {
            Write-Output "Detected a website so using web.config as the startup settings file"
            $startupConfigurationFile = "web.config"
        }

        $commandToRun = """$($migrationExePath)"" $($startupExe)"" /startupConfigurationFile=$($startupConfigurationFile)"
    }
    else
    {
        #Assume the person is using sql server, so hard coding the provider
        $commandToRun = """$($migrationExePath)"" ""$($startupExe)"" /connectionString=""$($connectionString)"" /connectionProviderName=”"System.Data.SqlClient"”"
    }

    #All Migration commands that could be executed.
    #https://msdn.microsoft.com/en-us/library/jj618307(v=vs.113).aspx
    Invoke-Expression "& $($commandToRun)"
}
else
{
    Write-Output "$($migrationExePath) was not found as expected, something happend in the copy process or it was in the package folder (working folder) or the specified EFramework location"
	Exit 1
}

