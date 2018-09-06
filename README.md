# Power Shell Deployment
Power Shell Scripts to automate deploying websites and services. It also contains a script to run the latest migrations for Entity Framework.
I am trying to create VSTS extensions, so the organization of the files will change as well as the scripts may also change to satisfy requirements of this.
See the script file for more information on parameters, but examples of how I have setup my VSTS PowerShell script tasks are shown below.

## Requirements
* All of the scripts expect the code to already be deployed to the server and be zipped up. This is to reduce the amount of time it takes to complete the deployment
* The scripts expects 7zip to be installed on the server at 'C:\Program Files\7-Zip\7z.exe'. I know power shell has compression, but at the time this was not in the version of PS I was using.
* The user the exectes the script must have sufficient access to the server to run the command 'New-PSSession'. If I remember correctly that's RDP access. If no user is supplied then it runs under the current context.
* EF requires the nuget package data for Entity Framwork. This is documented in detail below.

## Website Deployment (scriptDeployWebsite.ps1)
For VSTS I publish the script as an artifact using the name '$(Build.BuildNumber)-Scripts' and reference the script path using this:

`$(Build.DefinitionName)\$(Build.BuildNumber)-Scripts\DeployWebsite.ps1`

Arguments to the script: 

`-webSiteRootFolder  "C:\inetpub\wwwroot" -targetComputer "$(WebServerName)" -projectAndSites "$(BuildConfiguration)-Project1.zip:DomainName$(BuildConfiguration).tsged.com,$(BuildConfiguration)-Project2.zip:DomainName2$(BuildConfiguration).tsged.com" -userName $(ServerUserName) -userPassword $(ServerUserPassword)`

User defined variables are: ServerUserPassword, WebServerName, ServerUserName. If the username and password are not supplied it connects to the destination server


## Service Deployment (DeployService.ps1)
For VSTS I publish the script as an artifact using the name '$(Build.BuildNumber)-Scripts' and reference the script path using this:

 `$(Build.DefinitionName)\$(Build.BuildNumber)-Scripts\DeployService.ps1`

 Arguments to the script:

 `-dontTurnOn $false -targetComputer "$(ServicesServerName)" -userName $(ServerUserName) -userPassword $(ServerUserPassword) -targetService "ProcessName:HostedServices-$(BuildConfiguration),PollingBullhornService-$(BuildConfiguration),PickupAndSendLeadsService-$(BuildConfiguration),WorkflowService-$(BuildConfiguration),DataTrickle-$(BuildConfiguration),JobScheduler-$(BuildConfiguration)" -sourceZipFile "C:\Services\Recruiting\$(BuildConfiguration)-CodeFile.zip" -destinationFolder "C:\Services\Recruiting\$(BuildConfiguration)\"`

  User defined variables are: ServicesServerName, ServerUserName, ServerUserPassword

## Entity Framework Migration (EfMigration.ps1)
EF requires access to the Framework path, so I publish the path as an artifact. For me the relative path is 'Packages\EntityFramework.6.1.3' and is stored as a variable in VSTS when and if the version changes.
For VSTS I publish the script as an artifact using the name '$(Build.BuildNumber)-Scripts' and reference the script path using this:

`$(Build.DefinitionName)\$(Build.BuildNumber)-Scripts\EfMigration.ps1`

 Arguments to the script:

 `-EFrameworkPath "$(Build.DefinitionName)\$(Build.BuildNumber)-Scripts\tools" -projectMigrationExe "$(Build.DefinitionName)\$(Build.BuildNumber)-BuiltFiles\CoreFile.dll" -connectionString "$(DatabaseConnection)"`