# Load the Day 1 backlog

The 15 backlog issues for the 15:00 lab do not come with the clone. This script puts them in your tracker.

1. Open PowerShell in the folder of your practice repo. That is the folder that holds `pyproject.toml` for a Python repo or the solution file for a .NET repo. The script stops with a message and writes nothing if it finds neither.
2. Pick your route. It is the one the machine check gave you. The script works out your stack from the repo. You can name it with `-Stack python` or `-Stack dotnet`. If the name does not match the repo, the script stops and writes nothing.
3. Run a dry run first. It prints what the script would do and changes nothing.

```powershell
# Route A
powershell -ExecutionPolicy Bypass -File C:\course\kit\load-backlog.ps1 -Route A -DryRun
# Route B
powershell -ExecutionPolicy Bypass -File C:\course\kit\load-backlog.ps1 -Route B -DryRun
# Route C
powershell -ExecutionPolicy Bypass -File C:\course\kit\load-backlog.ps1 -Route C -DryRun
```

4. Run the same command without `-DryRun`.

On route A or B the script needs `gh`, signed in. It reads the repo from `origin` and passes that repo by name on every `gh` call, so nothing can land on the trainer's public repo, which is your `upstream`. It refuses a public repo.
A new GitHub repo has a set of default labels, among them `wontfix`. It lacks `needs-triage`, `needs-info`, `ready-for-agent` and `ready-for-human`. The setup skill of lab 2 may have made those four. The script creates any of them that is missing. If your repo has a `docs/agents/triage-labels.md` file, the script uses the label names in it.
Then it creates 15 issues.

GitHub gives issues and pull requests one shared run of numbers. A pull request that exists first takes a number, so an issue number can be higher than its file number. The script does not use the numbers. It matches issues by title. In the lab, find an issue by its title and not by its number.
On route C it writes 15 files to `.scratch\backlog\issues` in your repo.

The script is safe to run twice. It skips any issue whose title is already in the tracker. The loader counts a closed issue as present. It never reopens or recreates an issue you closed. To start again, use a fresh repo. The last line gives the count.

Change the path `C:\course\kit` to the folder where your kit is.