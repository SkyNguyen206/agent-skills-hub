# Agent Skills Hub

Personal hub that installs agent skills + role agents into AI coding tools (opencode, claude-code, copilot, gemini-cli, antigravity, cursor, codex) per project. The main interface is the `ash` CLI.

## Installation

```bash
# 1. clone the hub
git clone <repo-url> agent-skills-hub
cd agent-skills-hub

# 2. fetch the two vendor submodules (vendor/skills + vendor/agency-agents)
git submodule update --init --recursive

# 3. install the `ash` command into ~/bin (one-time)
./scripts/ash.sh setup
```

Requirements:

- `jq` — required
- `fzf` — optional (falls back to numbered menus)

If the hub lives somewhere other than `$HOME/agent-skills-hub`, point `ASH_HUB_DIR` at it.

## Quickstart

```bash
# one-time: install the `ash` command into ~/bin
./scripts/ash.sh setup

# use it from any project you want to equip
cd ~/your-project
ash add
```

`ash add` walks you through choosing role preset(s) → tool(s) → per-tool scope (l = local to project, g = global), diffs against current state, and installs/removes agents + skills accordingly.

## Commands

| Command | What it does |
| --- | --- |
| `ash setup` | Copies `scripts/ash.sh` to `~/bin/ash` (chmod +x). |
| `ash add` | Interactive install: pick role(s) → tool(s) → scope. |
| `ash clean` | Removes installed items for the current project. |
| `ash list` | Lists what is installed for the current project. |
| `ash check` | Validates the vendor contract (roster / presets / custom / agents). |
| `ash check dest` | Sandboxed install of every preset agent/skill, asserting it lands at the `dest_for_*()` path. `--full` covers the whole roster. |
| `ash update` | `git submodule update` then runs `check` + `check dest`. |

Always run `ash` from the target project's directory — state is written into `<cwd>/.ash/state.json`. The hub location defaults to `$HOME/agent-skills-hub`; override with `ASH_HUB_DIR`.

## Project layout

```
agent-skills-hub/
├── scripts/ash.sh          # the ash CLI
├── custom/
│   ├── skills/<slug>/      # hand-rolled skills (symlinked directly)
│   └── agents/             # reserved; not wired in
├── presets/roles/*.json    # role → {agents, skills}
├── vendor/
│   ├── skills/             # git submodule (read-only)
│   └── agency-agents/      # git submodule (read-only)
├── AGENTS.md               # agent-facing guide for working in this repo
└── .gitmodules
```

If a slug exists in both `custom/skills/` and `vendor/skills/`, the custom version wins (a warning is printed) — that is the intended override point.

## How install works

- **Skills** are symlinked from `custom/skills/` (or `vendor/skills/skills/`). Skills honor the requested scope (l/g) where the tool supports it.
- **Agents** go through the vendor `convert.sh` / `install.sh` pipeline, then `install_agent`'s `[fixup]` renames whatever the vendor produced to the bare `<slug>.md` convention. Vendor source basenames are arbitrary and unrelated to the slug (some are division-prefixed like `design-image-prompt-engineer.md`, some word-reversed like `project-manager-senior.md` for slug `senior-project-manager`); the slug comes from the frontmatter `name:` field.
- Per-tool destination paths live in `dest_for_agent()` / `dest_for_skill()`. Notable quirks:
  - `claude-code`, `copilot`, `gemini-cli`, `antigravity` install agents **globally only** regardless of scope (skills still honor scope).
  - `cursor` is project-scope only; `codex` is global-only for agents.
  - `copilot` writes both `~/.copilot/agents/` and a companion entry under `~/.github/agents/`; `ash clean` tracks both.

## Contract checks

`ash check` parses the real vendor roster from `vendor/agency-agents` and verifies every preset agent/skill resolves to a real source, custom agent files follow the convention, and convert caches aren't stale. It fails loudly on drift — fix the preset, not the code.

`ash check dest` runs `install_agent`/`install_skill` in a `mktemp -d` sandbox and asserts every preset agent lands at its `dest_for_*()` path (including the copilot `.github` companion). It is the arbiter of "does the fixup still work after a vendor update".

`ash update` = `git submodule update --init --recursive` → `check` → `check dest` (use `--fast` to skip the dest check). It never auto-fixes drift.

## State

- Per project: `<project>/.ash/state.json` — what roles and items are installed. (gitignored)
- Global: `~/.ash/registry.json` — refcounts every global-scope install keyed by dest path; a global item is deleted when the last referencing project removes it. Don't hand-edit.

## Notes

- Working inside `vendor/` is discouraged — both submodules are read-only by design; updates come only via `ash update`.
- `ash check`/`check dest` intentionally treat the vendor's `integrations/<tool>/` convert caches as regenerable: a stale cache is a WARN (and `ash add` heals it on the fly), never a failure on its own.