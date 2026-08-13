#!/usr/bin/env bash
# ash — Agent/Skill Hub CLI (interactive, npx-skills-style)
# Requires: jq
set -euo pipefail

HUB_DIR="${ASH_HUB_DIR:-$HOME/agent-skills-hub}"
PROJECT_ROOT="$(pwd)"
PROJECT_STATE="$PROJECT_ROOT/.ash/state.json"
REGISTRY="$HOME/.ash/registry.json"
PRESETS_DIR="$HUB_DIR/presets/roles"

mkdir -p "$PROJECT_ROOT/.ash" "$HOME/.ash"
[ -f "$REGISTRY" ] || echo '{}' > "$REGISTRY"
[ -f "$PROJECT_STATE" ] || echo '{"items":[]}' > "$PROJECT_STATE"

ALL_TOOLS=(opencode claude-code copilot gemini-cli antigravity cursor codex)
# Tools whose install.sh path requires a pre-generated intermediate format
# (confirmed via real run for opencode: "no agent files found in
# integrations/opencode. Run convert.sh --tool opencode first"). cursor (.mdc)
# and codex (.toml) produce non-native formats too, so grouped here.
# copilot/claude-code/gemini-cli use native .md agents, no conversion needed.
TOOLS_NEEDING_CONVERT=(opencode antigravity cursor codex)

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
  read -rp "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- dest path per (tool, scope) -----------------------------------------
# Echoes "<dest_path>|<confirmed:yes/no>"
dest_for_agent() {
  local tool="$1" scope="$2" division="$3" slug="$4"
  local file="${division}-${slug}.md"
  case "$tool:$scope" in
    opencode:local)    echo "$PROJECT_ROOT/.opencode/agents/$file|yes" ;;
    opencode:global)   echo "$HOME/.config/opencode/agents/$file|no" ;;
    claude-code:local) echo "$PROJECT_ROOT/.claude/agents/$file|no" ;;
    claude-code:global)echo "$HOME/.claude/agents/$file|yes" ;;
    copilot:local)     echo "$PROJECT_ROOT/.github/agents/$file|no" ;;
    copilot:global)    echo "$HOME/.copilot/agents/$file|yes" ;;
    gemini-cli:local)  echo "$PROJECT_ROOT/.gemini/agents/$file|no" ;;
    gemini-cli:global) echo "$HOME/.gemini/agents/$file|yes" ;;
    antigravity:local) echo "$PROJECT_ROOT/.gemini/skills/agency-$slug/SKILL.md|yes" ;;
    antigravity:global)echo "$HOME/.gemini/antigravity/skills/agency-$slug/SKILL.md|yes" ;;
    # cursor/codex integration output confirmed via real `ls` to use bare
    # <slug>.<ext> — NO division prefix (unlike opencode, confirmed the
    # opposite way: division-slug DID work there). Don't assume one naming
    # convention applies across every tool.
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
    # From user-provided doc; matches the antigravity AGENT path already
    # confirmed earlier (~/.gemini/antigravity/skills/), so treating as
    # confirmed too.
    antigravity:local)   echo "$PROJECT_ROOT/.gemini/skills/$slug|yes" ;;
    antigravity:global)  echo "$HOME/.gemini/antigravity/skills/$slug|yes" ;;
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
# Tools whose installer only writes agents globally, regardless of cwd —
# confirmed via real run: claude-code's install.sh wrote to ~/.claude/agents
# even when invoked from the project root asking for local. This is an
# agent-only restriction — Claude Code's own SKILL loading does support
# project-local .claude/skills/, so skills are unaffected.
AGENT_GLOBAL_ONLY_TOOLS=(claude-code copilot)

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
        local companion_dest="$HOME/.github/agents/${division}-${slug}.md"
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

ensure_converted() {
  local tool="$1"
  local needs=0
  for t in "${TOOLS_NEEDING_CONVERT[@]}"; do [ "$t" = "$tool" ] && needs=1; done
  [ "$needs" -eq 1 ] || return 0
  local out_dir="$HUB_DIR/vendor/agency-agents/integrations/$tool"
  if [ ! -d "$out_dir" ] || [ -z "$(find "$out_dir" -type f 2>/dev/null)" ]; then
    echo "  [setup] $tool cần convert trước — chạy convert.sh (cache lại, chỉ chạy lại khi trống)"
    ( cd "$HUB_DIR/vendor/agency-agents" && ./scripts/convert.sh --tool "$tool" )
  fi
}

