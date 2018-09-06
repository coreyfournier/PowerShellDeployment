###############################################################################################################################################################
#This allows you to automatically unpack the service and have it extract to the correct folder. It also turns off the service and reenables it.
#The file to extract is expected to be in the $serviceRootFolder on the server ($targetComputer). 
###############################################################################################################################################################
[CmdletBinding()]
Param(
	<#Fully qualified name of the target computer.#>
	[string][Parameter(Mandatory=$true)]$targetComputer,
	<#User name to execute against the server (optional, if excluded then executed against current user) #>
	[string]$userName,
	<#User password to execute against the server (optional, if excluded then executed against current user) #>
	[string]$userPassword,
	<#Tells the script to not turn the services back on.#>
	[bool] $dontTurnOn,
	# Specifiy the process name followed by the individual services that run in the process that will required to be shut down and restarted.
	#ProcessName:ServicesInProcess,NextService
	[ValidatePattern('.+\:((.+)|(.+,))')]
	[string][Parameter(Mandatory=$true)] $targetService,
	#Location and name of the zip file to be extrated
	[string][Parameter(Mandatory=$true)] $sourceZipFile,
	#Location to extract the file and remove any existing files
	[string][Parameter(Mandatory=$true)] $destinationFolder
)

#Stop execution on the first error
$ErrorActionPreference = "Stop"
[int] $secondsToWaitForTaskToEnd = 60

if([string]::IsNullOrEmpty($targetService))
{
	Write-Output "The process and a list of service names are required."
	Exit(1)
}

class ProcessDescription
{
	[string]$ProcessName
	[string[]]$ServiceNames
	[string]$DestinationFolder
	# Full path to the zip file
	[string]$ZipFileName	

	ProcessDescription([string] $targetService, [string] $sourceZipFile, [string] $destinationFolder)
	{
		$arguments = $targetService.Split(":")
		$this.ProcessName = $arguments[0]
		$this.ServiceNames = $arguments[1].Split(",")
		$this.DestinationFolder = $destinationFolder
		$this.ZipFileName = $sourceZipFile
	}
}

$processDescription = [ProcessDescription]::new($targetService, $sourceZipFile, $destinationFolder)

#Creates multiple commands that target a single item
# usage: "MultipleCommandsByArray -targets $webSites -command "Start-WebSite""
function MultipleCommandsByArray
{
    param([string[]] $targets, [string] $command)

    [string] $commands = ""

    foreach ($target in $targets) 
    {
        If($commands -eq "")
        {
            $commands = "$($command) $($target)"
        }
        Else
        {
            $commands = "$($commands); $($command) $($target)"
        }
    }

    return $commands
}

#Blocks execution until the service has reached the specified status
function WaitUntilServiceStatus($session, [string[]]$serviceNames, [string]$status)
{
    $scriptBlock = { 
        param($serviceNames, $status) 
        foreach($name in  $serviceNames)
        {
            #its ok if it's not found, as this is a new install.
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if($service -eq $null)
            {
                Write-Output "'$($name)' was not found. Assuming this is a new install."
            }
            else
            {
                Write-Output "Waiting for $($name) to change to the status of $($status) with the current status of $($service.Status)"
                # Wait for the service to reach the $status or a maximum of 30 seconds
                $service.WaitForStatus($status, '00:00:30')
            }
            
        }
    }
 
	#Run the command on the remote computer
    Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $serviceNames, $status    
}

#Checks to see if the process is still running. Filters the processes by the folder the exe is running in as multiple exes can have the same process name.
function CheckIfProcessIsRunning($session, [string]$processName, [string]$destinationFolder)
{
    $scriptBlock = {
        param($processName, $folder)
		#if it is not found then don't let it fail.
        $processes = Get-Process -name $processName -ErrorAction SilentlyContinue | Select-Object Path, Id

        ForEach($process in $processes)
        {   
            #Look at the path and see if it has the environment name in it. If so, then the exe is still in use.
            If(-not [string]::IsNullOrEmpty($process.Path) -and $process.Path -like "$($folder)*")
            {
                Write-Output "Process found running. Path: '$($process.Path)' Id: $($process.Id)"        
                Return $true
            }    
        }

        return $false
    }

	#Run the command on the remote computer
    Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $processName, $destinationFolder
}

