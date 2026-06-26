<#
.SYNOPSIS
    Rename all project references from CERBERUS_ASIST to a new name.
.PARAMETER NewName
    New project name (e.g., "ANTIGRAFITI")
.PARAMETER NewNameLower
    Lowercase version (e.g., "antigrafiti")
.EXAMPLE
    .\rename-project.ps1 -NewName "ANTIGRAFITI" -NewNameLower "antigrafiti"
#>
param(
    [string]$NewName = "ANTIGRAFITI",
    [string]$NewNameLower = "antigrafiti"
)

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

    # Replace in order: specific first → general last
    $s = $s -replace 'CERBERUS_ASIST', $NewName
    $s = $s -replace 'cerberus_asist', $NewNameLower
    $s = $s -replace 'Cerberus_Asist', ($NewNameLower -replace '(?:^|_)(.)', { $_.Groups[1].Value.ToUpper() + ($_.Value.Substring(1).ToLower()) })

    if ($s -ne $orig) {
        Set-Content -NoNewline -LiteralPath $f.FullName -Value $s
        Write-Host "✓ Updated: $($f.FullName | Resolve-Path -Relative)" -ForegroundColor Green
        $total++
    }
}

Write-Host "Done. Updated $total files from CERBERUS_ASIST → $NewName" -ForegroundColor Cyan