install_agent() {
  # Confirmed via real run against the vendor script: install.sh must be run
  # with cwd = PROJECT_ROOT for project-scoped tools ("OpenCode: project-scoped.
  # Run from your project root to install there") — NOT cwd = vendor dir as
  # this function did before. Also opencode/antigravity need convert.sh run
  # at least once before install.sh can find agent files for them.
  local tool="$1" slug="$2" dest="$3"
  local vendor_dir="$HUB_DIR/vendor/agency-agents"
  ensure_converted "$tool"
  # install.sh prints "[!!]" warnings (e.g. the project-scoped notice) that can
  # make it exit non-zero even on a successful install — confirmed by real run:
  # file landed correctly at dest, but `set -e` killed the rest of `ash` before
  # state.json got written, so `ash clean`/`ash list` saw nothing. Don't let
  # install.sh's exit code propagate; verify success by checking $dest instead.
  ( cd "$PROJECT_ROOT" && "$vendor_dir/scripts/install.sh" --tool "$tool" --agent "$slug" ) || true

  if [ -f "$dest" ]; then
    return 0
  fi

  local fname; fname="$(basename "$dest")"
  local stray
  local known_homes=("$HOME/.claude" "$HOME/.copilot" "$HOME/.github" "$HOME/.gemini" "$HOME/.codex")
  stray=$(find "$vendor_dir" "$PROJECT_ROOT" "${known_homes[@]}" -name "$fname" -newer "$vendor_dir/scripts/install.sh" 2>/dev/null | grep -v "^$dest$" | head -n1)
  if [ -z "$stray" ]; then
    echo "ERROR: install.sh ran but '$fname' not found at dest ($dest), vendor dir, or project dir. Aborting — check install.sh output above manually." >&2
    exit 1
  fi
  echo "  [fixup] found at unexpected path — moving $stray -> $dest"
  mkdir -p "$(dirname "$dest")"
  mv "$stray" "$dest"
  find "$vendor_dir" -type d -empty -not -path "$vendor_dir" -delete 2>/dev/null || true
}

install_skill() {
  local slug="$1" dest="$2"
  local src; src=$(find "$HUB_DIR/vendor/skills/skills" -maxdepth 2 -type d -name "$slug" | head -n1)
  [ -n "$src" ] || { echo "ERROR: skill '$slug' not found" >&2; exit 1; }
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
}

