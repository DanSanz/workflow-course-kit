<#
.SYNOPSIS
Loads the Day 1 backlog of 15 issues into the tracker of the repo in the current folder.

.DESCRIPTION
Routes A and B put the issues into GitHub Issues through the gh command.
It first creates the labels the triage skill expects, if they are missing.
Route C writes the issues into the local markdown tracker at .scratch/backlog/issues.
It works out the stack from the repo. A Python repo has pyproject.toml at its root. A .NET repo has a solution file there.
The script is safe to run twice. It skips an issue whose title already exists, even when that issue is closed.
It runs on Windows PowerShell 5.1 and needs no administrator rights.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File C:\course\kit\load-backlog.ps1 -Route A -DryRun
#>
[CmdletBinding()]
param(
    # Optional. Leave it out and the script uses the stack of your practice repo. Any letter case works.
    [ValidateSet('python', 'dotnet')]
    [string]$Stack,

    [Parameter(Mandatory = $true)]
    [ValidateSet('A', 'B', 'C')]
    [string]$Route,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'


$MaxWidth = 120
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# The two category labels and the five state labels of the triage skill, with their defaults.
$LabelSpecs = @(
    @{ Role = 'bug';             Color = 'd73a4a'; Text = 'Something is not working' },
    @{ Role = 'enhancement';     Color = 'a2eeef'; Text = 'New feature or request' },
    @{ Role = 'needs-triage';    Color = 'fbca04'; Text = 'Maintainer needs to evaluate this issue' },
    @{ Role = 'needs-info';      Color = 'd876e3'; Text = 'Waiting on reporter for more information' },
    @{ Role = 'ready-for-agent'; Color = '0e8a16'; Text = 'Fully specified, ready for an AFK agent' },
    @{ Role = 'ready-for-human'; Color = '1d76db'; Text = 'Requires human implementation' },
    @{ Role = 'wontfix';         Color = 'ffffff'; Text = 'Will not be actioned' }
)

function Hide-Secret([string]$Text) {
    # Masks anything shaped like a GitHub token before the script prints it.
    $Text = $Text -replace 'gh[pousr]_[A-Za-z0-9]{20,}', '<hidden>'
    return ($Text -replace 'github_pat_[A-Za-z0-9_]{20,}', '<hidden>')
}

function Format-Line([string]$Text) {
    $Text = Hide-Secret $Text
    if ($Text.Length -gt $MaxWidth) { $Text = $Text.Substring(0, $MaxWidth - 3) + '...' }
    return $Text
}

function Write-Line([string]$Text) {
    Write-Host (Format-Line $Text)
}

function Stop-Loader([string]$Message) {
    # Prints one clear error line, wrapped at the width limit, then stops with exit code 1.
    $text = Hide-Secret ('ERROR: ' + $Message)
    while ($text.Length -gt $MaxWidth) {
        $cut = $text.LastIndexOf(' ', $MaxWidth - 1)
        if ($cut -lt 20) { $cut = $MaxWidth - 1 }
        [Console]::Error.WriteLine($text.Substring(0, $cut))
        $text = '  ' + $text.Substring($cut).TrimStart()
    }
    [Console]::Error.WriteLine($text)
    exit 1
}

function Invoke-Native {
    # Runs a command and returns its exit code and text, without stopping on stderr output.
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    & $Exe @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add($_.ToString()) }
        else { $out.Add([string]$_) }
    }
    return [pscustomobject]@{
        Code = $LASTEXITCODE
        Out  = ($out -join "`n").Trim()
        Err  = ($err -join "`n").Trim()
    }
}

function ConvertTo-NativeArg([string]$Value) {
    # Windows PowerShell 5.1 drops inner double quotes when it calls an exe, so they are escaped.
    if ($PSVersionTable.PSVersion -lt [version]'7.3') { return ($Value -replace '"', '\"') }
    return $Value
}

function Get-Slug([string]$Title) {
    $slug = ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug -eq '') { $slug = 'issue' }
    return $slug
}

function Get-IssueNumber([string]$Id) {
    if ($Id -notmatch '(\d\d)$') { Stop-Loader "The issue id '$Id' does not end in two digits." }
    return $Matches[1]
}

# 1. The practice repo. The script finds it first and writes nothing until it is sure.
$WrongFolder = 'This folder is not the root of a practice repo. Run this script from the folder of your practice repo.'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-Loader 'git was not found on PATH. Install git or open the terminal the course setup gave you.'
}
$top = Invoke-Native git @('rev-parse', '--show-toplevel')
if ($top.Code -ne 0 -or -not $top.Out) { Stop-Loader $WrongFolder }
$repoRoot = $top.Out -replace '/', '\'
$repoStacks = @()
if (Test-Path -LiteralPath (Join-Path $repoRoot 'pyproject.toml') -PathType Leaf) { $repoStacks += 'python' }
if (@(Get-ChildItem -LiteralPath $repoRoot -File | Where-Object { $_.Extension -in '.sln', '.slnx' }).Count -gt 0) {
    $repoStacks += 'dotnet'
}
if ($repoStacks.Count -eq 0) { Stop-Loader $WrongFolder }
if ($Stack) {
    $Stack = $Stack.ToLowerInvariant()
    if ($repoStacks -notcontains $Stack) {
        Stop-Loader "You named the stack $Stack but this repo is a $($repoStacks -join ' and ') repo. Leave out -Stack or name $($repoStacks -join ' or ')."
    }
} elseif ($repoStacks.Count -eq 1) {
    $Stack = $repoStacks[0]
} else {
    Stop-Loader 'This repo looks like both python and dotnet. Name the stack with -Stack python or -Stack dotnet.'
}

