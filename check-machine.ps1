<#
Course machine check. Run it in the first five minutes of Day 1, in Windows PowerShell 5.1.

    powershell -ExecutionPolicy Bypass -File check-machine.ps1
    powershell -ExecutionPolicy Bypass -File check-machine.ps1 -AccessTest
    powershell -ExecutionPolicy Bypass -File check-machine.ps1 -AccessTest -Org my-company-org

It needs no administrator rights and installs nothing. It writes only inside one scratch folder under
%TEMP%, and removes that folder at the end. It never prints a token.

  -AccessTest  Try to create a private repo named workflow-course-access-test, push one commit,
               open a pull request and read whether branch protection can be set. Then print route A, B or C.
  -Org         Create the test repo under this organisation instead of the signed in account.
  -DryRun      Print the commands the access test would run and run none of them.
  -HeadlessSec Time limit in seconds for each headless agent run. The default is 45.
#>
param(
    [switch]$AccessTest,
    [string]$Org = '',
    [switch]$DryRun,
    [int]$HeadlessSec = 45
)

$ErrorActionPreference = 'Continue'
$RepoName = 'workflow-course-access-test'
$Scratch = Join-Path ([IO.Path]::GetTempPath()) ('wfc-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Rows = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- helpers

function Redact([string]$text) {
    if (-not $text) { return '' }
    $t = $text -replace 'gh[pousr]_[A-Za-z0-9_]{10,}', '<hidden>'
    $t = $t -replace 'github_pat_[A-Za-z0-9_]{10,}', '<hidden>'
    $t = $t -replace '(?i)(token|authorization|password)\s*[:=]\s*\S+', '$1 <hidden>'
    return $t
}

function First-Line([string]$text, [int]$max = 70) {
    $line = ((Redact $text) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return '' }
    $line = $line.Trim()
    if ($line.Length -gt $max) { $line = $line.Substring(0, $max - 3) + '...' }
    return $line
}

# Starts a sentence with a capital letter and ends it with a full stop.
function Sentence([string]$t) {
    $t = $t.Trim()
    if (-not $t) { return '' }
    $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1)
    if ($t -notmatch '[.!?]$') { $t += '.' }
    return $t
}

function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    return $a
}

function Find-Exe([string]$name) {
    try {
        $c = Get-Command $name -All -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandType -in 'Application', 'ExternalScript' } | Select-Object -First 1
        if ($c) { return $c.Source }
    } catch { }
    return $null
}

# Runs one program with a time limit. Never throws. Returns Started, TimedOut, Code and Text.
function Run-Cmd([string]$exe, [string[]]$arguments = @(), [int]$timeout = 30, [string]$dir = $null) {
    $result = [pscustomobject]@{ Started = $false; TimedOut = $false; Code = -1; Text = '' }
    try {
        if (-not $dir) { $dir = if (Test-Path $Scratch) { $Scratch } else { [IO.Path]::GetTempPath() } }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $argText = ($arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
        if ($exe -match '\.(cmd|bat)$') {
            $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
            $psi.Arguments = '/d /s /c "' + (Quote-Arg $exe) + ' ' + $argText + '"'
        } elseif ($exe -match '\.ps1$') {
            $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg $exe) + ' ' + $argText
        } else {
            $psi.FileName = $exe
            $psi.Arguments = $argText
        }
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
        $psi.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
        $p = [Diagnostics.Process]::Start($psi)
        $result.Started = $true
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Close()
        if (-not $p.WaitForExit($timeout * 1000)) {
            $result.TimedOut = $true
            & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        } else {
            $p.WaitForExit()
            $result.Code = $p.ExitCode
        }
        $result.Text = [string]$out.Result + "`n" + [string]$err.Result
    } catch {
        $result.Text = $_.Exception.Message
    }
    return $result
}

function Add-Row([string]$area, [string]$name, [string]$state, [string]$detail) {
    [void]$Rows.Add([pscustomobject]@{ Area = $area; Name = $name; State = $state; Detail = $detail })
    Write-Host ('  {0,-17} {1,-13} {2}' -f $name, $state, $detail)
}

# Runs a check and turns any error into "could not check".
function Safe-Check([string]$area, [string]$name, [scriptblock]$body) {
    try {
        $r = & $body
        Add-Row $area $name $r.State $r.Detail
        return $r
    } catch {
        $r = [pscustomobject]@{ State = 'could not check'; Detail = (First-Line $_.Exception.Message 50) }
        Add-Row $area $name $r.State $r.Detail
        return $r
    }
}

