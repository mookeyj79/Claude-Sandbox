# Claude Sandbox

Running Claude Code in a throwaway Docker Sandbox per launch, while keeping session history and skills as if it ran on the host.

## Language

**Wrapper**:
The `claude` function a user's shell loads (bash/zsh or PowerShell) that replaces running Claude on the host with running it in a fresh sandbox. There are two, and they must behave the same.
_Avoid_: launcher, script

**Project**:
The host folder `claude` was run from. Sessions, history and sandbox names all belong to a project.
_Avoid_: workspace, repo

**Project key**:
The name of a project in the history store, derived from its folder path. Both wrappers must give the same key for the same folder.
_Avoid_: base, base name, hash

**History store**:
The host folder holding each project's saved sessions and prompt history, so `--resume` works across throwaway sandboxes.
_Avoid_: backup, cache

**Earlier sessions**:
Read-only views of the history store (and the host's own sessions) mounted into a sandbox so Claude can look things up in past chats.
_Avoid_: shared history

**Close (a sandbox)**:
Save a sandbox's history to the history store, then delete it. If the save fails, the sandbox is kept, stopped, instead.
_Avoid_: cleanup, remove, release

**Leftover sandbox**:
A stopped sandbox of ours that was never closed, because its window was killed or its save failed.
_Avoid_: orphan, stale sandbox

**Sweep**:
Closing every leftover sandbox at the start of a launch.

**Skill sync**:
Making sure every skill in this repo is installed in sbx, and refreshing installed skills at most once a day.
_Avoid_: skill install, skill update
