cls
#region header
$Var_Controllers = @("CitrixController")
$Var_Site = "CitrixSite"
$Var_IntRelay = "EmailRelay"
$Var_Sender = "EmailSender"
$Var_Recipients = @("EmailRecipients")

$Date = $(Get-Date -Format 'yyyy-MM-dd_HH_mm')
$LogFileRoot = "$PSScriptRoot\$Date"
$TranscriptPath = "$($LogFileRoot)\$($Date)_RebootTranscript.txt" 

Start-Transcript -Path $TranscriptPath

Clear-Host
Write-Output "################################################################"
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Starting reboot script"

#endregion

$Elapsed = [System.Diagnostics.Stopwatch]::StartNew()

$Modules = @("PoshRSJob","C:\Program Files\Citrix\PowerShellModules\Citrix.Broker.Commands\Citrix.Broker.Commands.psd1")
$Modules | % {
	Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Importing Module $_"
	Remove-Module $_ -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
	Import-Module $_ -ErrorAction Stop -WarningAction SilentlyContinue
}

#Below Tags are used to delimit which delivery groups we are looking to reboot. 
#In this instance, we want to reboot all Delivery Groups marked as Production and QA. 
#Additionally, we have Delivery Groups that are not marked Production or QA but we still want them rebooted so the "Reboot" Tag is leveraged.
$DeliveryGroups = Get-BrokerDesktopGroup -AdminAddress $($Var_Controllers|Get-Random) -MaxRecordCount 10000 -InMaintenanceMode $false -SessionSupport SingleSession | ?{$_.tags -contains "Production" -or $_.tags -contains "QA" -or $_.tags -contains "Reboot"}

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Delivery Groups targeted for reboot"
$DeliveryGroups | select name, tags | Out-Default

#In the following statement, we want to look for machines that meet our criteria of 'Powered on' and 'Not in MaintenanceMode' for reboot.
#All of the machines we want to reboot must be machines located in the delivery groups we obtained above.
$Machines = $DeliveryGroups | %{
		Get-BrokerMachine -AdminAddress $($Var_Controllers|Get-Random) -MaxRecordCount 10000 -PowerState On -SessionSupport SingleSession -InMaintenanceMode $false -DesktopGroupName $_.name
}

#Here we want to obtain all of the unique hosts that are hosting valid virtual machines for reboot.
$Hosts = $Machines | Select HostingServerName -Unique | Sort-Object -Descending Hostingservername