function New-Result([string]$state, [string]$detail, $extra = $null) {
    return [pscustomobject]@{ State = $state; Detail = $detail; Extra = $extra }
}

# ---------------------------------------------------------------- tool checks

function Check-Git {
    $exe = Find-Exe 'git'
    if (-not $exe) { return New-Result 'missing' '' }
    $r = Run-Cmd $exe @('--version') 15
    if ($r.Text -match 'git version (\S+)') { return New-Result 'found' $Matches[1] }
    return New-Result 'could not check' 'git did not report a version'
}

function Check-Python {
    $cands = New-Object System.Collections.ArrayList
    $py = Find-Exe 'py'
    if ($py) { [void]$cands.Add(@{ Exe = $py; Args = @('-3.12', '--version'); Label = 'py launcher' }) }
    foreach ($n in 'python', 'python3') {
        try {
            Get-Command $n -All -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandType -eq 'Application' } |
                ForEach-Object { [void]$cands.Add(@{ Exe = $_.Source; Args = @('--version'); Label = $_.Source }) }
        } catch { }
    }
    if ($cands.Count -eq 0) { return New-Result 'missing' '' }
    $other = $null
    $aliasOnly = $false
    foreach ($c in $cands) {
        $r = Run-Cmd $c.Exe $c.Args 15
        if ($r.Text -match 'Python (3\.(\d+)\.\d+\S*)') {
            if ([int]$Matches[2] -eq 12) { return New-Result 'found' $Matches[1] }
            if (-not $other) { $other = $Matches[1] }
        } elseif ($c.Exe -match 'WindowsApps') {
            $aliasOnly = $true
        }
    }
    if ($other) { return New-Result 'partial' ("Python $other found, 3.12 needed") }
    if ($aliasOnly) { return New-Result 'missing' 'only the Microsoft Store alias' }
    return New-Result 'missing' ''
}

function Get-JavaExe {
    $exe = Find-Exe 'java'
    if ($exe) { return $exe }
    if ($env:JAVA_HOME) {
        $j = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path $j) { return $j }
    }
    return $null
}

function Check-Java {
    $exe = Get-JavaExe
    if (-not $exe) { return New-Result 'missing' '' }
    $r = Run-Cmd $exe @('-version') 20
    if ($r.Text -notmatch 'version "(\d+)(?:\.(\d+))?([^"]*)"') { return New-Result 'could not check' 'java did not report a version' }
    $major = [int]$Matches[1]
    $full = $Matches[0] -replace 'version "', '' -replace '"', ''
    if ($major -eq 1 -and $Matches[2]) { $major = [int]$Matches[2] }
    if ($major -ne 17) { return New-Result 'partial' ("Java $full found, 17 needed") }
    $home17 = $false
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) { $home17 = $true }
    if (-not $env:JAVA_HOME) { return New-Result 'partial' "Java $full found, JAVA_HOME not set" }
    if (-not $home17) { return New-Result 'partial' "Java $full found, JAVA_HOME points nowhere" }
    $r2 = Run-Cmd (Join-Path $env:JAVA_HOME 'bin\java.exe') @('-version') 20
    if ($r2.Text -match 'version "(\d+)(?:\.(\d+))?') {
        $m2 = [int]$Matches[1]
        if ($m2 -eq 1 -and $Matches[2]) { $m2 = [int]$Matches[2] }
        if ($m2 -ne 17) { return New-Result 'partial' "Java $full found, JAVA_HOME is Java $m2" }
    }
    return New-Result 'found' "$full with JAVA_HOME"
}

function Check-Dotnet {
    $exe = Find-Exe 'dotnet'
    if (-not $exe) { return New-Result 'missing' '' }
    $r = Run-Cmd $exe @('--list-sdks') 30
    if ($r.TimedOut) { return New-Result 'could not check' 'dotnet did not answer in time' }
    $sdks = @($r.Text -split "`r?`n" | Where-Object { $_ -match '^\s*(\d+)\.(\d+)\.(\d+)\S*\s+\[' } | ForEach-Object { ($_ -split '\s+' | Where-Object { $_ })[0] })
    $ten = @($sdks | Where-Object { $_ -match '^10\.' })
    if ($ten.Count -gt 0) { return New-Result 'found' ("SDK " + $ten[-1]) }
    if ($sdks.Count -gt 0) { return New-Result 'partial' ("SDK " + $sdks[-1] + " found, 10 needed") }
    $rt = Run-Cmd $exe @('--list-runtimes') 30
    if ($rt.Text -match 'Microsoft\.NETCore\.App') { return New-Result 'missing' 'runtime only, no SDK' }
    return New-Result 'missing' 'no SDK'
}

