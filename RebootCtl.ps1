<#  
.SYNOPSIS  
    A script to run the quiesce and then reboot script against multiple XenApp servers.
.DESCRIPTION  
    This script will run the quiesce and then reboot against multiple XenApp servers. Running it against the number of servers at a time specified by the interval parameter, or 1 at a time by default. The list of servers can either by specified by a text file, or by worker group.
.NOTES  
    File Name      : RebootCtrl.ps1
    Version        : 1.2
    Author         : Jameson Pugh
    Prerequisite   : Citrix PowerShell SDK.
    License        : GPLv3+
    Copyright (C) 2014 Jameson Pugh
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
.LINK
    http://www.citrix.com
.PARAMETER serverList
    Path to a text file containing a list of servers to reboot.
.PARAMETER workerGroup
    A worker group that contains servers to be rebooted.
.PARAMETER interval
    Number of servers to quiesce at a time.
.PARAMETER hostname
    The hostname of a single server to reboot.
.PARAMETER weeklyReboot
    Quiesces and reboots the localhost if it hasn't rebooted in 7 days.
.EXAMPLE
    .\RebootCtrl.ps1

     Description
     -----------
     This will quiesce the local machine and reboot it once all ICA sessions have ended.
.EXAMPLE
    .\RebootCtrl.ps1 -hostname vmxapar01

     Description
     -----------
     This will quiesce vmxapar01 and reboot it once all ICA sessions have ended.
.EXAMPLE
    .\RebootCtrl.ps1 -workerGroup HCI -interval 2

     Description
     -----------
     This will run the quiesce and reboot script against each server in the HCI worker group, two servers at a time.
.EXAMPLE
    .\RebootCtrl.ps1 -serverList hciservers.txt

     Description
     -----------
     This will run the quiesce and reboot script against each server listed in the hciservers.txt file, one server at a time.
.EXAMPLE
    .\RebootCtrl.ps1 -weeklyReboot

     Description
     -----------
     This will run the quiesce and reboot script against the local server if it hasn't been rebooted in 7 days or less.
.EXAMPLE
    .\RebootCtrl.ps1 -force

     Description
     -----------
     This will skip checking on user sessions.
#>

# Define parameters

[cmdletbinding()]
Param(
    [string]$serverList,
    [string]$workerGroup,
    [int]$interval = 1,
    [string]$hostname = (hostname),
    [switch]$weeklyReboot,
    [switch]$force
)

Write-Host "RebootCtrl.ps1 Copyright (C) 2014 Jameson Pugh"
Write-Host "This program comes with ABSOLUTELY NO WARRANTY."
Write-Host "This is free software, and you are welcome to redistribute it"
Write-Host "under certain conditions"
Write-Host ""

If ( ($serverList) -and ($workerGroup) ) { Throw "You must only specify a value for -serverList or -workerGroup, not both." }
If ( ($interval -ne 1) -and (!($serverList) -and !($workerGroup)) ) { Throw "You can't specify an interval without -serverList or -workerGroup." }
If ( ($hostname -ne (hostname)) -and ($weeklyReboot) ) { Throw "weeklyReboot can only run against the localhost. Please, don't specify a hostname." }
If ( ($hostname -ne (hostname)) -and (($serverList) -or ($workerGroup)) ) { Throw "Please, don't specify a hostname with serverList or workerGroup." }

# Initialize jobs and servers arrays
$jobs = @()
$servers = @()

# If it's not already added, add the Citrix.XenApp.Commands cmdlet
if ( (Get-PSSnapin -Name Citrix.XenApp.Commands -ErrorAction SilentlyContinue) -eq $null ) {Add-PSSnapin Citrix.XenApp.Commands}

# If snapin didn't load, exit with an error code
if ( (Get-PSSnapin -Name Citrix.XenApp.Commands -ErrorAction SilentlyContinue) -eq $null ) {Throw "Couldn't load Citrix.XenApp.Commands Snapin."}

