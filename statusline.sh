#!/usr/bin/env bash
# Claude Code status line.
# Format: model | dir | branch | ctx N% | 51.6k tok | 5h N% (reset) 7d N% (reset)
# Reads the status line JSON on stdin. Uses jq if present, else node.

input=$(cat)

# ---- Extract fields as one tab-separated line; "-" marks a missing value ----
parsed=""
if command -v jq >/dev/null 2>&1; then
  parsed=$(printf '%s' "$input" | jq -r '[
    (.model.display_name // .model.id // "-"),
    (.workspace.current_dir // .cwd // "-"),
    (.context_window.used_percentage // "-"),
    (.context_window.total_input_tokens // "-"),
    (.context_window.total_output_tokens // "-"),
    (.rate_limits.five_hour.used_percentage // "-"),
    (.rate_limits.five_hour.resets_at // "-"),
    (.rate_limits.seven_day.used_percentage // "-"),
    (.rate_limits.seven_day.resets_at // "-")
  ] | map(tostring) | join("\t")' 2>/dev/null)
elif command -v node >/dev/null 2>&1; then
  parsed=$(printf '%s' "$input" | node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
      let j = {};
      try { j = JSON.parse(s); } catch (e) {}
      const g = (f) => { try { const v = f(); return (v === undefined || v === null || v === "") ? "-" : String(v); } catch (e) { return "-"; } };
      const out = [
        g(() => j.model.display_name || j.model.id),
        g(() => (j.workspace && j.workspace.current_dir) || j.cwd),
        g(() => j.context_window.used_percentage),
        g(() => j.context_window.total_input_tokens),
        g(() => j.context_window.total_output_tokens),
        g(() => j.rate_limits.five_hour.used_percentage),
        g(() => j.rate_limits.five_hour.resets_at),
        g(() => j.rate_limits.seven_day.used_percentage),
        g(() => j.rate_limits.seven_day.resets_at),
      ];
      process.stdout.write(out.join("\t"));
    });
  ' 2>/dev/null)
fi

IFS=$'\t' read -r model cwd ctx tin tout five five_at week week_at <<<"$parsed"
for v in model cwd ctx tin tout five five_at week week_at; do
  [ -z "${!v}" ] && printf -v "$v" '%s' "-"
done
[ "$model" = "-" ] && model="Claude"

# ---- Helpers ----
is_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

round() { printf '%.0f' "$1" 2>/dev/null || echo "${1%%.*}"; }

# 51600 -> 51.6k, 1234567 -> 1.2M
compact() {
  local n=${1%%.*} t
  if [ "$n" -ge 1000000 ]; then
    t=$(( (n + 50000) / 100000 ))
    printf '%d.%dM' $((t / 10)) $((t % 10))
  elif [ "$n" -ge 1000 ]; then
    t=$(( (n + 50) / 100 ))
    printf '%d.%dk' $((t / 10)) $((t % 10))
  else
    printf '%d' "$n"
  fi
}

# epoch seconds -> "2h13m" / "3d4h" / "5m" (empty if past or invalid)
until_reset() {
  is_num "$1" || return
  local diff=$(( ${1%%.*} - $(date +%s) )) d h m
  [ "$diff" -le 0 ] && return
  d=$((diff / 86400)); h=$(((diff % 86400) / 3600)); m=$(((diff % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# colour by percentage: green <70, yellow <90, red otherwise
pct_color() {
  local p=${1%%.*}
  if [ "$p" -ge 90 ]; then printf '\033[31m'
  elif [ "$p" -ge 70 ]; then printf '\033[33m'
  else printf '\033[32m'; fi
}

C_RST=$'\033[0m'; C_SEP=$'\033[90m'; C_MODEL=$'\033[36m'; C_DIR=$'\033[34m'; C_BR=$'\033[35m'; C_TOK=$'\033[37m'
SEP=" ${C_SEP}|${C_RST} "

# ---- Segments ----
out="${C_MODEL}${model}${C_RST}"

if [ "$cwd" != "-" ]; then
  d=${cwd//\\//}
  d=${d%/}
  base=${d##*/}
  [ -z "$base" ] && base="$d"
  out+="${SEP}${C_DIR}${base}${C_RST}"

  branch=$(git --no-optional-locks -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null \
        || git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  [ -n "$branch" ] && out+="${SEP}${C_BR}${branch}${C_RST}"
fi

if is_num "$ctx"; then
  out+="${SEP}$(pct_color "$ctx")ctx $(round "$ctx")%${C_RST}"
fi

# Session tokens = input tokens in context + output tokens, as reported by Claude Code
tok=""
if is_num "$tin" || is_num "$tout"; then
  a=0; b=0
  is_num "$tin" && a=${tin%%.*}
  is_num "$tout" && b=${tout%%.*}
  tok=$((a + b))
fi
[ -n "$tok" ] && out+="${SEP}${C_TOK}$(compact "$tok") tok${C_RST}"

rl=""
if is_num "$five"; then
  r=$(until_reset "$five_at")
  rl+="$(pct_color "$five")5h $(round "$five")%${C_RST}"
  [ -n "$r" ] && rl+=" ${C_SEP}(${r})${C_RST}"
fi
if is_num "$week"; then
  r=$(until_reset "$week_at")
  [ -n "$rl" ] && rl+=" "
  rl+="$(pct_color "$week")7d $(round "$week")%${C_RST}"
  [ -n "$r" ] && rl+=" ${C_SEP}(${r})${C_RST}"
fi
[ -n "$rl" ] && out+="${SEP}${rl}"

printf '%s\n' "$out"