function Check-Gh {
    $exe = Find-Exe 'gh'
    if (-not $exe) { return New-Result 'missing' '' }
    $v = Run-Cmd $exe @('--version') 15
    $ver = ''
    if ($v.Text -match 'gh version (\S+)') { $ver = $Matches[1] }
    $a = Run-Cmd $exe @('auth', 'status', '--hostname', 'github.com') 25
    if ($a.TimedOut) { return New-Result 'could not check' "gh $ver, sign in check timed out" }
    if ($a.Code -eq 0) {
        $who = Run-Cmd $exe @('api', 'user', '--jq', '.login') 25
        $name = ($who.Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($who.Code -eq 0 -and $name -match '^[A-Za-z0-9-]+$') { return New-Result 'found' "$ver, signed in as $name" $name }
    }
    if ($a.Code -eq 0) { return New-Result 'found' "$ver, signed in" }
    return New-Result 'partial' "$ver, not signed in"
}

function Check-PowerShell {
    $win = $null
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $win = $PSVersionTable.PSVersion.ToString() }
    else {
        $w = Run-Cmd "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') 20
        if ($w.Text -match '(\d+\.\d+(?:\.\d+)*)') { $win = $Matches[1] }
    }
    $core = $null
    $exe = Find-Exe 'pwsh'
    if ($exe) {
        $c = Run-Cmd $exe @('--version') 20
        if ($c.Text -match 'PowerShell (\d+\.\d+\.\d+)') { $core = $Matches[1] }
    }
    $parts = @()
    $parts += $(if ($win) { "Windows PowerShell $win" } else { 'Windows PowerShell unknown' })
    $parts += $(if ($core) { "PowerShell $core" } else { 'no PowerShell 7' })
    return New-Result 'found' ($parts -join ', ') $core
}

# Looks for the Python repo's test packages. Installs nothing.
function Check-PyPackages {
    $exe = Find-Exe 'python'
    if (-not $exe) { return New-Result 'could not check' 'python not on PATH' }
    $r = Run-Cmd $exe @('-c', 'import pytest, pyspark') 60
    if ($r.Code -eq 0) { return New-Result 'found' 'pytest and pyspark' }
    return New-Result 'missing' 'pytest or pyspark'
}

# ---------------------------------------------------------------- agent checks

