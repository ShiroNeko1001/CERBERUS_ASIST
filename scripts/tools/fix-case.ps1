<#
.SYNOPSIS
    Normalize CERBERUS_ASIST casing in all project files to lowercase.
.DESCRIPTION
    This script scans all project files and replaces inconsistent case
    variants of "CERBERUS_ASIST" paths/references with consistent lowercase form.
#>
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "..\..\")

$files = Get-ChildItem -Path $ProjectRoot -Recurse -File | Where-Object {
    $_.FullName -notlike '*report.docx' -and
    $_.FullName -notlike '*.tgz' -and
    $_.FullName -notlike '*\.git\*' -and
    $_.FullName -notlike '*.gguf' -and
    $_.FullName -notlike '*.bin'
}

$total = 0
foreach ($f in $files) {
    $s = Get-Content -Raw -LiteralPath $f.FullName
    $orig = $s

    # Fix path casing: UPPERCASE → lowercase for well-known paths
    $s = $s -replace '/opt/CERBERUS_ASIST(?=/|"|$| )', '/opt/cerberus_asist'
    $s = $s -replace '/var/lib/CERBERUS_ASIST(?=/|"|$| )', '/var/lib/cerberus_asist'
    $s = $s -replace '/var/log/CERBERUS_ASIST(?=/|"|$| )', '/var/log/cerberus_asist'
    $s = $s -replace '/etc/CERBERUS_ASIST(?=/|"|$| )', '/etc/cerberus_asist'
    $s = $s -replace 'User=CERBERUS_ASIST', 'User=cerberus_asist'
    $s = $s -replace 'Group=CERBERUS_ASIST', 'Group=cerberus_asist'

    # Fix service name casing
    $s = $s -replace 'CERBERUS_ASIST-llama', 'cerberus_asist-llama'
    $s = $s -replace 'CERBERUS_ASIST-bot', 'cerberus_asist-bot'
    $s = $s -replace 'CERBERUS_ASIST-dashboard', 'cerberus_asist-dashboard'
    $s = $s -replace 'CERBERUS_ASIST-netwatch', 'cerberus_asist-netwatch'

    # Fix base path references (not part of a longer path)
    $s = $s -replace '(?<![\w/])CERBERUS_ASIST(?![\w-])', 'cerberus_asist'

    if ($s -ne $orig) {
        Set-Content -NoNewline -LiteralPath $f.FullName -Value $s
        Write-Host "✓ Fixed: $($f.FullName | Resolve-Path -Relative)" -ForegroundColor Green
        $total++
    }
}

Write-Host "Done. Fixed casing in $total files." -ForegroundColor Cyan