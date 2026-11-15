#!/usr/bin/env bats
# sandbox/statusline.sh: status line JSON in, one line out.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export STATUSLINE_NOW=1000000
    repo="$BATS_TEST_TMPDIR/My Repo"
    mkdir -p "$repo"
    git -C "$repo" init -q -b feature-x
}

# The line without colours.
line() { printf '%s' "$1" | bash "$REPO_ROOT/sandbox/statusline.sh" | sed $'s/\033\\[[0-9;]*m//g'; }

@test "shows every segment" {
    run line '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$repo"'"},
        "context_window":{"used_percentage":42.4,"total_input_tokens":51000,"total_output_tokens":600},
        "rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1007980},
                       "seven_day":{"used_percentage":91.6,"resets_at":1270000}}}'
    [ "$output" = "Opus | My Repo | feature-x | ctx 42% | 51.6k tok | 5h 12% (2h13m) 7d 92% (3d3h)" ]
}

@test "missing fields drop their segments" {
    run line '{}'
    [ "$output" = "Claude" ]
}

@test "falls back to the model id and cwd" {
    run line '{"model":{"id":"claude-x"},"cwd":"/nowhere/at-all"}'
    [ "$output" = "claude-x | at-all" ]
}

@test "token counts compact to k and M" {
    run line '{"context_window":{"total_input_tokens":1234567,"total_output_tokens":0}}'
    [ "$output" = "Claude | 1.2M tok" ]
}

@test "a reset time already past shows no countdown" {
    run line '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":999}}}'
    [ "$output" = "Claude | 5h 5%" ]
}

@test "colours usage: green under 70, yellow under 90, red from 90" {
    out=$(printf '%s' '{"context_window":{"used_percentage":95}}' | bash "$REPO_ROOT/sandbox/statusline.sh")
    [[ "$out" == *$'\033[31mctx 95%'* ]]
    out=$(printf '%s' '{"context_window":{"used_percentage":75}}' | bash "$REPO_ROOT/sandbox/statusline.sh")
    [[ "$out" == *$'\033[33mctx 75%'* ]]
}

@test "bad JSON still prints a line" {
    run line 'not json'
    [ "$status" -eq 0 ]
    [ "$output" = "Claude" ]
}
