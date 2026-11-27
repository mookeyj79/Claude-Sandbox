#!/usr/bin/env bats
# sandbox/guard-rm.py, fed a Bash call as Claude Code's PreToolUse hook sends it.

setup() {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj/Repo/.git" "$proj/Repo/sub" "$proj/docs" "$proj/Repo/.claude/worktrees/wt" "$BATS_TEST_TMPDIR/elsewhere"
    touch "$proj/Repo/.claude/worktrees/wt/.git"
    export CLAUDE_PROJECT_DIR="$proj"
}

# guard <command>: run the hook on a Bash call made from the project folder.
guard() {
    jq -n --arg c "$1" --arg d "$proj" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
        python3 "$REPO_ROOT/sandbox/guard-rm.py"
}

@test "blocks rm -rf of a repo at the top of the project, and says how the user can run it" {
    run guard 'rm -rf Repo'
    [ "$status" -eq 2 ]
    [[ "$output" == *"! rm -rf"* ]]
}

@test "blocks it however the call is written" {
    for c in 'sudo rm -fr "Repo"' 'rm -r -f -- Repo/' 'du -sh Repo; rm -rf Repo && echo gone' \
             "cd /tmp && rm -rf $proj/Repo" $'ls\nrm -rf Repo' 'rm -rf docs' 'rm -rf *' 'rm -rf ..'; do
        run guard "$c"
        [ "$status" -eq 2 ] || { echo "not blocked: $c"; return 1; }
    done
}

@test "lets through rm inside a repo, of a worktree, outside the project, or not recursive" {
    for c in 'rm -rf Repo/sub' 'cd Repo && rm -rf sub' 'rm -rf Repo/.claude/worktrees/wt' \
             "rm -rf $BATS_TEST_TMPDIR/elsewhere" 'rm Repo/x' 'echo "rm -rf Repo"'; do
        run guard "$c"
        [ "$status" -eq 0 ] || { echo "blocked: $c"; return 1; }
    done
}

@test "lets through what it can't parse" {
    run guard 'rm -rf "Repo'
    [ "$status" -eq 0 ]
}