# ---- interactive add --------------------------------------------------------
interactive_add() {
  local roles=(); mapfile -t roles < <(list_roles)
  [ ${#roles[@]} -gt 0 ] || { echo "Không có preset nào trong $PRESETS_DIR"; exit 1; }

  local labels=()
  for r in "${roles[@]}"; do labels+=("$r — $(role_description "$r")"); done
  print_menu "Chọn role (vd: 1,3):" "${labels[@]}"
  read -rp "> " role_sel
  local chosen_roles=()
  for i in $(parse_selection "$role_sel" "${#roles[@]}"); do chosen_roles+=("${roles[$((i-1))]}"); done
  [ ${#chosen_roles[@]} -gt 0 ] || { echo "Chưa chọn role nào."; exit 1; }

  print_menu "Bạn đang dùng tool nào cho project này (vd: 1,2):" "${ALL_TOOLS[@]}"
  read -rp "> " tool_sel
  local chosen_tools=()
  for i in $(parse_selection "$tool_sel" "${#ALL_TOOLS[@]}"); do chosen_tools+=("${ALL_TOOLS[$((i-1))]}"); done
  [ ${#chosen_tools[@]} -gt 0 ] || { echo "Chưa chọn tool nào."; exit 1; }

  declare -A tool_scope
  for t in "${chosen_tools[@]}"; do
    read -rp "  $t — cài (l)ocal project hay (g)lobal ~? [l/g]: " s
    local scope="local"; [[ "$s" =~ ^[Gg]$ ]] && scope="global"
    if ! scope_supported "$t" "$scope"; then
      local fallback="local"; [ "$t" = "codex" ] && fallback="global"
      echo "    ⚠ $t không hỗ trợ scope '$scope' theo tài liệu hiện có — dùng '$fallback' thay."
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

  echo ""
  echo "=== SẼ CÀI (${chosen_roles[*]}) ==="
  echo "$to_add" | jq -c '.[]' | while read -r it; do
    d=$(echo "$it" | jq -r '.dest'); pc=$(echo "$it" | jq -r '.path_confirmed')
    warn=""; [ "$pc" = "false" ] && warn="  [⚠ path chưa verify, kiểm tra lại sau khi cài]"
    echo "  + $d$warn"
  done
  echo ""
  echo "=== SẼ DỌN (không còn dùng nữa) ==="
  if [ "$(echo "$to_remove" | jq 'length')" -eq 0 ]; then
    echo "  (không có gì)"
  else
    echo "$to_remove" | jq -c '.[]' | while read -r it; do
      d=$(echo "$it" | jq -r '.dest'); sc=$(echo "$it" | jq -r '.scope')
      echo "  - $d  [$sc]"
    done
  fi
  echo ""
  confirm "Xác nhận thực hiện đúng như trên?" || { echo "Đã huỷ, không có gì thay đổi."; exit 0; }

  # NOTE: previously `echo ... | while read` ran the loop in a SUBSHELL —
  # any failure inside (e.g. install_skill not finding a skill) vanished
  # silently instead of stopping the script, and state.json never got
  # written even though installs partly succeeded. Using process
  # substitution keeps the loop in the current shell so errors surface.
  while read -r item; do
    kind=$(echo "$item" | jq -r '.kind'); dest=$(echo "$item" | jq -r '.dest')
    scope=$(echo "$item" | jq -r '.scope'); slug=$(echo "$item" | jq -r '.slug')
    tool=$(echo "$item" | jq -r '.tool'); companion=$(echo "$item" | jq -r '.companion // false')
    if [ "$companion" = "true" ]; then
      : # already written on disk by the primary item's install.sh call — just track for cleanup
    elif [ "$kind" = "agent" ]; then install_agent "$tool" "$slug" "$dest"
    else install_skill "$slug" "$dest"; fi
    [ "$scope" = "global" ] && registry_incref "$dest"
  done < <(echo "$to_add" | jq -c '.[]')
  while read -r item; do
    dest=$(echo "$item" | jq -r '.dest'); scope=$(echo "$item" | jq -r '.scope')
    if [ "$scope" = "global" ]; then registry_decref_and_maybe_delete "$dest"; else rm -rf "$dest"; fi
  done < <(echo "$to_remove" | jq -c '.[]')

  jq -n --argjson roles "$(printf '%s\n' "${chosen_roles[@]}" | jq -R . | jq -s .)" --argjson items "$new_items" \
    '{roles:$roles, items:$items}' > "$PROJECT_STATE"
  echo "Xong. Active roles: ${chosen_roles[*]}"
}

# ---- interactive clean: hỏi rõ dọn gì, không xoá hết mặc định -------------
interactive_clean() {
  local items; items=$(jq -c '.items' "$PROJECT_STATE")
  local count; count=$(echo "$items" | jq 'length')
  if [ "$count" -eq 0 ]; then echo "Project này chưa cài gì qua ash."; exit 0; fi

  local labels=() dests=()
  while read -r it; do
    d=$(echo "$it" | jq -r '.dest'); sc=$(echo "$it" | jq -r '.scope')
    labels+=("$d  [$sc]"); dests+=("$d")
  done < <(echo "$items" | jq -c '.[]')

  print_menu "Đang cài những mục sau — chọn mục muốn DỌN (vd: 1,2 hoặc 'all'):" "${labels[@]}"
  read -rp "> " sel
  local remove_idx=()
  if [ "$sel" = "all" ]; then
    for i in "${!dests[@]}"; do remove_idx+=("$((i+1))"); done
  else
    mapfile -t remove_idx < <(parse_selection "$sel" "${#dests[@]}")
  fi
  [ ${#remove_idx[@]} -gt 0 ] || { echo "Không chọn gì, huỷ."; exit 0; }

  echo "Sẽ DỌN:"
  for i in "${remove_idx[@]}"; do echo "  - ${labels[$((i-1))]}"; done
  confirm "Xác nhận?" || { echo "Đã huỷ."; exit 0; }

  local remaining="$items"
  for i in "${remove_idx[@]}"; do
    dest="${dests[$((i-1))]}"
    scope=$(echo "$items" | jq -r --arg d "$dest" '.[] | select(.dest==$d) | .scope')
    if [ "$scope" = "global" ]; then registry_decref_and_maybe_delete "$dest"; else rm -rf "$dest"; fi
    remaining=$(echo "$remaining" | jq --arg d "$dest" '[.[] | select(.dest != $d)]')
  done
  jq --argjson items "$remaining" '.items = $items' "$PROJECT_STATE" > "$PROJECT_STATE.tmp"
  mv "$PROJECT_STATE.tmp" "$PROJECT_STATE"
  echo "Xong."
}

case "${1:-add}" in
  add)   interactive_add ;;
  clean) interactive_clean ;;
  list)
    count=$(jq -r '.items | length' "$PROJECT_STATE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
      echo "(chưa cài gì qua ash trong project này)"
    else
      echo "Roles: $(jq -r '.roles | join(", ")' "$PROJECT_STATE")"
      jq -r '.items[] | "  \(.dest)  [\(.scope)]"' "$PROJECT_STATE"
    fi
    ;;
  *) echo "usage: ash <add|clean|list>" >&2; exit 1 ;;
esac
