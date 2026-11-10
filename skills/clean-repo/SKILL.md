---
name: clean-repo
description: Delete leftover junk files from the working tree and tighten `.gitignore` so it stays out.
disable-model-invocation: true
argument-hint: "[path to repo, default current]"
---

Tidy the files on disk in the current repo (or the path in the arguments): delete **junk** left behind by tools, editors, builds and merges, untrack junk that was committed by mistake, and add `.gitignore` patterns so the same junk can't come back. This is the files, not the history: branches, worktrees and PRs belong to `/clean-git`.

**Junk** is a file nobody wrote on purpose and nothing needs: it is regenerable or accidental. Anything else is **work**, and work is never deleted. When you can't tell which a file is, treat it as work and list it in the report.

## 1. Survey

Read the repo's stack first (manifests, build and CI files, `CLAUDE.md`, the existing `.gitignore`), so you know what its tools generate. Then list the candidates:

```bash
git status --short                          # untracked and modified
git clean -nd                               # untracked, not ignored
git clean -ndX                              # ignored
git ls-files -ci --exclude-standard         # tracked but matching an ignore pattern
git ls-files | xargs -d '\n' du -k 2>/dev/null | sort -rn | head -20   # largest tracked files
find . -path ./.git -prune -o -type d -empty -print                    # empty directories
```

Also look among the tracked files for junk that slipped in: OS files (`.DS_Store`, `Thumbs.db`, `desktop.ini`), editor files (`*.swp`, `*~`, `.idea/`, `*.code-workspace` when personal), merge leftovers (`*.orig`, `*.rej`, `*.BACKUP.*`, `*.LOCAL.*`), logs, temp files, build output, caches, and binaries the build produces.

Done when every untracked file, ignored path and suspicious tracked file has been looked at.

## 2. Classify

Sort every candidate into one of these:

- **Delete:** junk that is untracked or ignored and cheap to regenerate or plainly accidental: OS and editor files, merge leftovers, logs, temp files, stale build output.
- **Untrack:** tracked junk. Remove it with `git rm`; for a file that is local to each machine (personal editor settings, `.env`), use `git rm --cached` so it stays on disk.
- **Keep, ignored:** ignored paths that are deliberate local state: dependencies (`node_modules/`, `.venv/`), caches that are slow to rebuild, `.env` and other local config, data, session backups. They are already tidy: git doesn't see them.
- **Work:** everything else, including untracked source, notes, scripts and anything you can't place. Leave it where it is.

Before calling a tracked file junk, search the repo for its name (`git grep -n <name>`): a file something references is work.

Done when every candidate sits in exactly one group.

## 3. Update `.gitignore`

Add a pattern for every class of junk you found, plus the standard output of the repo's stack that isn't covered yet. Edit the existing file in place: keep its order and comments, add each new pattern under a short comment saying what it catches, and prefer a narrow pattern (`/dist/`, `*.log`) to a broad one. Personal editor and OS files can go in the user's global ignore instead; mention it in the report rather than changing their global config.

Then check that nothing wanted is newly hidden:

```bash
git ls-files -ci --exclude-standard
```

Every path it lists must be one you put in **Untrack**. If a work file appears, narrow the pattern or add a `!` exception.

## 4. Clean

- **Delete:** `rm` each file, `rmdir` each empty directory. Name every path explicitly; a broad `git clean -fdX` also wipes the **Keep, ignored** group.
- **Untrack:** `git rm` / `git rm --cached` as decided in step 2.

## 5. Verify

Run the repo's check, test or build command (from `CLAUDE.md`, the README or the manifests), to prove nothing needed was removed. Then `git status --short`: it should show only `.gitignore` and the `git rm` removals.

Done when the check passes and `git status` shows only the changes from steps 3 and 4. If the check fails because of a removal, restore the file (`git checkout -- <path>` for tracked files) and move it to **Work**.

## 6. Report

Don't commit. Tell the user in a few lines: what you deleted (grouped by kind, with sizes for anything big), what you untracked, the patterns you added to `.gitignore`, and each **Work** file you weren't sure about, so they can decide.
