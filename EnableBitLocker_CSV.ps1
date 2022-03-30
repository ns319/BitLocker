# script to import a CSV with computer names, look for Laptops, and check BitLocker status. Enable BitLocker and back up RecoveryKey to AD if necessary. 

# elevate to admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process PowerShell.exe -ArgumentList "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# Import the CSV and store all the data in a variable 
$CSV = Import-Csv C:\Temp\BitLockerTargets.csv 

Foreach ($Computer in $CSV) {
    $HostName = $Computer.Name
    if ($HostName -like "*LTW*") {
        if ((Test-Connection -ComputerName $HostName -Count 1 -Quiet) -eq $true) {
            $RemoteSession = New-PSSession -ComputerName $HostName
            Invoke-Command -Session $RemoteSession -ScriptBlock {
                $HostName = hostname
                if ((Get-BitLockerVolume -MountPoint C:).VolumeStatus -ne "FullyDecrypted") {
                    Write-Host "$HostName is already encrypted."
                } else {
                    Write-Host "$HostName is not encrypted! Enabling BitLocker..." -ForegroundColor Red
                    Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector
                    Enable-BitLocker -MountPoint C: -EncryptionMethod XtsAes128 -UsedSpaceOnly -TpmProtector
                    if ($? -ne $true) {
                        Write-Host "    Something went wrong and BitLocker was not enabled!" -ForegroundColor Red
                    } else {
                        Write-Host "    BitLocker is now enabled for $HostName." -ForegroundColor Green
                        $KeyID = ((Get-BitLockerVolume -MountPoint C:).KeyProtector | Where-Object {$_.KeyProtectorType -eq "RecoveryPassword"}).KeyProtectorID
                        Backup-BitLockerKeyProtector -MountPoint C: -KeyProtectorId $KeyID
                        if ($? -ne $true) {
                            Write-Host "    Something went wrong and the Recovery Key was not backed up to AD." -ForegroundColor Yellow
                        } else {
                            Write-Host "    Recovery Key for $HostName is backed up to AD."
                        }
                        Restart-Computer
                        if ($? -ne $true) {
                            Write-Host "    $HostName did not restart. This computer must restart for encryption to begin!" -ForegroundColor Yellow
                        } else {
                            Write-Host "    $HostName is restarting to begin encryption."
                        }
                    }
                }
            }
        } else {
            Write-Host "Could not connect to $HostName." -ForegroundColor Yellow
        }
    }
}

Read-Host -Prompt "Press Enter to exit"
