---
name: create-human-guide
description: Write a step-by-step guide, with copy-paste commands, for the open `ready-for-human` issues: the tasks an agent can't do and you have to do yourself.
disable-model-invocation: true
argument-hint: "[output path, default human-guide.md] [issue numbers to limit to]"
---

Issues labelled `ready-for-human` (the human-implementation label in `docs/agents/triage-labels.md`, if the repo has it) are the tasks an agent can't finish alone: they need the host machine, a login or secret, a browser, or a human decision. They pile up because each one means rereading the issue and working out the commands. This skill does that work up front, so the user can clear the whole pile in one sitting.

Write one guide covering every open `ready-for-human` issue. The reader works top to bottom, pasting commands as they go, and finishes with every issue done and closed. They should never have to look anything up, guess a value, or work out where to run a command.

Write the guide to the path in the arguments, or `human-guide.md` at the repo root. If the arguments name issue numbers, cover only those. Leave the issues and the repo otherwise untouched: you write the guide; the human does the tasks.

## 1. Gather the issues

```bash
gh issue list --label ready-for-human --state open --limit 200 \
  --json number,title,body,labels,comments,url
```

If none come back, tell the user and stop. For each issue also fetch its open blockers (`docs/agents/issue-tracker.md` has the command; otherwise `gh issue view <n> --json blockedBy`) and read any issues, PRs, files or docs it links to.

Done when you hold every issue's body, comments, blockers and linked material.

## 2. Resolve each task to exact actions

For each issue, work out precisely what the human must do and why it needs a human (a host-only command, a login, a secret, a browser click, a judgement call). Then do the **legwork** so every command is ready to paste:

- **Check every command against the source of truth**: the repo's scripts and docs, `--help` output, the tool's reference docs in the repo (e.g. `docs/sbx-cli.md`). Use only commands and flags you have confirmed exist.
- **Fill in every value you can find**: repo owner/name (`gh repo view --json nameWithOwner`), default branch, file paths, sandbox name (`$SANDBOX_NAME`), version numbers. A value only the human can know (a secret, a personal choice) stays a `<placeholder>`, with one line saying where to get it.
- **Name where each command runs**: host terminal (and which shell, when Windows and Unix commands differ), inside the sandbox, Claude Code prompt, or browser (give the exact URL and what to click).
- **Find the check that proves it worked**: a command with its expected output, or what the human should see.

Note anything you can't resolve from the issue or repo as an open question for that task.

Done when every task has concrete actions, each command is confirmed, and every placeholder left is one only the human can fill.

## 3. Order the work

Put blockers before what they block. Then group tasks that share setup (same tool, same login, same host shell) so the human does each setup once. Put the quickest independent tasks early so progress is visible.

## 4. Write the guide

Use this shape:

```markdown
# Human tasks: <repo> (<date>)

<N> tasks, about <total> minutes. Work top to bottom.

## Before you start
<every tool, login and access the tasks need, each with a check command; the setup shared across tasks, done once>

## Checklist
- [ ] 1. <title> (#<n>, ~<minutes> min)
...

## 1. <title> (#<n>)
**Why:** <one line on what this achieves>
**Where:** <host terminal / sandbox / browser>
**Time:** ~<minutes> min · **Needs:** <earlier task numbers, or nothing>

1. <imperative step>
   ```bash
   <command, ready to paste>
   ```
2. ...

**Check it worked:** <command and expected output>
**Close it:** `gh issue close <n> --comment "<what was done>"`
**If it fails:** <the likely failure and its fix, when the issue or docs name one>
```

Rules for every step:

- One action per numbered step; one code block per place the command runs.
- Commands are complete and copy-pasteable: real values filled in, `<placeholders>` only where the human must supply something, multi-line commands that paste as one block.
- Fence each block with its shell (`bash`, `powershell`); give both when the task runs on a host whose OS you don't know.
- Link the issue (`#<n>` with its URL) so the human can read the full discussion.
- List a task's open questions at its top, so the human sees them before starting.

## 5. Check the guide

Read the guide as the human would, top to bottom:

- Every open `ready-for-human` issue in scope appears once, in the checklist and as a section.
- No step relies on a tool, login or value introduced later.
- Every command was confirmed in step 2; every placeholder says where its value comes from.
- Every task ends with a check and a close command.

Done when every check passes; fix the guide until it does.

## 6. Report

Don't commit. Tell the user the guide's path, how many tasks it covers and the total time, and list each open question you couldn't resolve.
