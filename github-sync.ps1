# github-sync.ps1 - push RamWatch data to a private GitHub repo via the GitHub API (no local clone),
# then prune local copies that are already uploaded. Dot-sourced; call Sync-RamWatchData.

$script:Gh = if (Test-Path 'C:\Program Files\GitHub CLI\gh.exe') { 'C:\Program Files\GitHub CLI\gh.exe' } else { (Get-Command gh -EA SilentlyContinue).Source }

function Put-RepoFile([string]$repo, [string]$repoPath, [string]$localPath, [string]$message) {
    $sha = $null
    $existing = & $script:Gh api "repos/$repo/contents/$repoPath" --jq .sha 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) { $sha = $existing.Trim() }
    $body = [ordered]@{ message = $message; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($localPath)) }
    if ($sha) { $body.sha = $sha }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, ($body | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
        & $script:Gh api -X PUT "repos/$repo/contents/$repoPath" --input $tmp --silent 2>$null
        return ($LASTEXITCODE -eq 0)
    } finally { Remove-Item $tmp -Force -EA SilentlyContinue }
}

# state: hashtable with .uploaded (path -> lastWriteTicks)
function Sync-RamWatchData([string]$root, [hashtable]$state) {
    $repo = (Get-Content (Join-Path $root 'github-repo.txt') -EA SilentlyContinue | Select-Object -First 1)
    if (-not $repo) { return 'no repo configured' }
    if (-not $state.uploaded) { $state.uploaded = @{} }
    $files = @(Get-ChildItem (Join-Path $root 'metrics') -File -Filter '*.jsonl' -EA SilentlyContinue) +
             @(Get-ChildItem (Join-Path $root 'reports') -File -EA SilentlyContinue | Where-Object { $_.Name -match '\.(md|snapshot\.json)$' }) +
             @(Get-ChildItem (Join-Path $root 'daily') -File -Filter '*.json' -EA SilentlyContinue) +
             @(Get-ChildItem (Join-Path $root 'drivers') -File -Filter 'latest.csv' -EA SilentlyContinue)
    $ok = 0; $fail = 0
    foreach ($f in $files) {
        $rel = ($f.FullName.Substring($root.Length + 1)) -replace '\\', '/'
        $ticks = "$($f.LastWriteTimeUtc.Ticks)"
        if ($state.uploaded[$rel] -eq $ticks) { continue }
        if (Put-RepoFile $repo $rel $f.FullName "ramwatch: $rel") { $state.uploaded[$rel] = $ticks; $ok++ } else { $fail++ }
    }
    # local retention: only delete what is safely on GitHub
    # (drivers/latest.csv is the baseline for tomorrow's diff, so it is never pruned)
    $cut = @{ metrics = (Get-Date).AddDays(-3); reports = (Get-Date).AddDays(-7); daily = (Get-Date).AddDays(-7); drivers = [datetime]::MinValue }
    foreach ($f in $files) {
        $rel = ($f.FullName.Substring($root.Length + 1)) -replace '\\', '/'
        $dir = $rel.Split('/')[0]
        if ($f.LastWriteTime -lt $cut[$dir] -and $state.uploaded[$rel] -eq "$($f.LastWriteTimeUtc.Ticks)") {
            Remove-Item $f.FullName -Force -EA SilentlyContinue
            $state.uploaded.Remove($rel)
        }
    }
    "uploaded $ok, failed $fail"
}