# 2. The issue file.
$DataFile = Join-Path $PSScriptRoot "backlog-$Stack.json"
if (-not (Test-Path -LiteralPath $DataFile -PathType Leaf)) {
    Stop-Loader "There is no issue file at $DataFile. Keep backlog-$Stack.json next to this script."
}
try {
    $data = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $DataFile).Path, $Utf8NoBom) | ConvertFrom-Json
} catch {
    Stop-Loader "The issue file $DataFile is not valid JSON."
}
$issues = @($data.issues | Where-Object { $_ })
if ($issues.Count -eq 0) { Stop-Loader "The issue file $DataFile holds no issues." }
foreach ($issue in $issues) {
    if (-not $issue.id -or -not $issue.title -or -not $issue.body) {
        Stop-Loader "Every issue in $DataFile needs an id, a title and a body."
    }
}
$mode = 'GitHub'
if ($Route -eq 'C') { $mode = 'local markdown' }
$verb = 'created'
if ($DryRun) { $verb = 'would create' }
Write-Line "Backlog loader. Stack $Stack, route $Route, $mode tracker. $($issues.Count) issues in $(Split-Path $DataFile -Leaf)."
if ($DryRun) { Write-Line 'Dry run. Nothing is changed.' }

$created = 0
$skipped = 0

