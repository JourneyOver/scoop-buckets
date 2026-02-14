param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath)) {
  throw "Input file not found: $InputPath"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')

function Get-AppVersion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AppName
  )

  $manifestPath = Join-Path $repoRoot "bucket\$AppName.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  try {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    return $manifest.version
  } catch {
    return $null
  }
}

function Add-Mismatch {
  param(
    [System.Collections.Generic.List[object]]$Items,
    [Parameter(Mandatory = $true)]
    [string]$App,
    [string]$Url,
    [string]$FirstBytes,
    [string]$Expected,
    [string]$Actual
  )

  if ($null -eq $Items) {
    return
  }

  if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) {
    return
  }

  if ($Expected -eq $Actual) {
    return
  }

  $Items.Add([pscustomobject]@{
      app        = $App
      url        = $Url
      firstBytes = $FirstBytes
      expected   = $Expected
      actual     = $Actual
    })
}

$content = Get-Content -Raw -LiteralPath $InputPath
$rawLines = $content -split "`r?`n"

$lines = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $rawLines.Count; $index++) {
  $line = $rawLines[$index]
  if ($line -match '^(?<app>[A-Za-z0-9._+-]+):\s*$' -and $index + 1 -lt $rawLines.Count) {
    $appName = $Matches.app
    $nextTrimmed = $rawLines[$index + 1].Trim()
    if ($nextTrimmed -match '^(OK|Mismatch found)\b') {
      $lines.Add("${appName}: $nextTrimmed")
      $index++
      continue
    }
  }

  $lines.Add($line)
}

$mismatches = [System.Collections.Generic.List[object]]::new()

for ($index = 0; $index -lt $lines.Count; $index++) {
  $line = $lines[$index].TrimEnd()

  if ($line -match '^(?<app>[A-Za-z0-9._+-]+):\s*Mismatch found\b') {
    $app = $Matches.app
    $url = ''
    $firstBytes = ''
    $expected = ''
    $actual = ''

    for ($cursor = $index + 1; $cursor -lt $lines.Count; $cursor++) {
      $next = $lines[$cursor]

      if ($next -match '^[A-Za-z0-9._+-]+:\s*(OK|Mismatch found)\b') {
        break
      }

      if ($next -match '^\s*URL:\s*(?<value>.+)$') {
        $url = $Matches.value.Trim()
        continue
      }

      if ($next -match '^\s*First bytes:\s*(?<value>.+)$') {
        $firstBytes = $Matches.value.Trim()
        continue
      }

      if ($next -match '^\s*Expected:\s*(?<value>.+)$') {
        $expected = $Matches.value.Trim()
        continue
      }

      if ($next -match '^\s*Actual:\s*(?<value>.+)$') {
        $actual = $Matches.value.Trim()
        continue
      }
    }

    Add-Mismatch -Items $mismatches -App $app -Url $url -FirstBytes $firstBytes -Expected $expected -Actual $actual
    continue
  }

  if ($line -match '^ERROR\s+Hash\s+check\s+failed!?') {
    $app = ''
    $url = ''
    $firstBytes = ''
    $expected = ''
    $actual = ''

    for ($cursor = $index + 1; $cursor -lt $lines.Count; $cursor++) {
      $next = $lines[$cursor].TrimEnd()

      if ($next -match '^\s*App:\s*(?<value>.+)$') {
        $appToken = $Matches.value.Trim()
        if ($appToken -match '.+/(?<app>[A-Za-z0-9._+-]+)$') {
          $app = $Matches.app
        } else {
          $app = $appToken
        }
        continue
      }

      if ($next -match '^\s*URL:\s*(?<value>.+)$') {
        $url = $Matches.value.Trim()
        continue
      }

      if ($next -match '^\s*First\s+bytes:\s*(?<value>.+)$') {
        $firstBytes = $Matches.value.Trim()
        continue
      }

      if ($next -match '^\s*Expected:\s*(?<value>.+)$') {
        $expected = $Matches.value.Trim()
        continue
      }

      if ($next -match '^\s*Actual:\s*(?<value>.+)$') {
        $actual = $Matches.value.Trim()
        break
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($app)) {
      Add-Mismatch -Items $mismatches -App $app -Url $url -FirstBytes $firstBytes -Expected $expected -Actual $actual
    }
  }
}

$issuesByTitle = @{}

foreach ($mismatch in $mismatches) {
  $version = Get-AppVersion -AppName $mismatch.app
  $title = if ([string]::IsNullOrWhiteSpace($version)) {
    "$($mismatch.app): hash check failed"
  } else {
    "$($mismatch.app)@${version}: hash check failed"
  }

  if (-not $issuesByTitle.ContainsKey($title)) {
    $issuesByTitle[$title] = [System.Collections.Generic.List[object]]::new()
  }

  $issuesByTitle[$title].Add($mismatch)
}

$issues = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $issuesByTitle.GetEnumerator()) {
  $title = $entry.Key
  $details = $entry.Value
  $app = $details[0].app

  $blocks = [System.Collections.Generic.List[string]]::new()

  foreach ($detail in $details) {
    $blocks.Add(@"
App: $app
URL: $($detail.url)
First bytes: $($detail.firstBytes)
Expected: $($detail.expected)
Actual: $($detail.actual)
"@.Trim())
  }

  $body = (
    "Hash check failed for one or more URLs.`r`n`r`n" +
    '```text' +
    "`r`n$($blocks -join "`r`n`r`n")`r`n" +
    '```'
  ).Trim()

  $issues.Add([pscustomobject]@{
      title = $title
      body  = $body
    })
}

$issuesArray = $issues.ToArray()
$json = ConvertTo-Json -InputObject $issuesArray -Depth 10
Set-Content -LiteralPath $OutputPath -Encoding utf8 -Value $json
