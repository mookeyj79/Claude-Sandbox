#!/usr/bin/env python3
"""PreToolUse hook: stop a recursive rm from deleting the project folder or a folder at its top.

Claude Code runs it before each Bash call with the call as JSON on stdin. It blocks (exit 2,
reason on stderr) when an `rm -r` target resolves to the project folder, a folder above it,
a folder directly inside it, or a git repo anywhere inside it. Sibling project repos sit at the
top of a home folder, so a stray `rm -rf <repo>` loses work that may exist nowhere else.
Anything it can't parse is let through: the hook guards against a slip, not an adversary.
"""
import glob
import json
import os
import shlex
import sys

SEPARATORS = {";", "&&", "||", "|", "&", "(", ")"}


def segments(command):
    # shlex reads a newline as plain whitespace, so split lines first: each is a command.
    for line in command.splitlines():
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        seg = []
        for tok in lexer:
            if tok in SEPARATORS:
                if seg:
                    yield seg
                seg = []
            else:
                seg.append(tok)
        if seg:
            yield seg


def expand(arg, cwd):
    arg = os.path.expandvars(os.path.expanduser(arg))
    path = os.path.normpath(os.path.join(cwd, arg))
    return glob.glob(path) or [path]


def protected(path, project):
    if path == project or project.startswith(path.rstrip("/") + "/"):
        return True
    if not path.startswith(project + "/"):
        return False
    return os.path.dirname(path) == project or os.path.isdir(os.path.join(path, ".git"))


def blocked(command, cwd, project):
    for seg in segments(command):
        while seg and (seg[0] in ("sudo", "command", "builtin", "exec") or "=" in seg[0].split("/")[0]):
            seg = seg[1:]
        if not seg:
            continue
        if seg[0] == "cd" and len(seg) > 1:
            cwd = expand(seg[1], cwd)[0]
            continue
        if os.path.basename(seg[0]) != "rm":
            continue
        flags, targets, done = [], [], False
        for a in seg[1:]:
            if not done and a == "--":
                done = True
            elif not done and a.startswith("-"):
                flags.append(a)
            else:
                targets.append(a)
        recursive = any(f in ("--recursive",) or (not f.startswith("--") and ("r" in f or "R" in f)) for f in flags)
        if not recursive:
            continue
        for t in targets:
            for p in expand(t, cwd):
                if protected(os.path.realpath(p), project):
                    return p
    return None


def main():
    try:
        call = json.load(sys.stdin)
        command = call.get("tool_input", {}).get("command") or ""
        cwd = call.get("cwd") or os.getcwd()
        project = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or call.get("cwd") or "")
        if not command or not project or project == "/":
            return 0
        hit = blocked(command, cwd, project)
    except Exception:
        return 0
    if hit:
        print(
            f"Blocked: this would delete {hit}, a project folder or a repo in {project}. "
            "It may hold work that exists nowhere else. Ask the user first; if they agree, "
            f"they run it themselves with: ! rm -rf {shlex.quote(hit)}",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
