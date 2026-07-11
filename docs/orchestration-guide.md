# The Herding Guide — running many Claude Code agents well

Shepherd shows you every Claude Code session on your machine. This guide is about
what to *do* with that visibility: how to split work across sessions, teammates,
subagents and background workers, which model to give each of them, and how to read
the board so your attention goes where it's needed.

Everything here works with plain Claude Code — Shepherd just makes it observable.

---

## 1. Pick the right vehicle for each task

There are four ways to run an agent, and they differ in who consumes the result
and whether a human can step in mid-flight:

| Vehicle | Runs as | Human can intervene? | Result goes to | Shepherd shows |
|---|---|---|---|---|
| **Interactive session** (zellij pane / terminal window) | Own process | Yes — attach, type, approve prompts | You | Full card: reply, capture, drag & drop, close |
| **Teammate** (agent teams) | In-process, inside the lead session | Only via the lead (mailbox relay) | The lead Claude | Nested card under the parent while working |
| **Subagent** (Agent tool) | In-process, inside the parent session | No | The parent Claude | Nested card while working |
| **Background worker** (`claude --bg`) | Own process, no terminal | Yes — `claude attach`, or reply from Shepherd | Whoever attaches / the files it wrote | Card with `BG` chip; blocked questions come from the daemon socket |

Rules of thumb:

- **You own the outcome and might steer it?** Interactive session. Long-lived
  workstreams, anything with permission prompts or plan approvals you want to
  answer yourself, work you'll resume tomorrow.
- **A lead Claude orchestrates and integrates the results?** Teammates (or
  subagents for read-only fan-outs). Splitting N issues across N workers, parallel
  research, design drafts — the lead consumes the reports and you only review the
  synthesis.
- **Fire-and-forget with a definite end?** Background worker. Remember it holds
  real memory while parked (~600 MB measured) — Shepherd's *parked* chip exists
  to catch the ones you forgot to stop.
- If there's *any* chance you'll want to interject mid-task, prefer a separate
  session over a teammate — teammates have no attach route; their questions reach
  you only through the lead.

## 2. Don't run the whole flock on one model

Model choice is the biggest cost lever in a multi-agent setup, and the default
behavior works against you: **subagents inherit the parent's model when you don't
specify one.** Run your lead on a frontier model, spawn ten workers, and you're
paying frontier price for grep.

Anthropic's own multi-agent research system uses exactly this split — a frontier
orchestrator with cheaper workers — and their guidance is to match the tier to the
subtask, not to the parent ([How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)).

Pricing anchors (per 1M tokens, July 2026 — see [current pricing](https://platform.claude.com/docs/en/pricing)):

| Model | Input / Output | Give it |
|---|---|---|
| **Fable 5** | $10 / $50 | The lead. Task decomposition, integration, the judgment calls. |
| **Opus 4.8** | $5 / $25 | Hard or ambiguous implementation, deep review, debugging. |
| **Sonnet 5** | $3 / $15 (intro $2 / $10 through 2026-08) | Well-specified implementation, shipping chores: CI fixes, review rounds, mechanical refactors. |
| **Haiku 4.5** | $1 / $5 | Exploration, search fan-outs, classification, summarize-and-report. |

A Fable lead is 10× Haiku. A board where every model chip is the same color is
usually money left on the table — that's why Shepherd puts the tier on every card.

How to specify, per vehicle:

```sh
# Subagent — the Agent tool's model parameter
Agent(..., model: "haiku")            # 'haiku' | 'sonnet' | 'opus' | 'fable'

# Teammate — say it in the spawn instruction, or set a default once:
#   /config → "Default teammate model"

# Background worker
claude --bg --model sonnet -p "..."

# Blanket default for all subagents (settings.json env)
CLAUDE_CODE_SUBAGENT_MODEL=sonnet
```

The exception that proves the rule: single high-stakes judgments (a design
tiebreak, a final review before merge) deserve the big model even inside a cheap
pipeline. If re-verifying the output is cheap, use a cheap model; if a wrong answer
is expensive to detect, pay for the good one.

## 3. Keep lineage visible

Shepherd nests children under parents so a 10-agent board still reads as 3
workstreams. In-process teammates and subagents nest automatically (detected from
the transcript). For a **separate process** — launching a new interactive session
or background worker from inside a session — export the parent's session id first:

```sh
SHEPHERD_PARENT_SESSION_ID=<parent-session-id> claude ...
```

This is Shepherd's own convention (read from the child's environment via `ps`),
not an official Claude Code variable. Fork/resume lineage needs nothing — Shepherd
detects forks from transcript fingerprints and marks them with a branch icon.

## 4. Let the board drive your attention

The board is sorted by urgency, so the operating loop is simple: *if nothing is
orange, keep doing your own work.*

| Signal | Meaning | Do |
|---|---|---|
| **Orange banner** with `? …` | Agent is blocked on a question or permission | Answer it — right-click → Reply, or click through to the pane. This is the only thing that actually needs you. |
| **Context gauge** yellow (60%) / red (85%) | The window is filling | Wrap up, or have the agent write a handoff and start a fresh session. Quality degrades before the hard limit. |
| ***parked* chip**, escalating with a duration | A live background worker sitting idle | Stop it (right-click → close) unless you're about to attach. Parked workers are pure memory burn. |
| **`stale?`** | Looks busy but no transcript movement for 2+ min | Probably interrupted (Esc) — attach and check. |
| **Amber dog-ear** | Uncommitted changes in that worktree | Fine while working; a reminder before you close anything. |
| Model chips all one color | Nobody chose models | See §2. |

## 5. A worked example

Shipping four groomed issues in parallel (this is the `/herd-issues` pattern —
adapt freely):

1. **Lead session** (Fable/Opus, interactive — this is you and the orchestrator):
   creates one git worktree per issue. Isolated worktrees mean four agents can't
   step on each other's checkouts.
2. **Implementation teammates** (Opus; Sonnet for the well-specified ones), one per
   issue, each pointed at its own worktree. On the board: four cards nested under
   the lead, each with its own branch, changed-file count and context gauge.
3. Watch the board, not the terminals. When a teammate goes orange, the question
   is on the card; relay the answer and go back to your own work.
4. **Ship teammates** (Sonnet) take over per-issue as implementation lands: commit,
   push, PR, CI fixes, review rounds. Mechanical work, cheap model, fresh context.
5. Finished background records fold into the archive lane. PR badges on the cards
   turn green as CI passes — that's your merge queue.

The lead never edits code. Cheap models do the wide work, expensive models do the
deep work, and the only human interrupts are the orange cards.

---

*See also: [README](../README.md) for setup, [Stream Deck](stream-deck.md) for the
hardware companion.*