#Extracts the compressed file to the destination folder on the remote server. If you want to use zip then change it here.
function ExtractFiles($session, [string] $compressedFile, [string] $destination)
{
	Write-Output "Extracting '$($compressedFile)' to '$($destination)'...."

    #WinRar
    #[string]$command = """C:\Program Files\WinRAR\unrar.exe"" x ""$($compressedFile)"" ""$($destination)"""
    
    #7Zip
    [string]$command = """C:\Program Files\7-Zip\7z.exe"" x ""$($compressedFile)"" -aoa -o""$($destination)\"""
    
    Invoke-Command -Session $session -ScriptBlock { 
        param($expandCommand)         
		Invoke-Expression "& $($expandCommand)"
    } -ArgumentList $command
}

#****************************************************************************************************************************************
# Main Execution
#****************************************************************************************************************************************

#On the client computer make sure to enable HTTPS for winrm. https://support.microsoft.com/en-us/help/2019527/how-to-configure-winrm-for-https
if([string]::IsNullOrEmpty($userName) -or [string]::IsNullOrEmpty($userPassword))
{
	Write-Output "User Name and Password not supplied connecting to $($targetComputer) using current context"
	$session = New-PSSession -ComputerName $targetComputer
}
else
{
	Write-Output "User Name and Password supplied, connecting to $($targetComputer) using $($userName)"

	$pw = convertto-securestring -AsPlainText -Force -String $userPassword
	$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $userName, $pw
	$session = New-PSSession -ComputerName $targetComputer -credential $cred
}

#Make sure the compressed file exists on the server first
If(Invoke-Command -Session $session -ScriptBlock {param($compressedFile) Test-Path $compressedFile} -ArgumentList $processDescription.ZipFileName) 
{
    $stopServicesBlock = [System.Management.Automation.ScriptBlock]::Create($(MultipleCommandsByArray -targets $processDescription.ServiceNames -command "Stop-Service"))
    $startServicesBlock = [System.Management.Automation.ScriptBlock]::Create($(MultipleCommandsByArray -targets $processDescription.ServiceNames -command "Start-Service"))

    Write-Output "Stopping Services: $($stopServicesBlock)"    
    #Stop the services. If they are not found then continue on.
    Invoke-Command -Session $session -ScriptBlock $stopServicesBlock -ErrorAction SilentlyContinue
    
    #Wait until all services are stopped so no files are locked.
    WaitUntilServiceStatus -session $session -serviceName $processDescription.ServiceNames -status "Stopped"
    
    #Wait a little longer as the files are sometimes still locked for a few seconds longer.
    Start-Sleep -Seconds 2

    If(CheckIfProcessIsRunning -session $session -processName $processDescription.ProcessName -destinationFolder $processDescription.DestinationFolder)
    {
        Write-Output "The process is still running, it maybe a scheduled task. I will wait for $($secondsToWaitForTaskToEnd) seconds before continuing."
        Start-Sleep -Seconds $secondsToWaitForTaskToEnd
    }

	#Remove all of the existing files so the target folder is clean. Fail if the files are still locked after waiting once.
    Write-Output "Deleting all existing files in '$($processDescription.DestinationFolder)' on $($targetComputer)"
    Invoke-Command -Session $session -ScriptBlock { 
        param($targetServiceFolder) 
            Try
            {
                Remove-Item $targetServiceFolder\* -Recurse -Force -ErrorAction "Stop"
            }
            Catch [UnauthorizedAccessException]
            {
                Write-Output "Now waiting for all files to be released as they are still locked"
                #Wait for all services to completely release access
                Start-Sleep -Seconds 10
                Remove-Item $targetServiceFolder\* -Recurse -Force -ErrorAction "Stop"
            }
        } -ArgumentList $processDescription.DestinationFolder
	
	#Extract the compressed file
	ExtractFiles -session $session -compressedFile $processDescription.ZipFileName -destination $processDescription.DestinationFolder
	
	if($dontTurnOn -eq $true)
	{
		Write-Output "Will not start any services due to the flag 'dontTurnOn'"    
	}
	else
	{
		Write-Output "Starting Services: $($startServicesBlock)"    
		Invoke-Command -Session $session -ScriptBlock $startServicesBlock

		#Wait until all services are running so to ensure there are no failed operations.
		WaitUntilServiceStatus -session $session -serviceName $processDescription.ServiceNames -status "Running"
	}   

    Exit(0)
}
Else
{
    Write-Output "'$($processDescription.ZipFileName)' was not found on the server $($targetComputer). Exiting as there is nothing to deploy!"
    Exit(1)
}