function Check-Claude {
    $exe = Find-Exe 'claude'
    if (-not $exe) { return New-Result 'missing' '' }
    $v = Run-Cmd $exe @('--version') 20
    $ver = if ($v.Text -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { 'version unknown' }
    # The switch does not stop Claude Code writing one small session log file in the learner's Claude Code folder.
    $r = Run-Cmd $exe @('-p', 'Reply with the single word ready.', '--no-session-persistence') $HeadlessSec
    if ($r.TimedOut) { return New-Result 'no answer' "$ver, headless run timed out after $HeadlessSec s" }
    if ($r.Code -eq 0 -and $r.Text.Trim().Length -gt 0) { return New-Result 'answers' "$ver, headless run answered" }
    $why = First-Line $r.Text 40
    return New-Result 'no answer' ("$ver, headless run failed" + $(if ($why) { ": $why" } else { '' }))
}

function Check-Copilot {
    $exe = Find-Exe 'copilot'
    if (-not $exe) { return New-Result 'missing' '' }
    $v = Run-Cmd $exe @('--version') 30
    if ($v.Text -notmatch '(\d+\.\d+\.\d+)') { $v = Run-Cmd $exe @('--version') 30 }
    $ver = if ($v.Text -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { 'version unknown' }
    $r = Run-Cmd $exe @('-p', 'Reply with the single word ready.') $HeadlessSec
    if ($r.TimedOut) { return New-Result 'no answer' "$ver, headless run timed out after $HeadlessSec s" }
    if ($r.Code -eq 0 -and $r.Text.Trim().Length -gt 0) { return New-Result 'answers' "$ver, headless run answered" }
    $why = First-Line $r.Text 40
    return New-Result 'no answer' ("$ver, headless run failed" + $(if ($why) { ": $why" } else { '' }))
}

function Find-Code {
    $c = Find-Exe 'code'
    if ($c) { return $c }
    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Check-Vscode {
    $exe = Find-Code
    if (-not $exe) { return New-Result 'missing' '' }
    $v = Run-Cmd $exe @('--version') 40
    $ver = if ($v.Text -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { 'version unknown' }
    $e = Run-Cmd $exe @('--list-extensions') 40
    if ($e.TimedOut) { return New-Result 'could not check' "$ver, extension list timed out" }
    if ($e.Text -match '(?im)^github\.copilot-chat\s*$') { return New-Result 'found' "$ver, Copilot Chat installed" }
    return New-Result 'partial' "$ver, Copilot Chat not installed"
}

# ---------------------------------------------------------------- access test

# In a dry run the command is printed and nothing runs. Otherwise it runs with a time limit.
function Step-Run([string]$exe, [string[]]$arguments, [int]$timeout = 60, [string]$dir = $null) {
    if ($DryRun) {
        $line = "  would run: " + [IO.Path]::GetFileNameWithoutExtension($exe)
        foreach ($a in $arguments) {
            $q = Quote-Arg $a
            if (($line.Length + 1 + $q.Length) -gt 118) { Write-Host ($line + ' `'); $line = '      ' + $q }
            else { $line = $line + ' ' + $q }
        }
        Write-Host $line
        return [pscustomobject]@{ Started = $true; TimedOut = $false; Code = 0; Text = '' }
    }
    return Run-Cmd $exe $arguments $timeout $dir
}

function Invoke-AccessTest {
    $res = [pscustomobject]@{ Route = 'C'; Failed = ''; Reason = ''; Owner = ''; Cleanup = ''; CleanupNote = ''; CleanupCmd = ''; CleanupPre = ''; Tested = $true }
    $gh = Find-Exe 'gh'
    $git = Find-Exe 'git'
    if (-not $git) { $res.Failed = 'create the repo'; $res.Reason = 'Git is missing'; return $res }
    if (-not $gh) { $res.Failed = 'create the repo'; $res.Reason = 'the GitHub CLI is missing'; return $res }

    # Who owns the repo
    $owner = $Org
    if (-not $owner) {
        if ($DryRun) { $owner = '<your-account>'; Write-Host '  would run: gh api user --jq .login' }
        else {
            $u = Run-Cmd $gh @('api', 'user', '--jq', '.login') 25
            if ($u.Code -eq 0 -and $u.Text.Trim()) { $owner = ($u.Text -split "`r?`n")[0].Trim() }
        }
    }
    if (-not $owner) { $res.Failed = 'create the repo'; $res.Reason = 'the GitHub CLI is not signed in'; return $res }
    $res.Owner = $owner
    $full = "$owner/$RepoName"
    Write-Host "  test repo: $full"

    $created = $false
    # Step 1: does the name already exist
    if (-not $DryRun) {
        $ex = Run-Cmd $gh @('repo', 'view', $full, '--json', 'name') 25
        if ($ex.Code -eq 0) {
            $res.Route = '?'; $res.Tested = $false
            $res.Failed = 'create the repo'
            $res.Reason = 'a repo with this name already exists from an earlier run'
            $res.CleanupNote = 'If you have the route from your first run, use it. Leave the test repo for now. To delete it later, run:'
            $res.CleanupCmd = "gh repo delete $full --yes"
            return $res
        }
    }

    # Step 1: create the repo
    $c = Step-Run $gh @('repo', 'create', $full, '--private', '--description', 'Course access test. Safe to delete.') 60
    if ($c.Code -ne 0 -or $c.TimedOut) {
        $res.Failed = 'create the repo'
        $res.Reason = if ($c.TimedOut) { 'timed out' } else { First-Line $c.Text 60 }
        return $res
    }
    $created = $true

    try {
        # Step 2: push one commit
        $work = Join-Path $Scratch 'repo'
        if (-not $DryRun) { New-Item -ItemType Directory -Force $work | Out-Null }
        $idArgs = @()
        if (-not $DryRun) {
            $em = Run-Cmd $git @('config', 'user.email') 15
            $nm = Run-Cmd $git @('config', 'user.name') 15
            if (-not $em.Text.Trim() -or -not $nm.Text.Trim()) { $idArgs = @('-c', 'user.name=Course check', '-c', 'user.email=course-check@users.noreply.github.com') }
        }
        $r = Step-Run $git @('init', '-q') 30 $work
        if ($r.Code -eq 0) { $r = Step-Run $git @('symbolic-ref', 'HEAD', 'refs/heads/main') 15 $work }
        if (-not $DryRun) { Set-Content -Path (Join-Path $work 'README.md') -Value 'Access test. Safe to delete.' -Encoding ASCII }
        if ($r.Code -eq 0) { $r = Step-Run $git @('add', 'README.md') 15 $work }
        if ($r.Code -eq 0) { $r = Step-Run $git ($idArgs + @('commit', '-q', '-m', 'Access test commit')) 30 $work }
        if ($r.Code -eq 0) { $r = Step-Run $git @('remote', 'add', 'origin', "https://github.com/$full.git") 15 $work }
        $helper = @('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential')
        if ($r.Code -eq 0) { $r = Step-Run $git ($helper + @('push', '-q', '-u', 'origin', 'main')) 90 $work }
        if ($r.Code -ne 0 -or $r.TimedOut) {
            $res.Failed = 'push a commit'
            $res.Reason = if ($r.TimedOut) { 'timed out' } else { First-Line $r.Text 60 }
            return $res
        }

        # Step 3: open a pull request from a branch
        $r = Step-Run $git @('checkout', '-q', '-b', 'access-test-branch') 15 $work
        if (-not $DryRun) { Add-Content -Path (Join-Path $work 'README.md') -Value 'Second line.' -Encoding ASCII }
        if ($r.Code -eq 0) { $r = Step-Run $git ($idArgs + @('commit', '-q', '-a', '-m', 'Access test branch commit')) 30 $work }
        if ($r.Code -eq 0) { $r = Step-Run $git ($helper + @('push', '-q', '-u', 'origin', 'access-test-branch')) 90 $work }
        if ($r.Code -eq 0) { $r = Step-Run $gh @('pr', 'create', '--repo', $full, '--base', 'main', '--head', 'access-test-branch', '--title', 'Access test', '--body', 'Course access test. Safe to close.') 60 $work }
        if ($r.Code -ne 0 -or $r.TimedOut) {
            $res.Failed = 'open a pull request'
            $res.Reason = if ($r.TimedOut) { 'timed out' } else { First-Line $r.Text 60 }
            return $res
        }

        # Step 4: read whether branch protection can be set. This only reads. It sets nothing.
        $p = Step-Run $gh @('api', "repos/$full/branches/main/protection") 40
        $ptext = $p.Text
        if ($DryRun) {
            $res.Route = '?'; $res.Tested = $false
            return $res
        }
        if ($p.Code -eq 0 -or $ptext -match 'Branch not protected') {
            $res.Route = 'A'
            $res.Reason = 'branch protection can be set on the test repo'
        } elseif ($ptext -match 'Upgrade to GitHub') {
            $res.Route = 'B'
            $res.Reason = 'the plan does not enforce branch protection on private repos'
        } else {
            $res.Route = '?'; $res.Tested = $false
            $res.Failed = 'read branch protection'
            $res.Reason = 'GitHub answered: ' + (First-Line $ptext 60)
        }
        return $res
    } finally {
        # Step 5: delete the test repo
        if ($created) {
            $d = Step-Run $gh @('repo', 'delete', $full, '--yes') 60
            if ($d.Code -ne 0 -or $d.TimedOut) {
                $res.CleanupNote = 'Test repo left in place. The trainer will say when to delete it. To delete it later, run:'
                $res.CleanupCmd = "gh repo delete $full --yes"
            } else {
                $res.Cleanup = if ($DryRun) { 'would delete the test repo' } else { 'test repo deleted' }
            }
        }
    }
}

# ---------------------------------------------------------------- main

$summary = ''
try {
    New-Item -ItemType Directory -Force $Scratch | Out-Null
    Write-Host ''
    Write-Host ('Course machine check   ' + (Get-Date -Format 'dd MMM yyyy HH:mm') + '   ' + $env:COMPUTERNAME)
    Write-Host ''
    Write-Host 'TOOLS'
    $rGit = Safe-Check 'tools' 'Git' { Check-Git }
    $rPy = Safe-Check 'tools' 'Python 3.12' { Check-Python }
    $rJava = Safe-Check 'tools' 'Java 17' { Check-Java }
    $rNet = Safe-Check 'tools' '.NET 10 SDK' { Check-Dotnet }
    $rGh = Safe-Check 'tools' 'GitHub CLI' { Check-Gh }
    $rPs = Safe-Check 'tools' 'PowerShell' { Check-PowerShell }

    $pyOk = ($rPy.State -eq 'found' -and $rJava.State -eq 'found')
    $netOk = ($rNet.State -eq 'found')
    $stack = if ($pyOk -and $netOk) { 'both' } elseif ($pyOk) { 'Python' } elseif ($netOk) { '.NET' } else { 'none' }
    $why = ''
    if ($stack -eq 'none') {
        $bits = @()
        if ($rPy.State -ne 'found') { $bits += 'Python 3.12 ' + $rPy.State }
        if ($rJava.State -ne 'found') { $bits += 'Java 17 ' + $rJava.State }
        $why = ': ' + ($bits -join ', ') + ', and no .NET 10 SDK'
    }
    Write-Host ''
    Write-Host ('STACK  ' + $stack + $why)
    if ($stack -eq 'Python' -or $stack -eq 'both') {
        $rPkg = Safe-Check 'tools' 'Python packages' { Check-PyPackages }
        if ($rPkg.State -ne 'found') {
            Write-Host '  Once you have cloned contributions-pipeline, run this line inside that clone:'
            Write-Host '    python -m pip install --user -r requirements-dev.txt'
        }
    }

    Write-Host ''
    Write-Host 'AGENT'
    $rClaude = Safe-Check 'agent' 'Claude Code' { Check-Claude }
    $rCop = Safe-Check 'agent' 'Copilot CLI' { Check-Copilot }
    $rCode = Safe-Check 'agent' 'VS Code' { Check-Vscode }

    $agents = @()
    if ($rClaude.State -eq 'answers') { $agents += 'Claude Code' }
    if ($rCop.State -eq 'answers') { $agents += 'Copilot CLI' }
    $agent = if ($agents.Count -gt 0) { $agents -join ' and ' }
             elseif ($rCode.State -eq 'found') { 'Copilot Chat in VS Code only' }
             else { 'none' }

    $psCore = $false
    if ($rPs.Extra -and [int](([string]$rPs.Extra) -split '\.')[0] -ge 6) { $psCore = $true }
    if ($PSVersionTable.PSEdition -eq 'Core') { $psCore = $true }
    if ($agent -eq 'Copilot CLI' -and -not $psCore) {
        Write-Host '  Copilot CLI is the only agent and no PowerShell 6 or higher was found. Tell the trainer.'
    }

    $route = 'not tested'
    Write-Host ''
    if ($AccessTest -or $DryRun) {
        Write-Host $(if ($DryRun) { 'ROUTE   dry run, nothing is executed' } else { 'ROUTE   access test' })
        $a = $null
        try { $a = Invoke-AccessTest } catch {
            $a = [pscustomobject]@{ Route = '?'; Failed = 'the test itself'; Reason = (First-Line $_.Exception.Message 60); Owner = ''; Cleanup = ''; CleanupNote = ''; CleanupCmd = ''; CleanupPre = ''; Tested = $false }
        }
        if ($a.Tested -and $a.Route -eq 'A') { $route = 'A' }
        elseif ($a.Tested -and $a.Route -eq 'B') { $route = 'B' }
        elseif ($a.Tested -and $a.Route -eq 'C') { $route = 'C' }
        else { $route = 'not decided' }
        $names = @{ A = 'A, own repo with enforced protection'; B = 'B, own repo without enforced protection'; C = 'C, local only' }
        if ($a.Tested) { Write-Host ('  Route ' + $names[$route]) }
        elseif (-not $DryRun) { Write-Host '  No route decided. Set up as on route C for now. The trainer settles the route in the break.' }
        if ($a.Failed) { Write-Host ('  Step that failed: ' + $a.Failed + '. ' + (Sentence $a.Reason)) }
        elseif ($a.Reason) { Write-Host ('  ' + (Sentence $a.Reason)) }
        if ($a.Cleanup -and -not $DryRun) { Write-Host ('  Cleanup: ' + $a.Cleanup) }
        if ($a.CleanupNote) { Write-Host ('  ' + $a.CleanupNote) }
        if ($a.CleanupCmd) { Write-Host ('    ' + $a.CleanupCmd) }
    } else {
        Write-Host 'ROUTE   not tested. Add -AccessTest to test it.'
    }

    $summary = "stack $stack, agent $agent, route $route"
} catch {
    Write-Host ('The check stopped early: ' + (First-Line $_.Exception.Message 70))
    if (-not $summary) { $summary = 'check incomplete, tell the trainer what is on screen' }
} finally {
    try { if (Test-Path $Scratch) { Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
Write-Host ''
Write-Host "READ OUT TO THE TRAINER:  $summary"
Write-Host ''
exit 0
