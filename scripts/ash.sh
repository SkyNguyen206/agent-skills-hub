#!/usr/bin/env bash
# ash — Agent/Skill Hub CLI (interactive, npx-skills-style)
# Requires: jq
set -euo pipefail

# Needs bash >= 4: `declare -A` (interactive_add's tool_scope) and `mapfile`
# both appeared in bash 4.0. macOS ships bash 3.2 by default, where `ash add`
# would die at `declare -A` with a cryptic error — fail fast with a hint.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ash cần bash >= 4 (macOS: brew install bash; Linux: bash mặc định là đủ)." >&2
  exit 1
fi

# Current release version. Single source of truth: also mirrored in ./VERSION
# (kept in sync manually — VERSION exists so tooling/git tags can read it
# without running bash).
ASH_VERSION="0.1.0"

HUB_DIR="${ASH_HUB_DIR:-$HOME/agent-skills-hub}"
PROJECT_ROOT="$(pwd)"
PROJECT_STATE="$PROJECT_ROOT/.ash/state.json"
REGISTRY="$HOME/.ash/registry.json"
PRESETS_DIR="$HUB_DIR/presets/roles"

# ---- custom (non-vendor) content ------------------------------------------
# Layout: $HUB_DIR/custom/{agents,skills}/
# Vendor (vendor/agency-agents, vendor/skills) stays untouched/read-only by
# design — updates come only via `git submodule update`. Anything hand-rolled
# goes here instead. `agents/` is a placeholder for now: install_agent() does
# NOT read from it yet (agent install still goes through vendor's
# install.sh/convert.sh pipeline, which expects tool-native formats — a raw
# custom agent file can't just be symlinked in the same way a skill can).
# Only `skills/` is wired in below.
CUSTOM_DIR="$HUB_DIR/custom"
CUSTOM_SKILLS_DIR="$CUSTOM_DIR/skills"
CUSTOM_AGENTS_DIR="$CUSTOM_DIR/agents"   # reserved, unused for now

# Skip all side effects (mkdir, state/registry init, dispatch) when sourced as
# a library (ASH_AS_LIB=1) — used by `ash check`'s sandbox harness and any
# external tool that wants dest_for_agent()/dest_for_skill() without touching
# the filesystem.
if [ "${ASH_AS_LIB:-0}" != 1 ]; then
  mkdir -p "$PROJECT_ROOT/.ash" "$HOME/.ash" "$CUSTOM_SKILLS_DIR" "$CUSTOM_AGENTS_DIR"
  [ -f "$REGISTRY" ] || echo '{}' > "$REGISTRY"
  [ -f "$PROJECT_STATE" ] || echo '{"items":[]}' > "$PROJECT_STATE"
fi

# ---- UI: colors, icons, spinner --------------------------------------------
# Degrades cleanly: no color/spinner when stdout isn't a tty (pipes, CI, logs).
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim)
  C_CYAN=$(tput setaf 6); C_GREEN=$(tput setaf 2); C_RED=$(tput setaf 1)
  C_YELLOW=$(tput setaf 3); C_MAGENTA=$(tput setaf 5)
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_MAGENTA=""
fi
ICON_OK="${C_GREEN}✓${C_RESET}"
ICON_ERR="${C_RED}✗${C_RESET}"
ICON_WARN="${C_YELLOW}⚠${C_RESET}"
ICON_ARROW="${C_CYAN}➜${C_RESET}"

ui_title() { printf '\n%s%s%s\n' "${C_BOLD}${C_MAGENTA}" "$*" "$C_RESET"; }
ui_step()  { printf '%s %s\n' "$ICON_ARROW" "$*"; }
ui_ok()    { printf '  %s %s\n' "$ICON_OK" "$*"; }
ui_err()   { printf '  %s %s\n' "$ICON_ERR" "$*" >&2; }
ui_warn()  { printf '  %s %s\n' "$ICON_WARN" "$*" >&2; }
ui_dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ui_add()   { printf '  %s+ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
ui_rm()    { printf '  %s- %s%s\n' "$C_RED" "$*" "$C_RESET"; }

# spinner_run "label" -- cmd args...
# Runs cmd in the background with a spinner. Command's stdout/stderr is
# captured to a buffer (NOT streamed live) — streaming while a spinner
# overwrites the same line with \r produces garbled, unreadable output when
# the wrapped command (e.g. vendor's install.sh) prints its own multi-line
# progress. On success the captured log is discarded (clean, npx-style). On
# failure it's dumped in full so the real error is visible, not buried.
spinner_run() {
  local label="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local logfile; logfile=$(mktemp)
  local timeout_s=180

  # NOTE: do NOT wrap with the external `timeout` binary — "$@" here is
  # usually a shell FUNCTION (e.g. install_agent), and `timeout` execs its
  # argument as a real program looked up via PATH; it can't see shell
  # functions and fails instantly with "command not found" (rc 127) —
  # confirmed: that's exactly why this appeared to "stop immediately"
  # right when the spinner started. Implement the timeout ourselves by
  # counting spinner iterations and killing the pid if it runs too long.
  "$@" </dev/null >"$logfile" 2>&1 &
  local pid=$!
  local timed_out=0

  if [ ! -t 1 ]; then
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1; waited=$((waited+1))
      if [ "$waited" -ge "$timeout_s" ]; then
        timed_out=1
        kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
        break
      fi
    done
    wait "$pid" 2>/dev/null; local rc=$?
    [ $rc -ne 0 ] && cat "$logfile" >&2
    rm -f "$logfile"
    return $rc
  fi

  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 rc
  local max_iters=$((timeout_s * 12))   # ~0.08s/iter -> roughly timeout_s seconds
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s %s ' "${C_CYAN}${frames:$((i%${#frames})):1}${C_RESET}" "$label"
    i=$((i+1)); sleep 0.08
    if [ "$i" -ge "$max_iters" ]; then
      timed_out=1
      kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
      break
    fi
  done
  wait "$pid" 2>/dev/null; rc=$?
  tput cnorm 2>/dev/null || true
  printf '\r\033[K'
  if [ "$timed_out" -eq 1 ]; then
    printf '  %s %s %s(timeout %ss — có thể bị treo chờ stdin)%s\n' "$ICON_ERR" "$label" "$C_YELLOW" "$timeout_s" "$C_RESET"
    ui_dim "  --- log ---"
    sed 's/^/    /' "$logfile" >&2
    ui_dim "  -----------"
    rc=124
  elif [ $rc -eq 0 ]; then
    printf '  %s %s\n' "$ICON_OK" "$label"
  else
    printf '  %s %s\n' "$ICON_ERR" "$label"
    ui_dim "  --- log ---"
    sed 's/^/    /' "$logfile" >&2
    ui_dim "  -----------"
  fi
  rm -f "$logfile"
  return $rc
}

# select_multi "prompt" <outvar> opt1 opt2 ...
# Uses fzf (Tab=toggle, Enter=confirm) when available; falls back to the
# numbered menu + comma-list otherwise. Result written into $outvar array.
select_multi() {
  local prompt="$1" outvar="$2"; shift 2
  local -a opts=("$@") chosen=()
  if command -v fzf >/dev/null 2>&1; then
    local raw
    raw=$(printf '%s\n' "${opts[@]}" | fzf -m --prompt="$prompt > " --height=~60% --border \
      --header='Tab: chọn/bỏ chọn nhiều · Enter: xác nhận · Esc: huỷ' || true)
    [ -n "$raw" ] && while IFS= read -r line; do chosen+=("$line"); done <<< "$raw"
  else
    print_menu "${C_BOLD}${prompt}${C_RESET} ${C_DIM}(vd: 1,3)${C_RESET}" "${opts[@]}"
    read -rp "> " sel
    local idx
    for idx in $(parse_selection "$sel" "${#opts[@]}"); do chosen+=("${opts[$((idx-1))]}"); done
  fi
  eval "$outvar=(\"\${chosen[@]}\")"
}

ALL_TOOLS=(opencode claude-code copilot gemini-cli antigravity cursor codex)
# Tools whose install.sh path requires a pre-generated intermediate format
# (confirmed via real run for opencode: "no agent files found in
# integrations/opencode. Run convert.sh --tool opencode first"). cursor (.mdc)
# and codex (.toml) produce non-native formats too, so grouped here.
# gemini-cli also reads ONLY from integrations/gemini-cli/agents (install.sh
# errors "integrations/gemini-cli/agents missing" without it) — added here so
# the first install attempt succeeds instead of relying on the heal path.
# copilot/claude-code use native .md agents straight from the source dirs.
TOOLS_NEEDING_CONVERT=(opencode antigravity cursor codex gemini-cli)

# Some tools only support one scope per current docs — reject the other
# instead of silently computing a nonsense/wrong path.
scope_supported() {
  local tool="$1" scope="$2"
  case "$tool:$scope" in
    cursor:global) return 1 ;;   # Cursor rules are project-only (.cursor/rules/)
    codex:local)   return 1 ;;   # Codex agents documented as ~/.codex/agents/ only
    *) return 0 ;;
  esac
}

