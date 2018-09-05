###############################################################################################################################################################
#This allows you to automatically unpack the websites and have it extract to the correct folder. It also turns off the website and reenables it including the app pools.
#The file to extract is expected to be in the $webSiteRootFolder on the server ($targetComputer). 
###############################################################################################################################################################

Param(	
	#Fully qualified name of the target computer.
	[string]$targetComputer,
	#Websites (by name) that need to be stopped and started. Websites are always stopped first and started last
	#Array of [Zip File:Website,Project Name Website]
	#The website MUST have the same name as the app pool, otherwise the app pool will not be stopped and started.
	# Ex: "FileName.zip:SiteNameThatMatchesAppPool,FileName.zip:SiteNameThatMatchesAppPool"
    #This supports individual names for the site, app pool and the folder. The curly braces and pipe are literals.
    # EX: "FileName.zip:{SiteName|AppPoolName}SiteFolder"
	[string] $projectAndSites,
	# Usually "C:\inetpub\wwwroot"
	[string] $webSiteRootFolder,
	<#User name to execute against the server (optional, if excluded then executed against current user) #>
	[string]$userName,
	<#User password to execute against the server (optional, if excluded then executed against current user) #>
	[string]$userPassword
)

#Extracts the compressed file to the destination folder on the remote server. If you want to use zip then change it here.
function ExtractFiles($session, [string] $compressedFile, [string] $destination)
{
	Write-Output "Extracting '$($compressedFile)' to '$($destination)'...."

    #WinRar
    #[string]$command = """C:\Program Files\WinRAR\unrar.exe"" x ""$($compressedFile)"" ""$($destination)"""
    
    #7Zip
    [string]$command = """C:\Program Files\7-Zip\7z.exe"" x ""$($compressedFile)"" -aoa -o""$($destination)"""
    
    #Power shell zip. This is only supported in later versions. Use the other commands if you don't want this.
    #$command = {
    #    Expand-Archive -LiteralPath "$($compressedFile)" -DestinationPath "$($destination)"
    #}
    
    Invoke-Command -Session $session -ScriptBlock { 
        param($expandCommand)         
		Invoke-Expression "& $($expandCommand)"
    } -ArgumentList $command
}

#Creates multiple commands that target a single item
# usage: "MultipleCommandsByArray -targets $webSites -command "Start-WebSite""
function MultipleCommandsByArray([string[]] $targets, [string] $command)
{
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

class SiteDescription
{
    [string]$SiteName
    [string]$SitePath
    [string]$AppPoolName
    [string]$CompressedFile

    #Takes in the site as specified by the user and determins if the app pool is standard or the same name as the site or explicity specified
    # EX: FileName.zip:SiteNameThatMatchesAppPool -> SiteNameThatMatchesAppPool (AppPool)
    # EX: FileName.zip:{SiteName|AppPoolName}SiteFolder -> AppPoolName (AppPool)
    SiteDescription([string] $argumentParameters)
    {
        $argumentParameters -match "(.+\.zip):(({(.+)\|(.+)}(.+))|(.+))"

        #See if has a 
        if($Matches[7] -ne $null)
        {
            $this.SiteName = $Matches[7]
            $this.SitePath = $Matches[7]
            $this.AppPoolName = $Matches[7]
            $this.CompressedFile = $Matches[1]
        }
        else
        {
            $this.SiteName = $Matches[4]
            $this.SitePath = $Matches[6]
            $this.AppPoolName = $Matches[5]
            $this.CompressedFile = $Matches[1]
        }        
    }

}


#Stop execution on the first error
$ErrorActionPreference = "Stop"

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
[string[]] $projectAndSitesArray = $projectAndSites.Split(",")
[System.Collections.ArrayList]$webSites = New-Object System.Collections.ArrayList
[System.Collections.ArrayList]$appPoolNames = New-Object System.Collections.ArrayList
[System.Collections.ArrayList]$webSiteNames = New-Object System.Collections.ArrayList

#remove just the website information so the site can be stopped and started.
foreach($item in $projectAndSitesArray)
{
    $newDescription = [SiteDescription]::new($item)
    $webSites.Add($newDescription)
    $appPoolNames.Add($newDescription.AppPoolName)
    $webSiteNames.Add($newDescription.SiteName)
}

If($webSites.Length -gt 0)
{
    $stopAppPoolScriptBlock =
	{
        param([string]$appPools)
        Import-Module WebAdministration        

        foreach($item in Get-ChildItem IIS:\AppPools | where {$_.state -eq "Started" -and $appPools.contains($_.name) })
		{
			Write-Output "Stoping AppPool $($item.name)"
			Stop-WebAppPool $item.name
			#Make sure it it shut down by taking a short nap.
			Start-Sleep -s 1

			$status = Get-WebAppPoolState -name $item.name

			If($status -ne "Stopped"){
				Write-Output "$($item.name) is not stopped going to one more time"
				Start-Sleep -s 10
				#Stop it again, but if it is already stopped, just continue without fail.
				Stop-WebAppPool $item.name -erroraction "silentlycontinue"
			}
		}
	}

    Write-Output "Stopping website app pools: $($appPoolNames)"
	Invoke-Command -Session $session -ScriptBlock $stopAppPoolScriptBlock -ArgumentList "$($appPoolNames)"

    $stopWebsiteBlock = [System.Management.Automation.ScriptBlock]::Create($(MultipleCommandsByArray -targets $webSiteNames -command "Stop-WebSite"))    
    Write-Output "Stopping websites: $($stopWebsiteBlock)"    
    Invoke-Command -Session $session -ScriptBlock $stopWebsiteBlock	
}


#Remove all of the existing files so the target folder is clean. Fail if the files are still locked
foreach ($site in $webSites) 
{
    [string] $compressedFile = "$($webSiteRootFolder)\$($site.CompressedFile)"
    [string] $website = $site.SitePath
    [string] $websitePath = "$($webSiteRootFolder)\$($website)"

    If(Invoke-Command -Session $session -ScriptBlock {param($file) Test-Path $file} -ArgumentList $compressedFile)
    {
        Write-Output "Deleting all existing files in '$($webSiteRootFolder)\$($website)' on $($targetComputer)"

        Invoke-Command -Session $session -ScriptBlock { 
            param($targetSiteFolder) 
                Remove-Item -Path $targetSiteFolder\* -Recurse -Force -ErrorAction "Stop"
            } -ArgumentList $websitePath

        Write-Output "Extracting file $($compressedFile)"
	    ExtractFiles -session $session -compressedFile $compressedFile -destination $websitePath
    }
    Else
    {
        Write-Output "$($compressedFile) not found, skipping the site $($website)"
    }
}

If($webSites.Length -gt 0)
{
	$startAppPoolScriptBlock =
	{
        param([string]$sites)
        Import-Module WebAdministration

		foreach($item in Get-ChildItem IIS:\AppPools | where {$_.state -eq "Stopped" -and $sites.contains($_.name) })
		{
			Write-Output "Starting AppPool $($item.name)"
			Start-WebAppPool $item.name
		}
	}
    
    Write-Output "Starting website app pools: $($appPoolNames)"
	Invoke-Command -Session $session -ScriptBlock $startAppPoolScriptBlock  -ArgumentList "$($appPoolNames)"

    $startWebsiteBlock = [System.Management.Automation.ScriptBlock]::Create($(MultipleCommandsByArray -targets $webSiteNames -command "Start-WebSite"))
    Write-Output "Starting websites: $($webSites)"
    Invoke-Command -Session $session -ScriptBlock $startWebsiteBlock


}



