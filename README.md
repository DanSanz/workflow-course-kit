# Workflow course kit

This folder is the course kit for the three day AI coding workflow course.
Clone it to `C:\course\kit` when you arrive on Day 1.

```powershell
git clone https://github.com/DanSanz/workflow-course-kit.git C:\course\kit
```

## What it holds

- `day1\` holds the four Day 1 lab guides, two sheets, four short pages and the slides of the day:
  - `d1-lab1-drive-the-agent.html`
  - `d1-lab2-one-command-build.html`
  - `d1-lab3-rules-become-checks.html`
  - `d1-lab4-problem-to-queue.html`
  - `d1-stretch-goals.html`, for when you finish a lab early
  - `d1-between-the-days.html`, for what to do before Day 2
  - `d1-stretch-goals-lab1.html` to `d1-stretch-goals-lab4.html`, which open the stretch goals at one lab, for the links in the slides
  - `d1-slides.pdf`, the slides of Day 1 as one PDF, which show the day's pages as they build up, with what the trainer said under each one
- `skill-*.html` are the skill cards, one page for each skill the labs use.
- `skill-map.html` is the skill map, the 19 skills the course teaches on one page.
- `alt-*.html` are the alternatives cards, one page for each workflow step.
- `watch-list.html` is the watch list.
- `handout.css` is the stylesheet that every page uses. Keep it in this folder.
- `zoom.js` keeps one zoom level for every page. Keep it in this folder.
- `check-machine.ps1` is the machine check you run as you arrive.
- `load-backlog.ps1` loads the backlog for lab 4. `load-backlog.md` says how to run it.
- `backlog-python.json` and `backlog-dotnet.json` hold the backlog issues. Keep them next to the loader.

## Open a lab guide

Open the file in your browser. You can double click it in File Explorer, or run this command:

```powershell
Start-Process C:\course\kit\day1\d1-lab1-drive-the-agent.html
```

Pick your agent and your stack at the top of a lab guide. The page hides the commands you do not need.

## Run the machine check

Run this command in Windows PowerShell when the trainer asks:

```powershell
powershell -ExecutionPolicy Bypass -File C:\course\kit\check-machine.ps1 -AccessTest
```

The check needs `gh`, the GitHub command line tool, signed in to your own account.
With `-AccessTest` it creates a private test repo named `workflow-course-access-test` in your account, pushes to it and opens a pull request in it.
It then tries to delete the repo. Most sign ins lack the permission to delete, so the repo usually stays in place for the day.
Leave it until the trainer says. Then run the `gh repo delete` command that the check printed. If that fails for lack of permission, run `gh auth refresh -h github.com -s delete_repo` once and run the delete again.

If the repo, the push and the pull request all work and GitHub can protect your main branch, the check reports `Route A, own repo with enforced protection`.
If they all work but your GitHub plan does not enforce branch protection on private repos, the check reports `Route B, own repo without enforced protection`.
If you cannot create a repo, the check reports route C and names the step that failed.
If you do not want a test repo in your account, run the command without `-AccessTest`. The check then reports the route as not tested.
In both cases the trainer notes your route.

On the Python stack, if the check says pytest or pyspark is missing, it prints one install line. Run that line once inside your clone of `contributions-pipeline`, after lab 1 and before lab 2.

Near the end of the output is the line that starts `READ OUT TO THE TRAINER`. Read that line to the trainer. It gives your stack, your agent and your route.

If your kit is in another folder, change `C:\course\kit` in each command to that folder.