# ---- generic numbered-menu helpers --------------------------------------
# print_menu <label> <options...>
print_menu() {
  local label="$1"; shift
  echo "$label"
  local i=1
  for o in "$@"; do printf "  [%d] %s\n" "$i" "$o"; i=$((i+1)); done
}

# parse_selection "<raw input>" <max> -> prints 1-based indices, one per line
parse_selection() {
  local raw="${1// /,}" max="$2"
  IFS=',' read -ra parts <<< "$raw"
  for p in "${parts[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    if (( p >= 1 && p <= max )); then echo "$p"; fi
  done
}

confirm() {
  local prompt="$1"
  read -rp "${C_BOLD}${prompt}${C_RESET} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- dest path per (tool, scope) -----------------------------------------
# Echoes "<dest_path>|<confirmed:yes/no>"
dest_for_agent() {
  local tool="$1" scope="$2" division="$3" slug="$4"
  # Confirmed via `install.sh --list agents` + a real `ls` on
  # vendor/agency-agents/integrations/<tool>/: for the CONVERTED tools
  # (opencode, antigravity, cursor, codex) vendor's install_*() functions copy
  # each converted file UNMODIFIED — filename is whatever convert.sh's own
  # per-agent slug produced, which is NEVER "<division>-<slug>". `division`
  # is only a filter dimension (--division flag), unrelated to filenames.
  # The old "${division}-${slug}.md" formula here was wrong for those tools —
  # it happened to look "confirmed working" earlier only because
  # install_agent()'s own [fixup] logic silently found the real bare-slug
  # file and renamed it to match this (wrong) expectation.
  # EXCEPTION: copilot is NOT a converted tool — install_copilot copies source
  # files verbatim and keeps the "<division>-<slug>.md" filename (see below).
  local file="${slug}.md"
  case "$tool:$scope" in
    opencode:local)    echo "$PROJECT_ROOT/.opencode/agents/$file|yes" ;;
    opencode:global)   echo "$HOME/.config/opencode/agents/$file|no" ;;
    claude-code:local) echo "$PROJECT_ROOT/.claude/agents/$file|no" ;;
    claude-code:global)echo "$HOME/.claude/agents/$file|yes" ;;
    # copilot + claude-code are NOT converted tools — they copy SOURCE files
    # directly. The source basename is arbitrary and unrelated to the slug:
    # some are "<division>-<slug>.md" (engineering-data-engineer.md), some are
    # bare (business-strategist.md), one is even "project-manager-senior.md"
    # while its slug (frontmatter name) is "senior-project-manager". So the
    # vendor's copied filename is NOT predictable from (division, slug).
    # ash therefore adopts ONE convention for every tool — bare "<slug>.md" —
    # and install_agent()'s [fixup] renames whatever the vendor produced to
    # match it. Confirmed by real runs + the `ash check dest` contract.
    copilot:local)     echo "$PROJECT_ROOT/.github/agents/${slug}.md|no" ;;
    copilot:global)    echo "$HOME/.copilot/agents/${slug}.md|yes" ;;
    gemini-cli:local)  echo "$PROJECT_ROOT/.gemini/agents/$file|no" ;;
    gemini-cli:global) echo "$HOME/.gemini/agents/$file|yes" ;;
    # antigravity agents = skill dirs under the shared Gemini config root.
    # Per Google docs, ~/.gemini/config/skills/ is the ONLY global path read by
    # all three Antigravity surfaces (AGY, CLI, IDE); vendor install.sh also
    # defaults there. Workspace skills live in <proj>/.agents/skills/.
    antigravity:local) echo "$PROJECT_ROOT/.agents/skills/agency-$slug/SKILL.md|no" ;;
    antigravity:global)echo "$HOME/.gemini/config/skills/agency-$slug/SKILL.md|yes" ;;
    cursor:local)       echo "$PROJECT_ROOT/.cursor/rules/${slug}.mdc|yes" ;;
    codex:global)       echo "$HOME/.codex/agents/${slug}.toml|yes" ;;
    *) echo "ERROR: unsupported tool:scope $tool:$scope — check scope_supported()" >&2; exit 1 ;;
  esac
}

dest_for_skill() {
  local tool="$1" scope="$2" slug="$3"
  case "$tool:$scope" in
    # User requested tool-native path over the generic .agents/skills/
    # fallback (both work per OpenCode docs, but native is more explicit).
    opencode:local)     echo "$PROJECT_ROOT/.opencode/skills/$slug|yes" ;;
    # User confirmed this is the path to use — no longer flagging as unverified.
    opencode:global)    echo "$HOME/.opencode/skills/$slug|yes" ;;
    # Confirmed: Claude Skills spec — project (.claude/skills/) takes
    # priority over global (~/.claude/skills/).
    claude-code:local)  echo "$PROJECT_ROOT/.claude/skills/$slug|yes" ;;
    claude-code:global) echo "$HOME/.claude/skills/$slug|yes" ;;
    # Confirmed by user: Cursor uses its own convention.
    cursor:local)        echo "$PROJECT_ROOT/.cursor/skills/$slug|yes" ;;
    # From user-provided doc (GitHub Copilot CLI Reference / MS Learn):
    # .github/skills/ is the official committed-to-repo convention.
    copilot:local)       echo "$PROJECT_ROOT/.github/skills/$slug|yes" ;;
    copilot:global)      echo "$HOME/.copilot/skills/$slug|yes" ;;
    # From user-provided doc (Gemini CLI official docs).
    gemini-cli:local)    echo "$PROJECT_ROOT/.gemini/skills/$slug|yes" ;;
    gemini-cli:global)   echo "$HOME/.gemini/skills/$slug|yes" ;;
    # From user-provided doc; antigravity global skills are read from
    # ~/.gemini/config/skills/ (shared root, all AGY/CLI/IDE surfaces).
    antigravity:local)   echo "$PROJECT_ROOT/.agents/skills/$slug|yes" ;;
    antigravity:global)  echo "$HOME/.gemini/config/skills/$slug|yes" ;;
    # Codex: the user's own source explicitly flags this as NOT backed by
    # official OpenAI docs — community/wrapper convention only. Keep it as
    # the best guess but marked unconfirmed, unlike Codex's agent path
    # (.toml) which we already verified via a real `ls`.
    codex:local)         echo "$PROJECT_ROOT/.codex/skills/$slug|no" ;;
    codex:global)        echo "$HOME/.codex/skills/$slug|no" ;;
    *:global)            echo "$HOME/.agents/skills/$slug|no" ;;
    *:local)              echo "$PROJECT_ROOT/.agents/skills/$slug|no" ;;
  esac
}

