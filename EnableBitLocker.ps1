# EnableBitLocker

<#
.SYNOPSIS
    Enable BitLocker on remote host(s), or back up Recovery Key if BitLocker is already enabled
.DESCRIPTION
    Prompt user to enter target
        a. If the target ends with .csv, it is assumed to be a file path and the script will run Import-Csv against that path
        b. If the target contains anything else, this is assumed to be a hostname and the script will try to connect to that host
    Once a target is defined, the script checks if BitLocker is already enabled. If so, it just grabs the Recovery Key ID and sends it to AD. If not, it enables BitLocker and tries to restart
    the remote host. If the computer fails to restart, it's probably because someone is signed in. In that case we check the HostList; if it's a single host, give the option to force a restart.
    If the HostList was imported from a CSV, just skip the ones that fail to reboot so we don't hold up the rest. Add a warning to the output/log indicating the need for a reboot.
    Output is sent to a log in local C:\Temp so we can go back later to try again for failures.
.NOTES
    v2.1.2
#>

# Elevate to admin
if ( -not ( [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() ).IsInRole( [Security.Principal.WindowsBuiltInRole] 'Administrator') ) {
    Start-Process powershell.exe "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Create local log 
function Write-Log
{
    Param ([string]$LogEntry)
    $TimeStamp = Get-Date -Format s
    Add-Content -Path $LocalLog -Value "$TimeStamp,$LogEntry"
}

# Define the Target - input a path to Import-Csv, a Division-level OU, or computername
Write-Host 'To import a CSV, specify the path e.g. C:\Temp\BitLockerTargets.csv'
Write-Host 'To select a specific computer, enter the hostname e.g. DOL01FV-DTWX037'
Write-Host ''
$Target = Read-Host -Prompt 'Enter target'
Clear-Host

# Begin log
$LocalLog = 'C:\Temp\ManageBDELog.csv'
Add-Content -Path $LocalLog -Value '-------------------------,---------,Begin Managing BitLocker ----------------------------------------------'
Write-Host '------------------------- Begin Managing BitLocker -------------------------'

# Translate Target to HostList
if ($Target -like '*.csv') {
    $HostList = Import-Csv -Path "$Target"
    Write-Log "INFO,Importing CSV $Target..."
    Write-Host "INFO - Importing CSV $Target..."
    Write-Host ''
} else {
    $HostList = $Target
    Write-Log "INFO,Running against $Target..."
    Write-Host "INFO - Running against $Target..."
    Write-Host ''
}

# Main routine that runs against each host in HostList
foreach ($Computer in $HostList) {
    # If a single hostname is entered, use it; otherwise get the Name property from the CSV or OU
    if ($HostList -eq $Target) {
        $HostName = $Target
    } else {
        $HostName = $Computer.Name
    }

    Write-Log "--------,--------------------------------------"

    # Try to create a new PSSession on $HostName
    Write-Log "INFO,Create PSSession on $HostName..."
    Write-Host "INFO - Create PSSession on $HostName..." -ForegroundColor Cyan
    Write-Host ''
    $RemoteSession = New-PSSession -ComputerName $HostName
    if ($? -eq $false) {
        Write-Log "ERR!,Could not connect to $HostName."
        Write-Host "ERR! - Could not connect to $HostName" -ForegroundColor Yellow
        Write-Host "------------------------------------------------" -ForegroundColor Cyan
    } else {
        Invoke-Command -Session $RemoteSession -ScriptBlock {
            $HostName = hostname
            # Create a log on the remote host
            $RemoteLog = 'C:\Temp\ManageBDELog.csv'
            # Check to see if the drive is already encrypted; if so, just back up the Recovery Key
            if ( (Get-BitLockerVolume -MountPoint C:).VolumeStatus -ne "FullyDecrypted") {
                $TimeStamp = Get-Date -Format s
                Add-Content -Path $RemoteLog -Value "$TimeStamp,INFO,$HostName is already encrypted. Backing up Recovery Key..."
                Write-Host "INFO - $HostName is already encrypted. Backing up Recovery Key..."
                $KeyID = ( (Get-BitLockerVolume -MountPoint C:).KeyProtector | Where-Object {$_.KeyProtectorType -eq 'RecoveryPassword'} ).KeyProtectorID
                Backup-BitLockerKeyProtector -MountPoint C: -KeyProtectorId $KeyID
                $TimeStamp = Get-Date -Format s
                Add-Content -Path $RemoteLog -Value "$TimeStamp,INFO,Recovery Key for $HostName backed up to AD."
                Write-Host "INFO - Recovery Key for $HostName backed up to AD." -ForegroundColor Green
            } else {
                $TimeStamp = Get-Date -Format s
                Add-Content -Path $RemoteLog -Value "$TimeStamp,INFO,$HostName is not encrypted! Enabling BitLocker..."
                Write-Host "INFO - $HostName is not encrypted! Enabling BitLocker..."
                Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector
                Enable-BitLocker -MountPoint C: -EncryptionMethod XtsAes128 -UsedSpaceOnly -TpmProtector
                if ($? -ne $true) {
                    $TimeStamp = Get-Date -Format s
                    Add-Content $RemoteLog -Value "$TimeStamp,ERR!,Something went wrong and BitLocker was not enabled!"
                    Write-Host "ERR! - Something went wrong and BitLocker was not enabled!" -ForegroundColor Red
                } else {
                    $TimeStamp = Get-Date -Format s
                    Add-Content $RemoteLog -Value "$TimeStamp,INFO,BitLocker is now enabled for $HostName"
                    Write-Host "INFO - BitLocker is now enabled for $HostName." -ForegroundColor Green
                    Restart-Computer
                    # If Restart-Computer fails and we're only running against a single host, give the option to force a reboot
                    # If Restart-Computer fails and we're running against a CSV, just skip it so as not to hold up the rest
                    if ($? -ne $true) {
                        if ($HostName -eq $Using:Target) {
                            $ForceRestart = Read-Host -Prompt "Would you like to force a restart on $HostName ? (Y/N)"
                            switch ($ForceRestart)
                            {
                                Y {
                                    Restart-Computer -Force
                                    $TimeStamp = Get-Date -Format s
                                    Add-Content $RemoteLog -Value "$TimeStamp,INFO,$HostName is restarting to begin encryption."
                                    Write-Host "INFO - $HostName is restarting to begin encryption."
                                }
                                N {
                                    $TimeStamp = Get-Date -Format s
                                    Add-Content $RemoteLog -Value "$TimeStamp,WARN,$HostName needs to restart to begin encryption."
                                    Write-Host 'WARN - Please remember to restart the computer later to begin encryption!' -ForegroundColor Yellow -BackgroundColor Black
                                }
                            }
                        } else {
                            $TimeStamp = Get-Date -Format s
                            Add-Content $RemoteLog -Value "$TimeStamp,WARN,$HostName needs to restart to begin encryption."
                            Write-Host "WARN - $HostName did not restart. Please remember to restart the computer later to begin encryption!" -ForegroundColor Yellow -BackgroundColor Black
                        }
                    } else {
                        $TimeStamp = Get-Date -Format s
                        Add-Content $RemoteLog -Value "$TimeStamp,INFO,$HostName is restarting to begin encryption."
                        Write-Host "INFO - $HostName is restarting to begin encryption."
                    }
                }
            }    
        }
        # Merge the RemoteLog with the LocalLog then close the PSSession we opened
        Get-Content -Path "\\$HostName\C$\Temp\ManageBDELog.csv" | Add-Content $LocalLog
        Get-PSSession | Remove-PSSession
        Write-Host "------------------------------------------------" -ForegroundColor Cyan    
    }
}

# End log
Add-Content -Path $LocalLog -Value '-------------------------,---------,End Managing BitLocker ----------------------------------------------'
Write-Host '------------------------- End Managing BitLocker -------------------------'
Write-Host ''
Write-Host "Review the log at $LocalLog if desired." -ForegroundColor Cyan
Read-Host -Prompt 'Opertation complete. Press Enter to exit'
