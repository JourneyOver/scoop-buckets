Import-Module $(Join-Path $PSScriptRoot "SQLite.psm1")

function Install-PowerShellYaml {
    try {
        Install-Module -Name PowerShell-Yaml -Force -Scope CurrentUser
    } catch {
        Write-Warning "PowerShell-Yaml installation failed: $_"
    }
}

if (-not (Get-Module -ListAvailable -Name PowerShell-Yaml)) {
    Write-Warning "PowerShell-Yaml has not been installed."
    Install-PowerShellYaml | Out-Null
}

function ConvertFrom-YamlString {
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [string]
        $InputObject
    )
    return $InputObject | ConvertFrom-Yaml
}

function ConvertFrom-MSZIP {
    <#
    .SYNOPSIS
      Convert MSZIP format to plain text
    .DESCRIPTION
      This function is used to convert MSZIP format to plain text, which can be commonly seen in WinGet manifest.
    .NOTES
      Decompression errors terminate the loop; partial output may still be returned.
    .PARAMETER buffer
      The buffer to convert.
    .EXAMPLE
      ConvertFrom-MSZIP -buffer $buffer
    #>
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, HelpMessage = "The buffer to convert.")]
        [byte[]]$buffer
    )

    begin {
        # Initialize variables before the loop
        $magicHeader = [byte[]](0, 0, 0x43, 0x4b)
        $decompressed = [System.IO.MemoryStream]::new()
    }

    process {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # Verify the header is in MSZIP format
        if (-not ($buffer[26..29] -join ',') -eq ($magicHeader -join ',')) {
            throw "Invalid MSZIP format"
        }

        # Start searching from the header
        $chunkIndex = 26

        # Create a memory stream from the provided buffer
        $bufferStream = [System.IO.MemoryStream]::new($buffer)

        # Loop: find and decompress each chunk
        while ($chunkIndex -lt $buffer.Length) {
            $chunkIndex += $magicHeader.Length
            $bufferStream.Position = $chunkIndex
            try {
                $decompressedChunk = New-Object System.IO.Compression.DeflateStream($bufferStream, [System.IO.Compression.CompressionMode]::Decompress)
                $decompressedChunk.CopyTo($decompressed)
            } catch {
                break
            }
            $chunkIndex++
        }
    }

    end {
        # Clean up after all input has been processed
        $decompressed.Position = 0
        $reader = [System.IO.StreamReader]::new($decompressed)
        $reader.ReadToEnd()
    }
}

function Get-WinGetDatabase {
    $WorkDir = (New-Item -ItemType Directory -Path $env:TEMP -Name "WinGet_pwsh" -Force).FullName
    # Download the WinGet source package
    $MsixPath = Join-Path $WorkDir "source2.msix"
    Invoke-WebRequest "https://cdn.winget.microsoft.com/cache/source2.msix" -OutFile $MsixPath

    # Extract the WinGet database file
    Expand-Archive -Path $MsixPath -DestinationPath $WorkDir -Force

    # Read the database
    $DBPath = Join-Path $WorkDir "Public\index.db"
    New-SQLiteConnection -Path $DBPath
    $results = Invoke-SQLiteQuery -Query "SELECT CAST ( rowid AS TEXT ) AS rowid, CAST ( id AS TEXT ) AS id, CAST ( name AS TEXT ) AS name, CAST ( moniker AS TEXT ) AS moniker, CAST ( latest_version AS TEXT ) AS latest_version, CAST ( hash AS BLOB ) AS hash FROM packages"
    Close-SQLiteConnection

    # Remove cached files
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    return $results
}

function Get-WinGetInfo {
    param (
        [string] $Id
    )
    # Fetch software info, caching it in a global variable to avoid repeated requests
    if (!$Global:WinGetDB) {
        Write-Warning "WinGet Database has not been loaded yet, loading now..."
        $Global:WinGetDB = Get-WinGetDatabase
    } else {
        Write-Debug "WinGet Database has been loaded already, using cache data..."
    }
    # Fuzzy-match the software ID
    $Info = $Global:WinGetDB | Where-Object { $_.id -like "*$Id*" } | Select-Object -First 1
    if (!$Info) {
        Write-Debug "Cannot find software info for $Id, please check your input."
        throw "Cannot find software info for $Id, please check your input."
    }
    # Got the software version info
    Write-Debug "Got version information: $Info"
    return $Info
}

function Get-WinGetManifest {
    param(
        [string]$Id,
        [PSCustomObject]$Info
    )
    if (!$Info) {
        $Info = Get-WinGetInfo -Id $Id
    }
    write-Debug "Getting manifest for $Info..."
    $Id = $Info.id
    $hexString = [BitConverter]::ToString($Info.hash).Replace("-", "").ToLower().Substring(0, 8)
    $versionDataUrl = "https://cdn.winget.microsoft.com/cache/packages/$Id/$hexString/versionData.mszyml"
    Write-Debug "Requesting for version data..."
    Write-Debug "versionDataUrl: $versionDataUrl"
    $buffer = (Invoke-WebRequest $versionDataUrl).Content
    Write-Debug "Converting version data from MSZIP format..."
    $versionData = (ConvertFrom-MSZIP -buffer $buffer | ConvertFrom-YamlString).vD[0]
    Write-Debug "Got informations:"
    Write-Debug "RelativePath: $($versionData.rP)"
    Write-Debug "Version:      $($versionData.v)"
    $manifestUrl = "https://cdn.winget.microsoft.com/cache/" + $versionData.rP
    Write-Debug "manifestUrl:  $manifestUrl"
    $manifest = Invoke-RestMethod $manifestUrl

    $result = $manifest | ConvertFrom-YamlString
    return $result
}

Export-ModuleMember -Function Get-WinGetInfo, Get-WinGetManifest
