function Enable-DevelopmentMode {
    $RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'

    try {
        @{
            AllowAllTrustedApps               = 1
            AllowDevelopmentWithoutDevLicense = 1
        }.GetEnumerator() | ForEach-Object {
            Set-RegValue -Path $RegistryPath -Name $_.Key -Value $_.Value -Type REG_DWORD
        }
    } catch {
        Write-Error "This app requires Development Mode to install. Failed to enable Development Mode. Please reinstall this app. $($_.Exception.Message)"
        exit 1
    }
}

function Import-AppxPSModule {
    if (Get-Module -Name Appx) {
        return
    }

    $ImportParams = @{
        Name        = 'Appx'
        ErrorAction = 'Stop'
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $ImportParams.UseWindowsPowerShell = $true
    }

    Import-Module @ImportParams
}
