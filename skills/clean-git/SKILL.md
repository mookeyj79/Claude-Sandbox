---
name: clean-git
description: Merge outstanding PRs, then prune dead worktrees and branches.
disable-model-invocation: true
---

Tidy the current repo: land open PRs, then sweep away what they leave behind. Merge first so the sweep catches the branches the merges just finished.

## 1. Merge outstanding PRs

`git fetch --prune`, then list open PRs with `gh pr list`. For each one, check `gh pr view <n> --json mergeable,mergeStateStatus,isDraft,reviewDecision,statusCheckRollup` and merge it when it is **green**: not a draft, mergeable, checks passing, no changes requested. Merge with `gh pr merge <n> --delete-branch`, using a merge method the repo allows (`gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed`; prefer squash when several are allowed).

A PR that is not green stays open; note why for the report.

Done when every open PR is either merged or has a recorded reason it was left open.

## 2. Prune worktrees

Run `git worktree prune`, then walk `git worktree list`. A worktree is **dead** when its branch is merged into the default branch, its upstream is gone, or its directory no longer exists. Remove dead worktrees with `git worktree remove <path>`.

Keep the worktree this session is running in, and any worktree with uncommitted or unpushed work (`git -C <path> status --porcelain`, `git -C <path> log @{u}..`). Report those instead.

## 3. Prune branches

Switch the main worktree to the default branch and fast-forward it (`git pull --ff-only`). A local branch is **dead** when `git branch --merged <default>` lists it, or its upstream shows `[gone]` in `git branch -vv` and a merged PR exists for it (`gh pr list --state merged --head <branch>`). Delete dead branches with `git branch -d`; use `-D` only for squash-merged branches confirmed by that merged PR.

A branch with commits found nowhere else and no merged PR is live work: keep it and report it.

Done when every local branch other than the default is deleted or listed in the report with a reason.

## 4. Report

One short summary: PRs merged, PRs left open (with reason), worktrees and branches removed, and anything kept that the user may want to look at.
