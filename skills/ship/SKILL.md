---
name: ship
description: Commit, open a PR, wait for CI, then merge. Use when the user asks to commit, PR and merge in one go, or to ship the current work.
---

Land the current work on the default branch: commit, PR, **green** CI, squash-merge, sync. The user asked for all of it, so run straight through without stopping between steps. Stop only when a step goes **red**: a failed check, a conflict, a refused merge.

## 1. Commit

Find the default branch (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`). If you're on it, branch off with a short kebab-case name for the change. Read `git status --short` and stage the files that belong to this change. Leave unrelated files unstaged and mention them in the report. Commit with a message in the style of `git log --oneline -5`.

If the default branch moved on (`git fetch`, then `git log HEAD..origin/<default>`), rebase onto it now so CI tests what will land.

Done when `git status --short` shows nothing of this change left uncommitted.

## 2. Open the PR

`git push -u origin <branch>`. Write the body with the `pr` skill if it's installed, otherwise a short summary of what changed and why. Create the PR with `gh pr create --base <default> --title ... --body-file <file>`.

## 3. Wait for CI

If the repo has no `.github/workflows/`, skip to step 4.

Wait for the run on **the commit you pushed**, not the newest run on the branch. Right after a push, `gh pr checks` still shows the previous commit's jobs.

```bash
sha=$(git rev-parse HEAD)
until [ "$(gh run list --commit "$sha" --json status -q length)" -gt 0 ]; do sleep 5; done
gh pr checks <n> --watch --interval 15
```

Run it as one Bash call with a 600000 ms timeout. A plain `sleep` before it gets blocked. If CI usually takes longer than 10 minutes, run it with `run_in_background` and wait for the notification.

Done when every check has finished. **Green** means all passed. **Red** means anything failed: get the failing lines with `gh run view --job <id> --log-failed`, then fix the problem and go back to step 1, or stop and report it. Never merge red.

## 4. Merge

`gh pr merge <n> --squash --delete-branch`, or the method the repo history uses if squash isn't allowed (`gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`).

If auto mode's safety check refuses the merge, stop. Tell the user the PR is green and waiting, and that they can approve the exact command with `/permissions` or merge it themselves.

## 5. Sync and report

`git checkout <default> && git pull --ff-only && git fetch --prune`.

Report in a few lines: PR link, merge commit, checks that ran (or "no CI"), and anything left unstaged or unverified, such as code CI doesn't exercise.