Function Invoke-RemoteDosCommand {  
  [CmdletBinding()]Param(
    [Parameter(Mandatory=$true)][System.String]$MachineName,
    #[Parameter()][System.Management.Automation.PSCredential]$MachineCredential = $(New-Object System.Management.Automation.PSCredential("prod-am\zcompbuild",$(ConvertTo-SecureString "Sp1cyTun@" -AsPlainText -Force))),
    [Parameter(Mandatory=$true)][System.String]$DosCommand
  )
  $Cmd = "cmd /c $DosCommand"
  #Run the command      
  try {
    $ExecutionData += "Running remote command $DosCommand on $MachineName and retrieving process ID. "
    $Process = (Invoke-WmiMethod <#-Credential $MachineCredential#> -Class win32_process -Name create -ArgumentList $Cmd -ComputerName $MachineName -ErrorAction Stop)
    $ProcessID = $Process.ProcessID
  }
  catch {
    $ExceptionData = $_
  }
  #Wait for completion
  If(!$ExceptionData){
    $ExecutionData += "Waiting for process $processID to complete..."
    do {
      try {
        $ExecutionData += "Waiting..." 
        $RunningCheck = Get-WmiObject -Class Win32_Process -Filter "ProcessId='$ProcessId'" -ComputerName $MachineName -ErrorAction SilentlyContinue | ? { ($_.ProcessName -eq 'cmd.exe') } 
      }
      catch {
        $ExceptionData = $_
      }
    } while ($RunningCheck -ne $null)
    $ExecutionData += "Process return value is $($Process.ReturnValue)"
  }
  #Return results or exception
  If($ExceptionData){
      return $ExceptionData
      } else {
            return $ExecutionData
      }
}


#region Threads
<#
	The design implementation of the threads below was a Tree structure concept.

	Rather than multithreading n linear runspaces where n is the number of virtual machines, the intent here was to generate 
	m number of runspaces where m is the number of Hypervisor Hosts hosting the virtual machines. 
	Each m runspace would then be responsible for rebooting the virtual machines it is hosting (j).

	For example, you have 60 Hypervisor Hosts where each host services 30 Virtual Machines.
	The script will generate M number of runspaces, one for each host (H_01 all the way to H_m). 
	Each one of those Host runspaces will be responsible for generating and maintaining n number of runspaces (VM_01 all the way to VM_j)
	         H_01        .............         H_m
		  /        \      .............     /        \
		VM_01 ... VM_j   .............   VM_01 ... VM_j 

	Keep in mind, the value of J is going to flucuate between each hypervisor host.
	Host_01 can have 30 VMs and spawn 30 runspaces but Host_03 may have only 24 VMs and will only spawn 24 runspaces.
	The script acknowledges dynamic host usage and will react appropriately.
#>

$Threads_MaxParallel = 50
$Threads_TimeOut = 4260 #71 minutes 
$ObjectRunspaceFunctions = @("invoke-remotedoscommand")
$ObjectRunspaceModules = @()
$ObjectRunspaceSnapins = @()
$ObjectRunspaceScriptBlock = {

	$Obj_Host = New-Object -TypeName PSObject    
	$Obj_Host | Add-Member -MemberType NoteProperty -Name "Host" -Value $_
	$MachinesOnHost = ($using:Machines) | ?{$_.hostingservername -contains $Obj_Host.Host.HostingServername}
	$Obj_Host | Add-Member -MemberType NoteProperty -Name "MachinesOnHost" -Value $MachinesOnHost
	
	$Threads_MaxParallelInner = 10
	$Threads_TimeOutInner = 600 #70 minutes
	$ObjectRunspaceFunctions = @("invoke-remotedoscommand")
	$ObjectRunspaceModules = @()
	$ObjectRunspaceSnapins = @()
	$ObjectRunspaceScriptBlock = {
	
		$Obj_Machine = New-Object -TypeName PSObject    
		$Obj_Machine | Add-Member -MemberType NoteProperty -Name "VM_Name" -Value $_.hostedmachinename
		$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Error" -Value "No error"
		
		if(($_.sessionusername -eq $null)){
				try{
					Start-Sleep -s (Get-Random -minimum 1 -maximum 60)
					$seconds = get-Random -Maximum 600
					Invoke-RemoteDosCommand -DosCommand "Shutdown -r -t $($seconds)" -MachineName $_.hostedmachinename | Out-Null
					$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Status" -Value "VM empty or disconnected and restarted"
				}
				catch{
					$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Error" -Value "Error"
				}
		}elseif(($_.sessionstate -eq "Disconnected")){
			try{
					Start-Sleep -s (Get-Random -minimum 1 -maximum 60)
					$seconds = get-Random -Minimum 1500 -Maximum 2100
					Invoke-RemoteDosCommand -DosCommand "Shutdown -r -t $($seconds)" -MachineName $_.hostedmachinename | Out-Null
					$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Status" -Value "VM empty or disconnected and restarted"
				}
				catch{
					$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Error" -Value "Error"
				}
		}else{
			try{
				Start-Sleep -s (Get-Random -minimum 1 -maximum 60)
				$msg = "As part of our standard weekly maintenance, the desktop you are connected to will reboot in 60 minutes.  Please save your work, close open applications, and log off your desktop. You can then immediately log back on. Thank you."
			   	Invoke-WmiMethod -Path Win32_Process -Name Create -ArgumentList "msg * /time:3600 $msg" -ComputerName $_.HostedMachineName | Out-Null
				
				$seconds = get-Random -Minimum 3600 -Maximum 3900
				Invoke-RemoteDosCommand -DosCommand "Shutdown -r -t $($seconds)" -MachineName $_.hostedmachinename | Out-Null
			}catch{
				$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Error" -Value "VM errored out" -Force
				$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Status" -Value ""
			}
			$Obj_Machine | Add-Member -MemberType NoteProperty -Name "Status" -Value "VM active and restarted"
		}
		
		$Obj_Machine
	}
	
	$MachinesOnHost | Start-RSJob -PSSnapinsToImport $ObjectRunspaceSnapins -FunctionsToLoad $ObjectRunspaceFunctions -ScriptBlock $ObjectRunspaceScriptBlock -Throttle $Threads_MaxParallelInner | Out-Null
	Get-RSJob | Wait-RSJob -ShowProgress -Timeout $Threads_TimeOutInner | Out-Null
	$MachineResults = Get-RSJob -State Completed | Receive-RSJob
	Get-RSJob | Remove-RSJob -Force
	
	$Obj_Host | Add-Member -MemberType NoteProperty -Name "MachineResults" -Value $MachineResults
	$Obj_Host
	
}

$Hosts | Start-RSJob -PSSnapinsToImport $ObjectRunspaceSnapins -FunctionsToLoad $ObjectRunspaceFunctions -ScriptBlock $ObjectRunspaceScriptBlock -Throttle $Threads_MaxParallel | Out-Null
Get-RSJob | Wait-RSJob -ShowProgress -Timeout $Threads_TimeOut | Out-Null
$Results = Get-RSJob -State Completed | Receive-RSJob
Get-RSJob | Remove-RSJob -Force

#endregion

$Elapsed.Stop()

Write-Output "################################################################"
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Complete machine results"
$Results.machineresults | Out-Default

Write-Output "################################################################"
Write-Output "Execution time: $($Elapsed.Elapsed.ToString())" 

Stop-Transcript | Out-Null

Send-MailMessage -from $Var_Sender `
                    -to $Var_recipients`
                    -subject "Reboot Summary - $Var_Site" `
                    -body ("
                        Team,<br /><br />
                       Attached is the reboot summary for $Var_Site.<br /><br />
                        Thanks<br /><br /> 
                                                                                          
                    "  )` -Attachments $TranscriptPath -smtpServer $Var_IntRelay -BodyAsHtml 

  
    
    







