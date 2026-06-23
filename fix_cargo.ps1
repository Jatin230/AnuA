# Script to find and fix duplicate/orphan keys in all non-vendor Cargo.toml files

param([switch]$DryRun)

$libFiles = Get-ChildItem -Path "C:\Users\jatin\Downloads\rustdesk\libs" -Recurse -Filter "Cargo.toml" | 
    Where-Object { $_.FullName -notlike "*\vendor\*" }

$totalFixed = 0

foreach ($file in $libFiles) {
    $lines = Get-Content $file.FullName
    if ($null -eq $lines -or $lines.Count -eq 0) { continue }
    
    $currentSection = ""
    $keysInSection = New-Object System.Collections.Generic.HashSet[string]
    $linesToRemove = New-Object System.Collections.Generic.HashSet[int]
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        
        # Skip comments and blank lines
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        
        # Section header - reset tracking
        if ($trimmed -match '^\[') {
            $currentSection = $trimmed
            $keysInSection.Clear()
            continue
        }
        
        # Key = value line (handle key.subkey = too)
        if ($trimmed -match '^([a-zA-Z0-9_.-]+)\s*=') {
            $key = $matches[1]
            if ($keysInSection.Contains($key)) {
                # This is a duplicate key - mark for removal
                $linesToRemove.Add($i) | Out-Null
                Write-Host "DUPLICATE at $($file.FullName):$($i+1) section=$currentSection key=$key value=$trimmed"
            } else {
                $keysInSection.Add($key) | Out-Null
            }
        }
    }
    
    if ($linesToRemove.Count -gt 0 -and -not $DryRun) {
        $newLines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (-not $linesToRemove.Contains($i)) {
                $newLines.Add($lines[$i])
            }
        }
        [System.IO.File]::WriteAllLines($file.FullName, $newLines)
        $totalFixed++
        Write-Host "  -> Fixed $($linesToRemove.Count) duplicate(s) in $($file.FullName)"
    }
}

Write-Host ""
Write-Host "Total files fixed: $totalFixed"