# ---- role presets ----------------------------------------------------------
list_roles() {
  find "$PRESETS_DIR" -maxdepth 1 -name '*.json' -exec basename {} .json \; | sort
}

role_description() {
  jq -r '.description // "(no description)"' "$PRESETS_DIR/$1.json"
}

# resolve_items <role> <tool> <scope> -> JSON array of {kind,...,dest,scope,confirmed}
# Tools whose installer only writes agents globally, regardless of cwd.
# claude-code + copilot confirmed via real run (install.sh wrote to ~/.claude
# and ~/.copilot even when invoked from the project root asking for local).
# gemini-cli: install_gemini_cli defaults to ${HOME}/.gemini/agents with no
# cwd-based variant. antigravity: install_antigravity defaults to
# ${HOME}/.gemini/config/skills (its workspace mode would be <proj>/.agents/
# but the vendor installer never targets it). This is an agent-only
# restriction — Claude Code / Copilot skill loading still supports
# project-local dirs, so skills are unaffected.
AGENT_GLOBAL_ONLY_TOOLS=(claude-code copilot gemini-cli antigravity)

agent_scope_supported() {
  local tool="$1" scope="$2"
  [ "$scope" = "local" ] || return 0
  for t in "${AGENT_GLOBAL_ONLY_TOOLS[@]}"; do
    [ "$t" = "$tool" ] && return 1
  done
  return 0
}

resolve_role_items() {
  local role="$1" tool="$2" scope="$3"
  local preset="$PRESETS_DIR/$role.json"
  [ -f "$preset" ] || { echo "ERROR: preset not found: $role" >&2; exit 1; }
  jq -c '(.agents // [])[] + {kind:"agent"}, (.skills // [])[] + {kind:"skill"}' "$preset" | \
  while read -r item; do
    kind=$(echo "$item" | jq -r '.kind')
    slug=$(echo "$item" | jq -r '.slug')
    if [ "$kind" = "agent" ]; then
      division=$(echo "$item" | jq -r '.division')
      local eff_scope="$scope"
      if ! agent_scope_supported "$tool" "$scope"; then
        eff_scope="global"
        echo "    ⚠ $tool: agent chỉ hỗ trợ global qua installer này — dùng global cho agent (skill vẫn theo scope bạn chọn)" >&2
      fi
      out=$(dest_for_agent "$tool" "$eff_scope" "$division" "$slug")
      dest="${out%%|*}"; confirmed="${out##*|}"
      echo "$item" | jq -c --arg dest "$dest" --arg scope "$eff_scope" --arg tool "$tool" --arg confirmed "$confirmed" \
        '. + {dest:$dest, scope:$scope, tool:$tool, path_confirmed:($confirmed=="yes"), companion:false}'
      if [ "$tool" = "copilot" ]; then
        # Confirmed via real run: install.sh writes copilot agents to BOTH
        # ~/.github/agents/ and ~/.copilot/agents/ in a single call. .copilot/
        # is treated as the source-of-truth dest above; this companion entry
        # just makes sure `ash clean` also removes the .github/ copy instead
        # of leaving it orphaned. No separate install call needed for it.
        local companion_dest="$HOME/.github/agents/${slug}.md"
        echo "$item" | jq -c --arg dest "$companion_dest" --arg tool "$tool" \
          '. + {dest:$dest, scope:"global", tool:$tool, path_confirmed:true, companion:true}'
      fi
    else
      out=$(dest_for_skill "$tool" "$scope" "$slug")
      dest="${out%%|*}"; confirmed="${out##*|}"
      echo "$item" | jq -c --arg dest "$dest" --arg scope "$scope" --arg tool "$tool" --arg confirmed "$confirmed" \
        '. + {dest:$dest, scope:$scope, tool:$tool, path_confirmed:($confirmed=="yes")}'
    fi
  done
}

# ---- registry (refcount, global scope only) -------------------------------
registry_incref() {
  jq --arg d "$1" --arg p "$PROJECT_ROOT" '.[$d] = ((.[$d] // []) + [$p] | unique)' "$REGISTRY" > "$REGISTRY.tmp"
  mv "$REGISTRY.tmp" "$REGISTRY"
}

registry_decref_and_maybe_delete() {
  local dest="$1"
  jq --arg d "$dest" --arg p "$PROJECT_ROOT" '.[$d] = ((.[$d] // []) - [$p])' "$REGISTRY" > "$REGISTRY.tmp"
  mv "$REGISTRY.tmp" "$REGISTRY"
  local remaining; remaining=$(jq -r --arg d "$dest" '(.[$d] // []) | length' "$REGISTRY")
  if [ "$remaining" -eq 0 ]; then
    rm -rf "$dest"
    jq --arg d "$dest" 'del(.[$d])' "$REGISTRY" > "$REGISTRY.tmp"; mv "$REGISTRY.tmp" "$REGISTRY"
  else
    echo "    (giữ lại — còn $remaining project khác đang dùng)"
  fi
}

