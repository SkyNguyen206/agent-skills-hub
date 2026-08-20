# AGENTS.md

Personal hub that installs agent skills + role agents into AI coding tools (opencode, claude-code, copilot, gemini-cli, antigravity, cursor, codex) per project. The main interface is the `ash` CLI; this repo has no build, test, or lint pipeline of its own.

## The `ash` CLI (`scripts/ash.sh`)

- Commands: `ash setup | add | clean | list | check | update`. `setup` copies the script to `~/bin/ash` (no-arg run prints usage).
- Requires `jq`; `fzf` is optional (falls back to numbered menus).
- **Run `ash` from the target project's directory** (`PROJECT_ROOT="$(pwd)"`), not from the hub — state is written into `<cwd>/.ash/state.json`. The hub location defaults to `$HOME/agent-skills-hub`, override with `ASH_HUB_DIR`.
- `add` is interactive: pick role preset(s) → tool(s) → per-tool scope (l/g), then it diffs against current state and installs/removes.
- `check` validates the vendor contract: `ash check` (roster/presets/custom/agents) and `ash check dest [--tool T|all] [--full]` (sandboxed install vs `dest_for_*()`). `ash update` = `git submodule update` then runs both.
- Verify syntax with `bash -n scripts/ash.sh`. No test suite exists.

## Layout & ownership

- `custom/skills/<slug>/` — hand-rolled skills. Symlinked directly by `install_skill`. **If a slug exists in both `custom/` and `vendor/skills/`, custom silently wins** (a warning is printed) — this is the intended override point.
- `custom/agents/` — **reserved, not wired in**. Agent install always goes through vendor's `convert.sh`/`install.sh` pipeline; don't try to symlink a raw agent file into a tool dir.
- `presets/roles/*.json` — role → `{agents: [{division, slug}], skills: [{slug, repo}]}`. The `repo` field is **metadata only** — `ash` resolves skills from `custom/skills/` and `vendor/skills/skills/`, ignoring `repo`.
- `vendor/skills` and `vendor/agency-agents` — git submodules, **read-only by design**. Updates come only via `git submodule update`; never edit files inside `vendor/`.

## Agent install quirks (verified against vendor scripts)

- `division` in a preset is only a filter dimension. **Vendor SOURCE basenames are arbitrary and unrelated to the slug** — some are `<division>-<slug>.md` (`engineering-data-engineer.md`), some bare (`business-strategist.md`), one is word-reversed (`project-manager-senior.md` for slug `senior-project-manager`); the slug comes from the frontmatter `name:` field (vendor's `agent_slug`). `ash` adopts ONE convention for every tool — bare `<slug>.md` — and `install_agent`'s `[fixup]` renames whatever the vendor produced (exact basename → slug substring → frontmatter-name lookup). Real roster: `cd vendor/agency-agents && ./scripts/install.sh --list agents`.
- `opencode`, `antigravity`, `cursor`, `codex`, `gemini-cli` need `convert.sh` run before `install.sh` finds agents — `ash` caches this in `vendor/agency-agents/integrations/<tool>/`. The cache is checked for "any file other than the committed README.md", so it can go stale; `ash` heals by forcing a reconvert and retrying install once (the heal deletes only convert output, never the tracked README.md).
- `claude-code`, `copilot`, `gemini-cli`, `antigravity` install **agents globally only** regardless of requested scope (skills still honor scope). For `antigravity`, agents land as skill dirs under `~/.gemini/config/skills/agency-<slug>/SKILL.md` — the only global path all Antigravity surfaces read.
- `copilot` copies vendor **source** files verbatim into BOTH `~/.copilot/agents/` and `~/.github/agents/`; the fixup renames both copies to the bare `<slug>.md` convention (the `.github` one is the "companion" entry `ash clean` tracks). `claude-code` copies the same source files into `~/.claude/agents/`.
- Both vendor `install.sh` and `convert.sh` can print warnings and exit non-zero on a *successful* run — `ash` verifies by checking the dest file, not the exit code. Prefer the same when touching this pipeline. Same caution applies to `find` pipelines under `ash.sh`'s `set -euo pipefail`: `find` exits 1 on a missing start path (e.g. a fresh `~/.claude`), which silently kills the whole script — every such pipeline needs `|| true`.
- Per-tool dest paths live in `dest_for_agent()`/`dest_for_skill()`. `cursor` is project-scope only; `codex` is global-only for agents. `ash check dest` installs in a sandbox and asserts every preset agent lands at its `dest_for_*()` path — the arbiter of "does the fixup still work after a vendor update".

## Contract checks (`ash check`, `ash update`)

- `ash check` parses the real roster from `install.sh --list agents`, then verifies: every preset agent resolves to roster ∪ `custom/agents` (`<division>-<slug>.md`), every preset skill to `custom/skills/` ∪ `vendor/skills/skills/`, custom agent files follow the convention, and convert caches aren't stale (WARN only — installs still heal). Fails loudly on drift.
- `ash check dest` runs `install_agent`/`install_skill` in a `mktemp -d` sandbox (`HOME`/`PROJECT_ROOT` pointed inside) and asserts the bare-`<slug>.md` dest + the copilot `.github` companion. `--full` covers the whole roster; default samples preset agents. A slug that doesn't exist in the roster fails here — fix the preset, not the code.
- `ash update` = `git submodule update --init --recursive` → `check` → `check dest` (skip dest with `--fast`). It never auto-fixes drift.

## State

- Per project: `<project>/.ash/state.json` — `{roles: [...], items: [{kind, slug, dest, scope, tool, ...}]}`.
- Global: `~/.ash/registry.json` — refcounts every global-scope install keyed by dest path; a global item is deleted when the last referencing project removes it. Don't hand-edit.

## Working inside `vendor/`

If a task requires touching the vendor repos (e.g. verifying a slug), their own instruction files apply: `vendor/skills/AGENTS.md` and `vendor/agency-agents/CONTRIBUTING.md`. Remember they're submodules — changes there belong in those upstream repos.