if ($Route -eq 'C') {
    # 3a. The local route writes one file per issue. The first line is the number and title. There is no Status line.
    $issueDir = Join-Path $repoRoot '.scratch\backlog\issues'
    Write-Line "Tracker folder is .scratch\backlog\issues in $(Split-Path $repoRoot -Leaf)."
    $existing = @{}
    if (Test-Path -LiteralPath $issueDir) {
        foreach ($file in Get-ChildItem -LiteralPath $issueDir -Filter '*.md' -File) {
            $first = [System.IO.File]::ReadAllLines($file.FullName, $Utf8NoBom) | Select-Object -First 1
            if ($first -match '^#\s*\d+:\s*(.+?)\s*$') { $existing[$Matches[1]] = $file.Name }
        }
    }
    foreach ($issue in $issues) {
        $nn = Get-IssueNumber $issue.id
        $title = $issue.title.Trim()
        $name = "$nn-$(Get-Slug $title).md"
        $path = Join-Path $issueDir $name
        if ($existing.ContainsKey($title)) {
            $skipped++
            Write-Line "  $nn  skipped, title already in $($existing[$title])"
            continue
        }
        if (Test-Path -LiteralPath $path) {
            $skipped++
            Write-Line "  $nn  skipped, $name exists with another title"
            continue
        }
        if (-not $DryRun) {
            if (-not (Test-Path -LiteralPath $issueDir)) { New-Item -ItemType Directory -Path $issueDir | Out-Null }
            $body = ($issue.body -replace "`r`n", "`n").TrimEnd()
            [System.IO.File]::WriteAllText($path, "# ${nn}: $title`n`n$body`n", $Utf8NoBom)
        }
        $created++
        Write-Line "  $nn  $verb  $name"
    }
} else {
    # 3b. The GitHub routes check first, then add labels, then add issues in file order.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Stop-Loader 'gh was not found on PATH. Routes A and B need the GitHub CLI. Use route C if gh is not available.'
    }
    $login = Invoke-Native gh @('api', 'user', '--jq', '.login')
    if ($login.Code -ne 0 -or -not $login.Out) {
        $why = "$($login.Err) $($login.Out)"
        if ($why -match 'dial tcp|proxyconnect|no such host|error connecting|internet connection|timed? ?out|connection refused|could not resolve|unreachable|actively refused') {
            Stop-Loader 'gh could not reach github.com. Check the network, then run this script again.'
        }
        Stop-Loader 'gh is not signed in to github.com. Run gh auth login, then run this script again.'
    }

    # The target comes from the origin remote. gh on its own may pick the upstream repo, which is public.
    $remote = Invoke-Native git @('remote', 'get-url', 'origin')
    if ($remote.Code -ne 0 -or -not $remote.Out) {
        Stop-Loader 'This repo has no origin remote. Point origin at your own GitHub repo, or use route C.'
    }
    if ($remote.Out -notmatch 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$') {
        # Print the owner and repo name only. The URL can hold a password or a token.
        $named = 'The origin remote'
        if ($remote.Out -match '([^/:@]+)/([^/]+?)(\.git)?/?$') { $named = "The origin remote $($Matches[1])/$($Matches[2])" }
        Stop-Loader "$named is not on github.com. Point origin at your own GitHub repo, or use route C."
    }
    $repo = "$($Matches[1])/$($Matches[2])"
    $view = Invoke-Native gh @('repo', 'view', $repo, '--json', 'nameWithOwner,visibility,hasIssuesEnabled')
    if ($view.Code -ne 0) { Stop-Loader "gh cannot read the repo $repo. $($view.Err)" }
    $info = $view.Out | ConvertFrom-Json
    if ($info.visibility -eq 'PUBLIC') {
        Stop-Loader "The repo $($info.nameWithOwner) is public. Load the backlog into your own private repo only."
    }
    if (-not $info.hasIssuesEnabled) {
        Stop-Loader "Issues are turned off in $($info.nameWithOwner). Turn them on in the repo settings."
    }
    Write-Line "Signed in as $($login.Out). Target repo is $($info.nameWithOwner), which is $($info.visibility.ToLower())."
    Write-Line "Every gh call that reads or writes the repo names it with --repo $repo."
    # A second guard. Any gh call that left out --repo would still land on the origin repo and never on upstream.
    $env:GH_REPO = $repo

    # Label names follow the repo's mapping file when setup has written one.
    $mapFile = Join-Path $repoRoot 'docs\agents\triage-labels.md'
    $mapping = @{}
    if (Test-Path -LiteralPath $mapFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($mapFile, $Utf8NoBom)) {
            if ($line -match '^\|\s*`([a-z-]+)`\s*\|\s*`([^`]+)`\s*\|') { $mapping[$Matches[1]] = $Matches[2] }
        }
    }
    $labelList = Invoke-Native gh @('label', 'list', '--repo', $repo, '--limit', '500', '--json', 'name')
    if ($labelList.Code -ne 0) { Stop-Loader "gh cannot list the labels of $repo. $($labelList.Err)" }
    $haveLabels = @{}
    foreach ($l in ($labelList.Out | ConvertFrom-Json)) { if ($l) { $haveLabels[$l.name.ToLowerInvariant()] = $true } }
    $labelsMade = 0
    $labelsThere = 0
    foreach ($spec in $LabelSpecs) {
        $name = $spec.Role
        if ($mapping.ContainsKey($name)) { $name = $mapping[$name] }
        if ($haveLabels.ContainsKey($name.ToLowerInvariant())) { $labelsThere++; continue }
        if (-not $DryRun) {
            $made = Invoke-Native gh @('label', 'create', (ConvertTo-NativeArg $name), '--repo', $repo,
                '--color', $spec.Color, '--description', (ConvertTo-NativeArg $spec.Text), '--force')
            if ($made.Code -ne 0) { Stop-Loader "gh could not create the label $name. $($made.Err)" }
        }
        $labelsMade++
        Write-Line "  label  $verb  $name"
    }

    $issueList = Invoke-Native gh @('issue', 'list', '--repo', $repo, '--state', 'all', '--limit', '1000',
        '--json', 'number,title,state')
    if ($issueList.Code -ne 0) { Stop-Loader "gh cannot list the issues of $repo. $($issueList.Err)" }
    $haveTitles = @{}
    foreach ($i in ($issueList.Out | ConvertFrom-Json)) { if ($i) { $haveTitles[$i.title.Trim()] = $i } }

    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        foreach ($issue in $issues) {
            $nn = Get-IssueNumber $issue.id
            $title = $issue.title.Trim()
            if ($haveTitles.ContainsKey($title)) {
                $skipped++
                Write-Line "  $nn  skipped, exists as #$($haveTitles[$title].number), $($haveTitles[$title].state.ToLower())  $title"
                continue
            }
            $number = ''
            if (-not $DryRun) {
                [System.IO.File]::WriteAllText($bodyFile, ($issue.body -replace "`r`n", "`n"), $Utf8NoBom)
                $made = Invoke-Native gh @('issue', 'create', '--repo', $repo, '--title', (ConvertTo-NativeArg $title),
                    '--body-file', $bodyFile)
                if ($made.Code -ne 0) {
                    Stop-Loader "gh could not create issue $nn. $created created before it. $($made.Err)"
                }
                if ($made.Out -match '/issues/(\d+)') { $number = "#$($Matches[1])  " }
            }
            $created++
            Write-Line "  $nn  $verb  $number$title"
        }
    } finally {
        Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
    }
    if ($DryRun) {
        Write-Line "Labels: $labelsMade would be created, $labelsThere already there."
    } else {
        Write-Line "Labels: $labelsMade created, $labelsThere already there."
    }
}

if ($Route -ne 'C' -and $created -gt 0 -and -not $DryRun) {
    Write-Line 'GitHub numbers issues and pull requests in one sequence, so a number can differ from the id. Find an issue by its title.'
}
if ($skipped -gt 0) {
    Write-Line 'An issue with the same title counts as existing, even when it is closed. The script never reopens or recreates it.'
}
if ($DryRun) {
    Write-Line "Summary: $created issues would be created, $skipped skipped, $($issues.Count) in the file."
} else {
    Write-Line "Summary: $created issues created, $skipped skipped, $($issues.Count) in the file."
}
exit 0
