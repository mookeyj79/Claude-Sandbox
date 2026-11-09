#!/usr/bin/env bats
# History store, close and sweep: _claude_sandbox_{project_key,new_name,project_of,push_history,
# save_history,close,sweep}

load helpers

setup() {
    setup_fake_sbx
    store="$XDG_DATA_HOME/claude-sandbox/history"
    key=claude-proj-0123abcd
    box=$key-x1y2
}

@test "project key: lowercase leaf plus a hash of the full path" {
    run _claude_sandbox_project_key "/home/me/My Project!"
    [ "$output" = "claude-my-project-$(printf '%s' '/home/me/My Project!' | sha256sum | cut -c1-8)" ]
}

@test "project key: a folder with no usable name is 'root'" {
    run _claude_sandbox_project_key "/"
    [[ "$output" == claude-root-* ]]
}

@test "new names are unique per window but trace back to the project" {
    a=$(_claude_sandbox_new_name "$key"); b=$(_claude_sandbox_new_name "$key")
    [ "$a" != "$b" ]
    [ "$(_claude_sandbox_project_of "$a")" = "$key" ]
}

@test "project_of accepts old names without the random part, rejects others" {
    [ "$(_claude_sandbox_project_of "$key")" = "$key" ]
    run _claude_sandbox_project_of "my-own-sandbox"
    [ "$status" -ne 0 ]
}

@test "push_history copies the project's store into the sandbox" {
    mkdir -p "$store/$key/projects/p"; echo s1 > "$store/$key/projects/p/s1.jsonl"
    make_sandbox "$box" running
    _claude_sandbox_push_history "$box"
    [ "$(cat "$FAKE_SBX_DIR/sandboxes/$box/fs/tmp/claude-hist/projects/p/s1.jsonl")" = s1 ]
}

@test "push_history works for a project seen for the first time" {
    make_sandbox "$box" running
    _claude_sandbox_push_history "$box"
    [ -d "$store/$key" ]
}

@test "save_history merges sessions and copies prompt history" {
    mkdir -p "$store/$key/projects/p"; echo old > "$store/$key/projects/p/s0.jsonl"
    make_sandbox "$box" stopped
    sandbox_file "$box" /home/agent/.claude/projects/p/s1.jsonl new
    sandbox_file "$box" /home/agent/.claude/projects/lost+found/junk x
    sandbox_file "$box" /home/agent/.claude/history.jsonl prompts
    _claude_sandbox_save_history "$box"
    [ "$(cat "$store/$key/projects/p/s0.jsonl")" = old ]
    [ "$(cat "$store/$key/projects/p/s1.jsonl")" = new ]
    [ ! -e "$store/$key/projects/lost+found" ]
    [ "$(cat "$store/$key/history.jsonl")" = prompts ]
}

@test "save_history fails when the sandbox has no projects folder" {
    make_sandbox "$box" stopped
    run _claude_sandbox_save_history "$box"
    [ "$status" -ne 0 ]
}

@test "close deletes the sandbox once history is saved" {
    make_sandbox "$box" running
    sandbox_file "$box" /home/agent/.claude/projects/p/s1.jsonl s
    run _claude_sandbox_close "$box"
    [ "$status" -eq 0 ]
    [ ! -d "$FAKE_SBX_DIR/sandboxes/$box" ]
    [ -f "$store/$key/projects/p/s1.jsonl" ]
}

@test "close keeps the sandbox, stopped, when the save fails" {
    make_sandbox "$box" running
    sandbox_file "$box" /home/agent/.claude/projects/p/s1.jsonl s
    touch "$FAKE_SBX_DIR/sandboxes/$box/fail-cp"
    run _claude_sandbox_close "$box"
    [ "$status" -ne 0 ]
    [[ "$output" == *"couldn't save history from $box, so the sandbox was kept"* ]]
    [ "$(cat "$FAKE_SBX_DIR/sandboxes/$box/status")" = stopped ]
}

@test "sweep closes our stopped sandboxes and leaves everything else" {
    make_sandbox "$box" stopped
    sandbox_file "$box" /home/agent/.claude/projects/p/s1.jsonl s
    make_sandbox "$key-busy" running
    make_sandbox "someone-elses" stopped
    run _claude_sandbox_sweep
    [[ "$output" == *"cleaning up leftover sandbox $box"* ]]
    [ ! -d "$FAKE_SBX_DIR/sandboxes/$box" ]
    [ -d "$FAKE_SBX_DIR/sandboxes/$key-busy" ]
    [ -d "$FAKE_SBX_DIR/sandboxes/someone-elses" ]
    [ -f "$store/$key/projects/p/s1.jsonl" ]
}

@test "sweep reads the sbx ls table with or without the status dot" {
    make_sandbox "$box" stopped
    sandbox_file "$box" /home/agent/.claude/projects/p/s1.jsonl s
    make_sandbox "$key-busy" running
    touch "$FAKE_SBX_DIR/ls-plain"
    _claude_sandbox_sweep 2>/dev/null
    [ ! -d "$FAKE_SBX_DIR/sandboxes/$box" ]
    [ -d "$FAKE_SBX_DIR/sandboxes/$key-busy" ]
}

@test "sweep retries a sandbox whose save failed last time" {
    make_sandbox "$box" stopped
    touch "$FAKE_SBX_DIR/sandboxes/$box/fail-cp"
    _claude_sandbox_sweep 2>/dev/null
    [ -d "$FAKE_SBX_DIR/sandboxes/$box" ]
    rm "$FAKE_SBX_DIR/sandboxes/$box/fail-cp"
    sandbox_file "$box" /home/agent/.claude/projects/p/s1.jsonl s
    _claude_sandbox_sweep 2>/dev/null
    [ ! -d "$FAKE_SBX_DIR/sandboxes/$box" ]
}