$funcQandR = {
    Function QandR {
        Param([string]$target,[switch]$force)
        
        # If it's not already added, add the Citrix.XenApp.Commands cmdlet
        if ( (Get-PSSnapin -Name Citrix.XenApp.Commands -ErrorAction SilentlyContinue) -eq $null ) {Add-PSSnapin Citrix.XenApp.Commands}

        # Get some info about the server
        $CurrentLogonMode = (Get-XAServer -ServerName $target).LogonMode
        $WorkerGroups=Get-XAWorkerGroup -ServerName $target
        $PrimaryWorkerGroup=$WorkerGroups | Where {($_.WorkerGroupName -ne "ALL Farm servers")}
        
        # If the server is in a Worker Group besides ALL Farm Servers, remove it
        if ( $PrimaryWorkerGroup.WorkerGroupName -ne $null ) {
            Write-Host "Removing $target from $PrimaryWorkerGroup worker group."
            Remove-XAWorkerGroupServer $PrimaryWorkerGroup.WorkerGroupName -ServerNames $target
        }
        
        # Disable logons until restart
        Write-Host "Disabling Logons until restart for $target."
        Set-XAServerLogOnMode -ServerName $target -LogOnMode ProhibitNewLogOnsUntilRestart
        
        # Loop until there are no ICA sessions on the server
        Do {
            Start-Sleep -s 5
            $SessionCount = Get-XASession -ServerName $target | Where {$_.Protocol -eq "Ica"} | Where {($_.State -eq "Active") -or ($_.State -eq "Disconnected")} | measure
            Write-Host "There are " $SessionCount.Count " sessions on $target."
        } While ($SessionCount.Count -gt 0)
        
        # If we found a WorkerGroup, add it back
        if ( $PrimaryWorkerGroup.WorkerGroupName -ne $null ) {
            Write-Host "Adding $target to $PrimaryWorkerGroup."
            Add-XAWorkerGroupServer $PrimaryWorkerGroup.WorkerGroupName -ServerNames $target
        }
        
        # Reboot
        Write-Host "Restarting $target."
        Restart-Computer -ComputerName $target -Force
    }
}

# Clear background jobs from this session
foreach ($job in Get-Job) { Remove-Job $job }

if ($weeklyReboot) {
    $wmi = Get-WmiObject -Class Win32_OperatingSystem
    $uptime = (((Get-Date) - ($wmi.ConvertToDateTime($wmi.LastBootUpTime))).Days)
    Write-Host "$hostname has been up for $uptime days."
    if ($uptime -le 7) {
        exit 0
    }
}

if (!($workerGroup) -and !($serverList)) {
    If ($force) {
        Start-Job -Name "SingleQandR" -ScriptBlock { param([string]$target,[switch]$force) QandR -target $target -force } -InitializationScript $funcQandR -ArgumentList($hostname)
    }
    Else {
        Start-Job -Name "SingleQandR" -ScriptBlock { param([string]$target) QandR -target $target } -InitializationScript $funcQandR -ArgumentList($hostname)
    }
    Do {
        Receive-Job SingleQandR
        Start-Sleep -Seconds 2
    } While ((Get-Job SingleQandR).State -eq "Running")
    exit 0
}

if ($workerGroup) {
    # Try to get the list of servers in the given worker group
    Try { $servers = (Get-XAWorkerGroup -WorkerGroupName $workerGroup).ServerNames }
    Catch { Throw { $Error } }
}

if ($serverList) {
    # Try to read in the serverList
    Try { $servers = Get-Content $serverList }
    Catch { Throw { $Error } }
}

# Check to make sure our interval isn't longer than our list
if ($interval -gt $servers.Length) {$interval = $servers.Length}

# Start the initial set of jobs
For ($i = 0; $i -le $interval - 1; $i++) {
    Write-Host $servers[$i]
    If ($force) {
        Start-Job -Name "QandR$i" -ScriptBlock { param([string]$target,[switch]$force) QandR -target $target -force } -InitializationScript $funcQandR -ArgumentList($servers[$i])
    }
    Else {
        Start-Job -Name "QandR$i" -ScriptBlock { param([string]$target) QandR -target $target } -InitializationScript $funcQandR -ArgumentList($servers[$i])
    }
    $jobs += "QandR$i"
}

# As old jobs end, start new ones one by one
For ($i = $interval; $i -le $servers.Length - 1; $i++) {
    Do {
        Foreach ($job in $jobs) {
            Receive-Job -Name $job
            If ((Get-Job -Name $job).State -ne "Running") {$jobEnded = $job}
        }
        Start-Sleep -s 10
    } Until ($jobEnded -ne $null)
    $jobs += "QandR$i"
    $jobs = @($jobs | ? {$_ -ne $jobEnded})
    $jobEnded = $null
    Write-Host $servers[$i]
    If ($force) {
        Start-Job -Name "QandR$i" -ScriptBlock { param([string]$target,[switch]$force) QandR -target $target -force } -InitializationScript $funcQandR -ArgumentList($servers[$i])
    }
    Else {
        Start-Job -Name "QandR$i" -ScriptBlock { param([string]$target) QandR -target $target } -InitializationScript $funcQandR -ArgumentList($servers[$i])
    }
    Write-Host $jobs.Length
}

Do {
    Foreach ($job in $jobs) {
        Receive-Job -Name $job
    }
    Start-Sleep -Seconds 10
} Until ($jobs.Lenght -eq 0)

# Wait until all jobs are finished before continuing
Get-Job | Wait-Job

Exit 0