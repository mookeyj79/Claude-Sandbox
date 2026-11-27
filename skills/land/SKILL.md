---
name: land
description: Land the current work (commit, open a PR, wait for CI, then merge). Use when the user asks to land a change, or to commit, PR and merge in one go.
---

Land the current work on the default branch: commit, PR, **green** CI, squash-merge, sync. The user asked for all of it, so run straight through without stopping between steps. Stop only when a step goes **red**: a failed check, a conflict, a refused merge.

## 0. Check for open gates

Before step 1, look for work this branch is still waiting on: subagents still running for it (code review, implementers, screenshot runs), or a PR or linked ticket that requires an owner approval nobody has given yet. If there is any, list it and ask once whether to land anyway. This is the one stop before red.

## 1. Commit

Find the default branch (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`). If you're on it, branch off with a short kebab-case name for the change. Read `git status --short` and stage the files that belong to this change. Leave unrelated files unstaged and mention them in the report. Commit with a message in the style of `git log --oneline -5`.

If the default branch moved on (`git fetch`, then `git log HEAD..origin/<default>`), rebase onto it now so CI tests what will land. If this branch was stacked on a PR that has since been squash-merged, rebase only its own commits: `git rebase --onto origin/<default> <old base tip>`.

Done when `git status --short` shows nothing of this change left uncommitted.

## 2. Open the PR

`git push -u origin <branch>`. If the branch already has an open PR (`gh pr view --json number,state`), use that one and go to step 3. Otherwise write the body with the `pr` skill, or as a short summary of what changed and why if it isn't installed, and create the PR with `gh pr create --base <default> --title ... --body-file <file>`.

To edit an existing body, read it with stderr dropped: `gh api repos/<owner>/<repo>/pulls/<n> --jq .body 2>/dev/null`. gh prints a `hint:` block on stderr for any PR call, and a reader that merges stderr into stdout (the REPL's `$`) writes the hint back into the body.

## 3. Wait for CI

If the repo has no `.github/workflows/`, skip to step 4.

Wait for the run on **the commit you pushed**, not the newest run on the branch. Right after a push, `gh pr checks` still shows the previous commit's jobs.

```bash
sha=$(git rev-parse HEAD)
for i in $(seq 24); do [ "$(gh run list --commit "$sha" --json status -q length)" -gt 0 ] && break; sleep 5; done
gh pr checks <n> --watch --interval 15
```

Run it as one Bash call with a 600000 ms timeout. If no run starts within those two minutes, read the workflows' `on:` triggers: path filters can skip a commit entirely, which counts as no CI. A plain `sleep` before it gets blocked. If CI usually takes longer than 10 minutes, run it with `run_in_background` and wait for the notification.

Done when every check has finished. **Green** means all passed. **Red** means anything failed: get the failing lines with `gh run view --job <id> --log-failed`, then fix the problem and go back to step 1, or stop and report it. Never merge red. A cancelled or skipped-by-hand check is not green: rerun it (`gh run rerun <id>`).

## 4. Merge

If a workflow on the default branch deploys to GitHub Pages (`actions/deploy-pages`), check that Pages is on (`gh api repos/<owner>/<repo>/pages`). On a 404, ask the user to turn it on before merging.

`gh pr merge <n> --squash --delete-branch`, or the method the repo history uses if squash isn't allowed (`gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`).

If auto mode's safety check refuses the merge, stop. Tell the user the PR is green and waiting, and that they can approve the exact command with `/permissions` or merge it themselves.

## 5. Sync and report

`git checkout <default> && git pull --ff-only && git fetch --prune`.

Watch the runs the merge commit starts (`gh run list --commit <merge sha>`) until they finish. A failed run goes in the report. A run that opens a follow-up PR (a bot's screenshot or lockfile PR) is part of this landing: wait for it, and land that PR through steps 3 and 4 before reporting.

Report in a few lines: PR link, merge commit, checks that ran (or "no CI"), and anything left unstaged or unverified, such as code CI doesn't exercise.
