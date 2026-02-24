---
name: dev-gsd
description: Orchestrate Claude Code with GSD framework for multi-phase development. Features full-auto mode, human-centric browser verification, and batched question escalation.
---

# Dev-GSD: Autonomous Development Framework

This skill teaches the agent how to orchestrate the **GSD (get-shit-done)** CLI installed at `~/.claude/get-shit-done/` to execute complex, multi-phase development tasks.

## Core Principles

1. **Full-Auto by Default**: The agent is a partner, not an assistant. It uses its best judgment to answer GSD's `/gsd:discuss-phase` questions, drafts them for Andrew, and auto-proceeds if no objection is received within 10 minutes.
2. **Real-Life Verification**: Completion is not "tests passed." Completion is "I used the browser, clicked the buttons, verified the data, and it works for a human user."
3. **Phase Continuity**: Auto-advance through GSD phases (discuss -> plan -> execute -> verify) without waiting for permission unless a critical blocker is reached.
4. **Thin Orchestration**: Run Claude Code in a background PTY session; monitor logs; pipe context in and results out.

## Workflow

### 1. Initialization
When a dev task is assigned:
- Identify the project root.
- Spawn a background Claude Code session with PTY:
  ```bash
  bash pty:true workdir:<repo> background:true command:"claude --dangerously-skip-permissions"
  ```
- Trigger GSD:
  ```bash
  process action:submit sessionId:<ID> data:"/gsd:discuss-phase"
  ```

### 2. Discuss Phase (Autonomous Drafting)
GSD will generate "Gray Area" questions. 
- **Action**: Read the questions from the Claude log.
- **Action**: Research the codebase and Andrew's `MEMORY.md` to draft answers.
- **Action**: Write the questions + your drafted answers to `_handoff/dev-questions.json`.
- **Action**: Notify Andrew: "GSD has 5 questions. I've drafted my best guesses here. I'll auto-proceed with these in 10 minutes unless you tweak them."
- **Logic**: Use `cron` to schedule a wake event in 10 mins. If no answer is received, submit the drafted answers to Claude and move to `/gsd:plan-phase`.

### 3. Plan Phase (Auto-Approval)
- Review the generated `ROADMAP.md` and `VALIDATION.md`.
- Ensure `VALIDATION.md` includes human-centric browser tests (e.g., "Login via UI and check dashboard state").
- If the plan is logical, auto-submit `approve` to Claude.

### 4. Execute Phase (Autonomous Execution)
- Monitor the execution. 
- Follow GSD deviation rules: auto-fix bugs, add critical handlers, and resolve blockers.
- Only escalate if an architectural change is required that contradicts `CONTEXT.md`.

### 5. Verify Phase (Real-Life Data)
GSD's automated tests are Step 1. Step 2 is **Real-Life Verification**:
- **Mandatory**: Use the `browser` tool (with `profile: "chrome"`) to actually test the implementation.
- **Scenario**: If fixing a 502 error on a RAG tool, open the CallVault UI, trigger the tool, and verify the data renders correctly on screen.
- **Snapshot**: Take a screenshot of the successful verification and include it in the final summary.

## Communication Pattern

### Semi-Auto vs. Full-Auto
- **Full-Auto (Default)**: Report progress, draft answers, auto-proceed on 10-min timeout.
- **Semi-Auto**: Explicitly requested by Andrew. Agent stops and waits for "approve" or "continue" at every phase boundary.

### Escalation JSON Schema
Maintain `_handoff/dev-questions.json` with the following:
```json
{
  "id": "dev-q-001",
  "status": "drafted|answered|processed",
  "auto_proceed_at": "ISO-TIMESTAMP",
  "questions": [
    {
      "id": "q1",
      "question": "...",
      "suggested_answer": "...",
      "rationale": "Why I think this is the right call",
      "user_override": null
    }
  ]
}
```

## Tools Mapping
- **Orchestrator**: Opus (Decision making, log parsing, synthesis).
- **Sub-Agents**: GSD's internal executors handle the grunt work.
- **Verification**: `browser` (OpenClaw) + `gsd-verifier` (CLI).

## Rules
1. **Never wait** for approval on routine implementation details.
2. **Always test as a human** using the browser before declaring "Done."
3. **Context Reset**: Ensure the background Claude session is fresh for each new milestone to prevent context rot.
4. **Git Commits**: Use `gsd-tools.cjs` or direct bash to commit at every phase completion.
