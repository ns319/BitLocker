# script to test connection, check BitLocker status; enable BitLocker and back up RecoveryKey to AD if necessary 

# elevate to admin
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$HostName = Read-Host -Prompt 'Enter hostname'

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
                Write-Host "Something went wrong and BitLocker was not enabled!" -ForegroundColor Red
            } else {
                Write-Host "BitLocker is now enabled for $HostName." -ForegroundColor Green
                Restart-Computer
                if ($? -ne $true) {
                    Write-Host "$HostName did not restart. This computer must restart for encryption to begin!" -ForegroundColor Yellow
                } else {
                    Write-Host "$HostName is restarting to begin encryption."
                }
            }
        }
    }
} else {
    Write-Host "Could not connect to $HostName." -ForegroundColor Yellow
}

Read-Host -Prompt "Press Enter to exit"