# slug_source_basename <slug> <vendor_dir> — prints the basename of the vendor
# SOURCE file whose frontmatter `name:` slugifies to <slug> (approximating
# vendor lib.sh's agent_slug: lowercase, non-alnum runs -> '-'). Returns 1 when
# no file matches. Used by install_agent's [fixup] for source-copy tools
# (copilot/claude-code) whose copied filename is unrelated to the slug.
slug_source_basename() {
  local slug="$1" vendor_dir="$2" f nm
  while IFS= read -r -d '' f; do
    nm=$(awk 'NR<=12 && /^name:/ { sub(/^name:[[:space:]]*/,""); print; exit }' "$f" 2>/dev/null)
    [ -n "$nm" ] || continue
    nm=$(printf '%s' "$nm" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')
    if [ "$nm" = "$slug" ]; then basename "$f"; return 0; fi
  done < <(find "$vendor_dir" -mindepth 2 -maxdepth 2 -name '*.md' -type f -print0 2>/dev/null || true)
  return 1
}

ensure_converted() {
  local tool="$1"
  local needs=0
  for t in "${TOOLS_NEEDING_CONVERT[@]}"; do [ "$t" = "$tool" ] && needs=1; done
  [ "$needs" -eq 1 ] || return 0
  local out_dir="$HUB_DIR/vendor/agency-agents/integrations/$tool"
  # "Empty" = no convert output, ignoring the committed README.md every
  # integrations/<tool>/ ships with (e.g. integrations/gemini-cli/ has ONLY
  # README.md in git, yet install.sh needs integrations/gemini-cli/agents/ —
  # a plain "dir empty?" check would skip convert forever and force the heal
  # path on every install).
  if [ ! -d "$out_dir" ] || [ -z "$(find "$out_dir" -type f ! -name 'README.md' 2>/dev/null)" ]; then
    echo "  [setup] $tool cần convert trước — chạy convert.sh (cache lại, chỉ chạy lại khi trống)"
    # Same quirk as install.sh (see install_agent below): convert.sh can
    # print "[!!]" warnings and still exit non-zero on an otherwise
    # successful run. Without `|| true` here, `set -e` kills install_agent
    # right at this line — BEFORE it ever attempts install.sh — which looks
    # like an instant, unexplained failure on every agent install.
    ( cd "$HUB_DIR/vendor/agency-agents" && ./scripts/convert.sh --tool "$tool" ) 2>&1 || true
  fi
}

install_agent() {
  # Confirmed via real run against the vendor script: install.sh must be run
  # with cwd = PROJECT_ROOT for project-scoped tools ("OpenCode: project-scoped.
  # Run from your project root to install there") — NOT cwd = vendor dir as
  # this function did before. Also opencode/antigravity need convert.sh run
  # at least once before install.sh can find agent files for them.
  #
  # NOTE: custom/agents/ is intentionally NOT consulted here yet. Agent
  # install always goes through vendor's install.sh/convert.sh pipeline,
  # which emits tool-native formats (.md/.mdc/.toml per tool). A hand-rolled
  # custom agent can't be symlinked in the same shortcut way a skill can —
  # wiring this in later needs either pre-converted per-tool custom agent
  # files, or a way to feed custom agents through convert.sh itself.
  local tool="$1" slug="$2" dest="$3"
  local vendor_dir="$HUB_DIR/vendor/agency-agents"
  ensure_converted "$tool"

  # install.sh prints "[!!]" warnings (e.g. the project-scoped notice) that can
  # make it exit non-zero even on a successful install — confirmed by real run:
  # file landed correctly at dest, but `set -e` killed the rest of `ash` before
  # state.json got written, so `ash clean`/`ash list` saw nothing. Don't let
  # install.sh's exit code propagate; verify success by checking $dest instead.
  local out
  out=$( ( cd "$PROJECT_ROOT" && "$vendor_dir/scripts/install.sh" --tool "$tool" --agent "$slug" ) 2>&1 ) || true
  printf '%s\n' "$out"

  # ensure_converted()'s cache check only looks at "is the integrations dir
  # empty or not" — it can't tell "non-empty but missing this agent because
  # it was converted before this agent existed / cache is stale". If
  # install.sh itself reports the classic "run convert.sh first" error, that's
  # ground truth the cache lied — force a fresh convert (ignore cache) and
  # retry install.sh exactly once before falling through to the error path.
  if [ ! -f "$dest" ] && printf '%s' "$out" | grep -q "convert.sh --tool $tool first"; then
    echo "  [heal] cache convert.sh có vẻ cũ/thiếu — ép convert lại rồi thử cài lần nữa" >&2
    # Nuke the stale convert output, but NOT the tracked README.md every
    # integrations/<tool>/ ships with — `rm -rf` on the whole dir deletes it
    # and dirties the vendor submodule (confirmed: real runs had already
    # deleted integrations/{opencode,gemini-cli}/README.md).
    find "$vendor_dir/integrations/$tool" -mindepth 1 ! -name 'README.md' -exec rm -rf {} + 2>/dev/null || true
    ( cd "$vendor_dir" && ./scripts/convert.sh --tool "$tool" ) 2>&1 || true
    out=$( ( cd "$PROJECT_ROOT" && "$vendor_dir/scripts/install.sh" --tool "$tool" --agent "$slug" ) 2>&1 ) || true
    printf '%s\n' "$out"
  fi

  if [ -f "$dest" ]; then
    return 0
  fi

  # $fname is dest_for_agent()'s output — the real bare slug (e.g.
  # "financial-analyst.md"), not a guessed "division-slug" concat. A miss at
  # this point means either a path quirk, or the slug in the preset simply
  # doesn't exist in the vendor's current agent roster — not something a
  # filename heuristic can fix. `install.sh --list agents` is the
  # authoritative source of truth for real slugs.
  #
  # find(1) exits 1 when any start path is missing (a fresh ~/.claude,
  # ~/.codex etc.), which under `set -euo pipefail` silently kills the whole
  # script with no error — the `|| true` guards below are REQUIRED, not
  # cosmetic. Search ONLY the install roots (never vendor source dirs): the
  # fixup must rename a copy, and moving a vendor SOURCE file out of the
  # submodule would dirty it.
  local fname; fname="$(basename "$dest")"
  local known_homes=("$HOME/.claude" "$HOME/.copilot" "$HOME/.github" "$HOME/.gemini" "$HOME/.codex" "$HOME/.config/opencode")
  local roots=("$PROJECT_ROOT" "${known_homes[@]}")
  local stray=""

  # 1) exact expected basename (converted tools + bare-slug sources)
  stray=$(find "${roots[@]}" -name "$fname" 2>/dev/null | grep -v "^$dest$" | head -n1 || true)

  # 2) copilot/claude-code copy vendor SOURCE files verbatim, and the source
  #    basename is arbitrary (design-image-prompt-engineer.md for slug
  #    image-prompt-engineer) — match by slug substring.
  if [ -z "$stray" ]; then
    stray=$(find "${roots[@]}" -iname "*${slug}*" 2>/dev/null | grep -v "^$dest$" | head -n1 || true)
  fi

  # 3) word-reversed basenames (project-manager-senior.md ↔ slug
  #    senior-project-manager) can't be matched by substring — resolve the
  #    source basename from the file's frontmatter `name:` (like vendor's
  #    agent_slug), then look for that copy in the install roots.
  if [ -z "$stray" ]; then
    local srcbase; srcbase=$(slug_source_basename "$slug" "$vendor_dir" || true)
    if [ -n "$srcbase" ]; then
      stray=$(find "${roots[@]}" -name "$srcbase" 2>/dev/null | grep -v "^$dest$" | head -n1 || true)
    fi
  fi

  # 4) last resort: the tool's convert output dir (converted tools can land
  #    output only there).
  if [ -z "$stray" ]; then
    stray=$(find "$vendor_dir/integrations/$tool" -type f -iname "$fname" 2>/dev/null | head -n1 || true)
  fi

  if [ -z "$stray" ]; then
    echo "ERROR: install.sh ran but '$fname' not found at dest ($dest), vendor dir, or project dir." >&2
    echo "  Slug '$slug' may not exist in the vendor roster — verify with:" >&2
    echo "    (cd $vendor_dir && ./scripts/install.sh --list agents | grep -i \"${slug%%-*}\")" >&2
    exit 1
  fi
  echo "  [fixup] found at unexpected path — moving $stray -> $dest"
  mkdir -p "$(dirname "$dest")"
  mv "$stray" "$dest"
  # The vendor copy can land in several roots at once (copilot writes both
  # ~/.github/agents/ and ~/.copilot/agents/) — rename every remaining copy of
  # the same source basename to the bare-slug convention in place, so
  # companions (the ~/.github one) aren't left orphaned under the vendor's
  # filename for `ash clean`/`ash list` to miss.
  local srcbase; srcbase="$(basename "$stray")"
  if [ "$srcbase" != "$fname" ]; then
    while IFS= read -r -d '' c; do
      [ "$c" = "$dest" ] && continue
      mv "$c" "$(dirname "$c")/$fname"
    done < <(find "${roots[@]}" -name "$srcbase" -type f -print0 2>/dev/null || true)
  fi
  find "$vendor_dir" -type d -empty -not -path "$vendor_dir" -delete 2>/dev/null || true
}

install_skill() {
  # Resolution order: custom/skills/<slug> first, then vendor/skills/skills.
  # This is the one override point for hand-rolled skills — vendor stays
  # untouched. If a slug exists in BOTH places, custom silently wins (that's
  # the intended override behavior) but we warn loudly so it's never mistaken
  # for "vendor updated and nothing changed".
  local slug="$1" dest="$2"
  local custom_src vendor_src src

  custom_src=$(find "$CUSTOM_SKILLS_DIR" -maxdepth 1 -type d -name "$slug" 2>/dev/null | head -n1 || true)
  vendor_src=$(find "$HUB_DIR/vendor/skills/skills" -maxdepth 2 -type d -name "$slug" 2>/dev/null | head -n1 || true)

  if [ -n "$custom_src" ]; then
    src="$custom_src"
    if [ -n "$vendor_src" ]; then
      echo "  [warn] skill '$slug' tồn tại cả ở custom/ lẫn vendor/ — đang dùng bản custom ($custom_src)" >&2
    fi
  else
    src="$vendor_src"
  fi

  [ -n "$src" ] || { echo "ERROR: skill '$slug' not found in custom/skills or vendor" >&2; exit 1; }
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
}

# ---- interactive add --------------------------------------------------------
# preflight_add_items <json-items> — for every item about to be installed,
# assert its source still exists before touching the filesystem. Returns 1
# (after red ui_err per missing item) when the vendor submodules changed and
# removed/renamed something a preset depends on. Mirrors the drift checks in
# check_roster_and_presets(), but runs at install time so `ash add` never
# installs half a preset and then fails on the missing piece.
preflight_add_items() {
  local items="$1"
  local missing=0
  local vendor_dir="$HUB_DIR/vendor/agency-agents"
  local roster_tmp; roster_tmp=$(mktemp)
  ( cd "$vendor_dir" && ./scripts/install.sh --list agents ) 2>/dev/null \
    | tr -s ' ' | sed 's/^ *//;s/ *$//' | grep -v '^$' > "$roster_tmp" || true
  while read -r item; do
    local kind slug division in_custom in_vendor
    kind=$(echo "$item" | jq -r '.kind')
    slug=$(echo "$item" | jq -r '.slug')
    if [ "$kind" = "agent" ]; then
      division=$(echo "$item" | jq -r '.division')
      [ -f "$CUSTOM_AGENTS_DIR/${division}-${slug}.md" ] && continue
      if ! grep -qxF "$division $slug" "$roster_tmp"; then
        ui_err "agent '$division/$slug' không tồn tại trong roster vendor lẫn custom/agents — vendor có thể đã đổi/đi bỏ. Chạy 'ash update' hoặc sửa preset."
        missing=1
      fi
    else
      in_custom="no"; in_vendor="no"
      [ -d "$CUSTOM_SKILLS_DIR/$slug" ] && in_custom="yes"
      find "$HUB_DIR/vendor/skills/skills" -maxdepth 2 -type d -name "$slug" 2>/dev/null | grep -q . && in_vendor="yes" || true
      if [ "$in_custom" = "no" ] && [ "$in_vendor" = "no" ]; then
        ui_err "skill '$slug' không tồn tại trong custom/skills lẫn vendor/skills/skills — vendor có thể đã đổi/đi bỏ. Chạy 'ash update' hoặc sửa preset."
        missing=1
      fi
    fi
  done < <(echo "$items" | jq -c '.[]')
  rm -f "$roster_tmp"
  return "$missing"
}

interactive_add() {
  ui_title "ash · add"

  local roles=(); mapfile -t roles < <(list_roles)
  [ ${#roles[@]} -gt 0 ] || { ui_err "Không có preset nào trong $PRESETS_DIR"; exit 1; }

  local labels=()
  for r in "${roles[@]}"; do labels+=("$r — $(role_description "$r")"); done
  local role_labels_chosen=()
  select_multi "Chọn role" role_labels_chosen "${labels[@]}"
  [ ${#role_labels_chosen[@]} -gt 0 ] || { ui_err "Chưa chọn role nào."; exit 1; }
  local chosen_roles=()
  for l in "${role_labels_chosen[@]}"; do chosen_roles+=("${l%% — *}"); done
  ui_ok "Role: ${chosen_roles[*]}"

  local chosen_tools=()
  select_multi "Bạn đang dùng tool nào cho project này" chosen_tools "${ALL_TOOLS[@]}"
  [ ${#chosen_tools[@]} -gt 0 ] || { ui_err "Chưa chọn tool nào."; exit 1; }
  ui_ok "Tool: ${chosen_tools[*]}"

  echo ""
  declare -A tool_scope
  for t in "${chosen_tools[@]}"; do
    read -rp "  ${C_BOLD}${t}${C_RESET} — cài ${C_CYAN}(l)ocal${C_RESET} project hay ${C_CYAN}(g)lobal${C_RESET} ~? [l/g]: " s
    local scope="local"; [[ "$s" =~ ^[Gg]$ ]] && scope="global"
    if ! scope_supported "$t" "$scope"; then
      local fallback="local"; [ "$t" = "codex" ] && fallback="global"
      ui_warn "$t không hỗ trợ scope '$scope' theo tài liệu hiện có — dùng '$fallback' thay."
      scope="$fallback"
    fi
    tool_scope["$t"]="$scope"
  done

  # resolve all (role x tool) combos, dedupe by dest
  local new_items="[]"
  for role in "${chosen_roles[@]}"; do
    for t in "${chosen_tools[@]}"; do
      local resolved; resolved=$(resolve_role_items "$role" "$t" "${tool_scope[$t]}" | jq -s '.')
      new_items=$(jq -n --argjson a "$new_items" --argjson b "$resolved" '$a + $b | unique_by(.dest)')
    done
  done

  local old_items; old_items=$(jq -c '.items' "$PROJECT_STATE")
  local to_add to_remove
  to_add=$(jq -n --argjson n "$new_items" --argjson o "$old_items" \
    '[$n[] | select([.dest] as $d | ($o|map(.dest)) | index($d[0]) | not)]')
  to_remove=$(jq -n --argjson n "$new_items" --argjson o "$old_items" \
    '[$o[] | select([.dest] as $d | ($n|map(.dest)) | index($d[0]) | not)]')

  # pre-flight: vendor drift (a skill/agent this preset depends on was
  # removed/renamed upstream) must be reported RED and abort BEFORE anything
  # is installed — install_skill/install_agent would otherwise fail only
  # halfway, after the user already confirmed the plan.
  if ! preflight_add_items "$to_add"; then
    ui_err "Drift với vendor — chưa cài gì cả. Chạy 'ash update' để đồng bộ vendor, hoặc sửa preset."
    exit 1
  fi

  ui_title "SẼ CÀI (${chosen_roles[*]})"
  if [ "$(echo "$to_add" | jq 'length')" -eq 0 ]; then
    ui_dim "  (không có gì mới)"
  else
    echo "$to_add" | jq -c '.[]' | while read -r it; do
      d=$(echo "$it" | jq -r '.dest'); pc=$(echo "$it" | jq -r '.path_confirmed')
      if [ "$pc" = "false" ]; then
        ui_add "$d  ${C_YELLOW}[⚠ path chưa verify]${C_RESET}"
      else
        ui_add "$d"
      fi
    done
  fi

  ui_title "SẼ DỌN (không còn dùng nữa)"
  if [ "$(echo "$to_remove" | jq 'length')" -eq 0 ]; then
    ui_dim "  (không có gì)"
  else
    echo "$to_remove" | jq -c '.[]' | while read -r it; do
      d=$(echo "$it" | jq -r '.dest'); sc=$(echo "$it" | jq -r '.scope')
      ui_rm "$d  ${C_DIM}[$sc]${C_RESET}"
    done
  fi
  echo ""
  confirm "Xác nhận thực hiện đúng như trên?" || { ui_dim "Đã huỷ, không có gì thay đổi."; exit 0; }

  # NOTE: previously `echo ... | while read` ran the loop in a SUBSHELL —
  # any failure inside (e.g. install_skill not finding a skill) vanished
  # silently instead of stopping the script, and state.json never got
  # written even though installs partly succeeded. Using process
  # substitution keeps the loop in the current shell so errors surface.
  #
  # IMPORTANT: `spinner_run ...` as a bare statement would trip `set -e`
  # on a non-zero return and kill the WHOLE script the instant one item
  # fails — the rest of the batch (including items that would've
  # succeeded) never runs, and it can look like the script "just stops"
  # with no visible reason. Wrapping in `if ! spinner_run ...; then`
  # neutralizes `set -e` for this one call, so one bad item is recorded
  # as a failure and the loop continues instead of aborting everything.
  echo ""
  local failed_dests=()
  while read -r item; do
    kind=$(echo "$item" | jq -r '.kind'); dest=$(echo "$item" | jq -r '.dest')
    scope=$(echo "$item" | jq -r '.scope'); slug=$(echo "$item" | jq -r '.slug')
    tool=$(echo "$item" | jq -r '.tool'); companion=$(echo "$item" | jq -r '.companion // false')
    if [ "$companion" = "true" ]; then
      : # already written on disk by the primary item's install.sh call — just track for cleanup
    elif [ "$kind" = "agent" ]; then
      if ! spinner_run "cài agent: $dest" -- install_agent "$tool" "$slug" "$dest"; then
        failed_dests+=("$dest"); continue
      fi
    else
      if ! spinner_run "cài skill: $dest" -- install_skill "$slug" "$dest"; then
        failed_dests+=("$dest"); continue
      fi
    fi
    [ "$scope" = "global" ] && registry_incref "$dest"
  done < <(echo "$to_add" | jq -c '.[]')
  while read -r item; do
    dest=$(echo "$item" | jq -r '.dest'); scope=$(echo "$item" | jq -r '.scope')
    if [ "$scope" = "global" ]; then registry_decref_and_maybe_delete "$dest"; else rm -rf "$dest"; fi
  done < <(echo "$to_remove" | jq -c '.[]')

  # Failed items must NOT be recorded as installed — otherwise `ash list`
  # would claim something is present that never actually landed on disk,
  # and `ash clean` would try to remove a file/symlink that doesn't exist.
  if [ ${#failed_dests[@]} -gt 0 ]; then
    local failed_json; failed_json=$(printf '%s\n' "${failed_dests[@]}" | jq -R . | jq -s .)
    new_items=$(jq -n --argjson n "$new_items" --argjson f "$failed_json" \
      '[$n[] | select([.dest] as $d | ($f | index($d[0])) | not)]')
  fi

  jq -n --argjson roles "$(printf '%s\n' "${chosen_roles[@]}" | jq -R . | jq -s .)" --argjson items "$new_items" \
    '{roles:$roles, items:$items}' > "$PROJECT_STATE"

  if [ ${#failed_dests[@]} -gt 0 ]; then
    ui_title "Cài xong (một phần) — ${#failed_dests[@]} mục LỖI:"
    for d in "${failed_dests[@]}"; do ui_rm "$d"; done
    ui_warn "Xem log '--- log ---' phía trên để biết lý do từng mục. Chạy lại 'ash add' sau khi sửa (vd: đổi division/slug trong preset) để thử lại — các mục đã cài thành công sẽ không bị cài lại."
  else
    ui_ok "Xong. Active roles: ${chosen_roles[*]}"
  fi
}

# ---- interactive clean: hỏi rõ dọn gì, không xoá hết mặc định -------------
interactive_clean() {
  ui_title "ash · clean"
  local items; items=$(jq -c '.items' "$PROJECT_STATE")
  local count; count=$(echo "$items" | jq 'length')
  if [ "$count" -eq 0 ]; then ui_dim "Project này chưa cài gì qua ash."; exit 0; fi

  local labels=() dests=()
  while read -r it; do
    d=$(echo "$it" | jq -r '.dest'); sc=$(echo "$it" | jq -r '.scope')
    labels+=("$d  [$sc]"); dests+=("$d")
  done < <(echo "$items" | jq -c '.[]')

  local chosen=()
  if command -v fzf >/dev/null 2>&1; then
    local raw
    raw=$(printf '%s\n' "${labels[@]}" | fzf -m --prompt="Chọn mục muốn DỌN > " --height=~60% --border \
      --header='Tab: chọn nhiều · Enter: xác nhận' || true)
    [ -n "$raw" ] && while IFS= read -r line; do chosen+=("$line"); done <<< "$raw"
  else
    print_menu "${C_BOLD}Đang cài những mục sau — chọn mục muốn DỌN${C_RESET} ${C_DIM}(vd: 1,2 hoặc 'all')${C_RESET}:" "${labels[@]}"
    read -rp "> " sel
    if [ "$sel" = "all" ]; then
      chosen=("${labels[@]}")
    else
      local idx
      for idx in $(parse_selection "$sel" "${#labels[@]}"); do chosen+=("${labels[$((idx-1))]}"); done
    fi
  fi
  [ ${#chosen[@]} -gt 0 ] || { ui_dim "Không chọn gì, huỷ."; exit 0; }

  ui_title "Sẽ DỌN"
  for l in "${chosen[@]}"; do ui_rm "$l"; done
  confirm "Xác nhận?" || { ui_dim "Đã huỷ."; exit 0; }

  local remaining="$items"
  for l in "${chosen[@]}"; do
    dest="${l%%  [*}"
    scope=$(echo "$items" | jq -r --arg d "$dest" '.[] | select(.dest==$d) | .scope')
    if [ "$scope" = "global" ]; then registry_decref_and_maybe_delete "$dest"; else rm -rf "$dest"; fi
    ui_ok "$dest"
    remaining=$(echo "$remaining" | jq --arg d "$dest" '[.[] | select(.dest != $d)]')
  done
  jq --argjson items "$remaining" '.items = $items' "$PROJECT_STATE" > "$PROJECT_STATE.tmp"
  mv "$PROJECT_STATE.tmp" "$PROJECT_STATE"
  ui_ok "Xong."
}

# ---- one-time setup: install this script to ~/bin/ash ----------------------
# Copies the currently-running script to ~/bin/ash and chmod +x's it, so
# `ash` works globally without an alias/PATH hack pointing back into the repo.
# `sudo -v` is used purely as a password confirmation gate (as requested) —
# ~/bin is user-owned and never actually needs root; this just forces an
# explicit "yes it's really you" prompt before writing outside the repo.
cmd_setup() {
  ui_title "ash · setup"
  local target_dir="$HOME/bin"
  local target="$target_dir/ash"

  # Resolve the real path of the running script (works whether invoked as
  # ./ash.sh, bash scripts/ash.sh, or via a relative symlink).
  local src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  ui_step "Sẽ cài ash CLI vào: ${C_BOLD}$target${C_RESET}"
  ui_dim "  (nguồn: $src)"
  ui_step "Xác nhận bằng mật khẩu hệ thống trước khi ghi file (không cần quyền root cho ~/bin):"
  if ! sudo -v; then
    ui_err "Xác thực thất bại, huỷ setup."
    exit 1
  fi

  mkdir -p "$target_dir"
  if [ -e "$target" ] && ! confirm "Đã có $target — ghi đè?"; then
    ui_dim "Đã huỷ, không có gì thay đổi."
    exit 0
  fi
  spinner_run "cài $target" -- cp "$src" "$target"
  chmod +x "$target"

  case ":$PATH:" in
    *":$target_dir:"*)
      ui_ok "~/bin đã có trong PATH — gõ '${C_BOLD}ash${C_RESET}' ở bất kỳ đâu là chạy được ngay."
      ;;
    *)
      ui_warn "~/bin chưa có trong PATH. Thêm dòng sau vào ~/.bashrc hoặc ~/.zshrc rồi mở lại shell:"
      ui_dim "      export PATH=\"\$HOME/bin:\$PATH\""
      ;;
  esac
}

# ---- contract checks: catch drift when vendor submodules are updated ------
# Run after `git submodule update` (or via `ash update`). The point is NOT to
# mirror vendor internals by hand — vendor's own outputs are the source of
# truth:
#   * roster = `install.sh --list agents` (authoritative slug list)
#   * dests  = a real sandboxed install, compared against
#              dest_for_agent()/dest_for_skill()
# so drift fails loudly here instead of being silently papered over by the
# runtime heal/fixup paths in install_agent().

check_roster_and_presets() {
  local vendor_dir="$HUB_DIR/vendor/agency-agents"
  local fail=0
  local roster_tmp; roster_tmp=$(mktemp)
  # roster lines are "<division> <slug>" padded with variable spaces — normalize.
  ( cd "$vendor_dir" && ./scripts/install.sh --list agents ) 2>/dev/null \
    | tr -s ' ' | sed 's/^ *//;s/ *$//' | grep -v '^$' > "$roster_tmp" || true
  local n_agents; n_agents=$(wc -l < "$roster_tmp" | tr -d ' ')
  if [ "$n_agents" -eq 0 ]; then
    ui_err "Không parse được roster từ install.sh --list agents — vendor có vấn đề."
    rm -f "$roster_tmp"
    return 1
  fi

  # 1) every preset-referenced agent must exist in roster ∪ custom/agents
  local preset div slug
  for preset in "$PRESETS_DIR"/*.json; do
    [ -f "$preset" ] || continue
    while read -r div slug; do
      [ -n "$div" ] || continue
      if [ -f "$CUSTOM_AGENTS_DIR/${div}-${slug}.md" ]; then continue; fi
      if ! grep -qxF "$div $slug" "$roster_tmp"; then
        ui_err "agent '$div/$slug' (preset $(basename "$preset")) không có trong roster vendor lẫn custom/agents"
        fail=1
      fi
    done < <(jq -r '.agents[]? | "\(.division) \(.slug)"' "$preset" 2>/dev/null)
  done

  # 2) every preset-referenced skill must exist in custom/skills or vendor
  local s
  while read -r s; do
    [ -n "$s" ] || continue
    local in_custom="no" in_vendor="no"
    [ -d "$CUSTOM_SKILLS_DIR/$s" ] && in_custom="yes"
    find "$HUB_DIR/vendor/skills/skills" -maxdepth 2 -type d -name "$s" 2>/dev/null | grep -q . && in_vendor="yes" || true
    if [ "$in_custom" = "no" ] && [ "$in_vendor" = "no" ]; then
      ui_err "skill '$s' không tồn tại trong custom/skills lẫn vendor/skills/skills"
      fail=1
    elif [ "$in_custom" = "yes" ] && [ "$in_vendor" = "yes" ]; then
      ui_warn "skill '$s' tồn tại ở cả custom/ lẫn vendor/ — custom sẽ override (đúng như install_skill)"
    fi
  done < <(for f in "$PRESETS_DIR"/*.json; do [ -f "$f" ] && jq -r '.skills[]?.slug' "$f" 2>/dev/null; done | sort -u)

  # 3) custom/agents convention validation (framework — dir thường rỗng cho tới khi wire vào install)
  local c base cdiv cslug
  for c in "$CUSTOM_AGENTS_DIR"/*.md; do
    [ -e "$c" ] || continue
    base=$(basename "$c" .md)
    cdiv="${base%-*}"; cslug="${base##*-}"
    if [ -z "$cdiv" ] || [ -z "$cslug" ] || [ "$cdiv" = "$cslug" ]; then
      ui_err "custom/agents: '$c' không đúng dạng <division>-<slug>.md"
      fail=1
      continue
    fi
    if ! grep -q "\"$cslug\"" "$PRESETS_DIR"/*.json 2>/dev/null; then
      ui_warn "custom agent '$base' không được preset nào tham chiếu — sẽ không bao giờ được cài"
    fi
    if grep -qxF "$cdiv $cslug" "$roster_tmp"; then
      ui_warn "custom agent '$base' override vendor agent '$cdiv/$cslug'"
    fi
  done

  # 4) convert-cache completeness (WARN): converted output should have one
  # artifact per roster agent. A shortfall means the cache is stale (an agent
  # was added/renamed upstream) — installs still work via the runtime heal,
  # but only `ash check` surfaces it instead of silently re-converting.
  local tool cnt
  for tool in "${TOOLS_NEEDING_CONVERT[@]}"; do
    cnt=$(find "$vendor_dir/integrations/$tool" -type f ! -name 'README.md' 2>/dev/null | wc -l | tr -d ' ')
    if [ -n "$cnt" ] && [ "$cnt" -gt 0 ] && [ "$cnt" -ne "$n_agents" ]; then
      ui_warn "convert cache cho '$tool' có $cnt artifact, roster có $n_agents — cache cũ/thiếu, 'ash add' sẽ phải heal để convert lại."
    fi
  done

  rm -f "$roster_tmp"
  if [ "$fail" -eq 0 ]; then
    ui_ok "Contract OK — $n_agents agent trong roster, mọi agent/skill trong preset resolve."
    return 0
  fi
  ui_err "Có drift — sửa preset (đổi slug/division) hoặc update vendor trước khi cài."
  return 1
}

check_dest() {
  local tool_arg="" mode="sample"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tool) tool_arg="$2"; shift 2 ;;
      --full) mode="full"; shift ;;
      *) ui_err "Không rõ option: '$1'"; return 1 ;;
    esac
  done

  local vendor_dir="$HUB_DIR/vendor/agency-agents"
  local sandbox; sandbox=$(mktemp -d)
  local fake_home="$sandbox/home" fake_proj="$sandbox/proj"
  mkdir -p "$fake_home" "$fake_proj"
  local fail=0 n_tests=0

  local agents_tmp; agents_tmp=$(mktemp)
  if [ "$mode" = "full" ]; then
    ( cd "$vendor_dir" && ./scripts/install.sh --list agents ) 2>/dev/null \
      | tr -s ' ' | sed 's/^ *//;s/ *$//' | grep -v '^$' > "$agents_tmp" || true
  else
    for f in "$PRESETS_DIR"/*.json; do
      [ -f "$f" ] && jq -r '.agents[]? | "\(.division) \(.slug)"' "$f" 2>/dev/null
    done | sort -u > "$agents_tmp"
  fi

  local tools=()
  if [ -n "$tool_arg" ]; then tools=("$tool_arg"); else tools=("${ALL_TOOLS[@]}"); fi

  local tool
  for tool in "${tools[@]}"; do
    ensure_converted "$tool" >/dev/null 2>&1 || true
    local scope
    for scope in global local; do
      # only scopes the tool actually supports (mirror add-flow filtering)
      if ! scope_supported "$tool" "$scope"; then continue; fi
      if ! agent_scope_supported "$tool" "$scope"; then continue; fi
      local div slug out expected
      while read -r div slug; do
        [ -n "$div" ] || continue
        n_tests=$((n_tests+1))
        # point HOME/PROJECT_ROOT into the sandbox so global dests land in fake_home
        HOME="$fake_home" PROJECT_ROOT="$fake_proj" out=$(dest_for_agent "$tool" "$scope" "$div" "$slug")
        expected="${out%%|*}"
        # Test ash's REAL install path (vendor install + heal + fixup). The
        # fixup renames vendor output to the bare-<slug> convention — required
        # for source-copy tools (copilot, claude-code) whose vendor filenames
        # are arbitrary source basenames, and for the contract this is the
        # invariant users actually rely on.
        if ( HOME="$fake_home" PROJECT_ROOT="$fake_proj" install_agent "$tool" "$slug" "$expected" >/dev/null 2>&1 ) && [ -f "$expected" ]; then
          if [ "$tool" = "copilot" ] && [ ! -f "$fake_home/.github/agents/${slug}.md" ]; then
            ui_err "[$tool:$scope] '$slug' thiếu companion: $fake_home/.github/agents/${slug}.md"
            fail=1
            continue
          fi
          printf '  %s %s:%s → %s\n' "$ICON_OK" "$tool" "$slug" "$expected"
        else
          ui_err "[$tool:$scope] '$slug' không cài được về dest mong đợi: $expected"
          fail=1
        fi
        rm -rf "$fake_home" "$fake_proj" 2>/dev/null || true
        mkdir -p "$fake_home" "$fake_proj"
      done < "$agents_tmp"
    done
  done

  # skill spot-check: first preset-referenced skill, symlink per tool+scope
  local sample_skill; sample_skill=$(for f in "$PRESETS_DIR"/*.json; do [ -f "$f" ] && jq -r '.skills[]?.slug' "$f" 2>/dev/null; done | sort -u | head -n1)
  if [ -n "$sample_skill" ]; then
    local tool2 scope2 out2 dest2
    for tool2 in "${tools[@]}"; do
      for scope2 in global local; do
        if ! scope_supported "$tool2" "$scope2"; then continue; fi
        HOME="$fake_home" PROJECT_ROOT="$fake_proj" out2=$(dest_for_skill "$tool2" "$scope2" "$sample_skill")
        dest2="${out2%%|*}"
        [ -n "$dest2" ] || continue
        n_tests=$((n_tests+1))
        install_skill "$sample_skill" "$dest2" >/dev/null 2>&1 || true
        if [ -L "$dest2" ]; then
          printf '  %s skill %s (%s:%s) → %s\n' "$ICON_OK" "$sample_skill" "$tool2" "$scope2" "$dest2"
        else
          ui_err "skill '$sample_skill' không symlink vào $dest2 ($tool2:$scope2)"
          fail=1
        fi
        rm -rf "$fake_home" "$fake_proj" 2>/dev/null || true
        mkdir -p "$fake_home" "$fake_proj"
      done
    done
  fi

  rm -f "$agents_tmp"
  rm -rf "$sandbox"
  if [ "$fail" -eq 0 ]; then
    ui_ok "Dest contract OK — $n_tests install(s)/symlink(s) rơi đúng dest."
    return 0
  fi
  ui_err "Dest contract có lỗi — cập nhật dest_for_agent()/dest_for_skill() cho khớp vendor."
  return 1
}

cmd_check() {
  local mode="${1:-roster}"
  case "$mode" in
    roster) check_roster_and_presets ;;
    dest)   shift; check_dest "$@" ;;
    -h|--help|help) ui_dim "Dùng: ash check [roster|dest [--tool T|all] [--full]]"; return 0 ;;
    *) ui_err "Không rõ mode: '$mode'"; ui_dim "Dùng: ash check [roster|dest [--tool T|all] [--full]]"; return 1 ;;
  esac
}

cmd_update() {
  ui_title "ash · update"
  local fast=0
  [ "${1:-}" = "--fast" ] && fast=1
  if ! command -v git >/dev/null 2>&1; then
    ui_err "Cần git để chạy ash update."
    return 1
  fi
  ui_step "git submodule update --init --recursive trong $HUB_DIR"
  ( cd "$HUB_DIR" && git submodule update --init --recursive ) || { ui_err "git submodule update thất bại."; return 1; }
  ui_ok "Submodules đã đồng bộ (vendor/skills, vendor/agency-agents)."
  if ! check_roster_and_presets; then
    ui_err "Contract fail sau update — không tự sửa; xử lý drift (sửa preset hoặc vendor) rồi chạy lại 'ash check'."
    return 1
  fi
  if [ "$fast" -eq 1 ]; then
    ui_dim "Bỏ qua dest contract (--fast). Chạy 'ash check dest' nếu vendor đổi logic cài."
  else
    ui_title "ash · check dest (sample)"
    check_dest || return 1
  fi
  ui_ok "Update xong — vendor sẵn sàng để 'ash add'."
}

print_usage() {
  ui_title "ash v${ASH_VERSION}"
  printf '%susage:%s ash <setup|add|clean|list|check|update|version>\n\n' "$C_BOLD" "$C_RESET"
  printf '  %ssetup%s   Cài script này vào ~/bin/ash (chmod +x) để dùng lệnh `ash` global.\n' "$C_CYAN" "$C_RESET"
  printf '           Chạy 1 lần: ./scripts/ash.sh setup\n'
  printf '  %sadd%s     Chạy interactive flow để chọn role/tool/scope rồi cài agent+skill.\n' "$C_CYAN" "$C_RESET"
  printf '  %sclean%s   Dọn các item đã cài trong project hiện tại.\n' "$C_CYAN" "$C_RESET"
  printf '  %slist%s    Liệt kê những gì đang cài trong project hiện tại.\n' "$C_CYAN" "$C_RESET"
  printf '  %scheck%s   Kiểm tra contract với vendor (roster/preset/custom/agents).\n' "$C_CYAN" "$C_RESET"
  printf '  %s          ash check dest [--tool T|all] [--full] — cài thử trong sandbox, so với dest_for_*().\n' "$C_CYAN" "$C_RESET"
  printf '  %supdate%s  git submodule update rồi tự chạy check + check dest --sample.\n\n' "$C_CYAN" "$C_RESET"
  ui_dim "Không có subcommand nào chạy mặc định — luôn phải gõ rõ."
}

# Sourced as a library (ASH_AS_LIB=1) → stop here, no dispatch, no side
# effects. Used by external harnesses and test scripts that want
# dest_for_agent()/dest_for_skill()/check_*() without running `ash`.
if [ "${ASH_AS_LIB:-0}" != 1 ]; then
case "${1:-}" in
  add)   interactive_add ;;
  clean) interactive_clean ;;
  setup) cmd_setup ;;
  check) shift; cmd_check "$@" ;;
  update) shift; cmd_update "$@" ;;
  version|-v|--version) printf 'ash %s\n' "$ASH_VERSION" ;;
  list)
    ui_title "ash · list"
    count=$(jq -r '.items | length' "$PROJECT_STATE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
      ui_dim "(chưa cài gì qua ash trong project này)"
    else
      printf '%sRoles:%s %s\n' "$C_BOLD" "$C_RESET" "$(jq -r '.roles | join(", ")' "$PROJECT_STATE")"
      jq -r '.items[] | "\(.dest)\u0000\(.scope)"' "$PROJECT_STATE" | while IFS=$'\0' read -r d sc; do
        ui_add "$d  ${C_DIM}[$sc]${C_RESET}"
      done
    fi
    ;;
  ""|-h|--help|help) print_usage ;;
  *) ui_err "Không rõ subcommand: '$1'"; print_usage >&2; exit 1 ;;
esac
fi
