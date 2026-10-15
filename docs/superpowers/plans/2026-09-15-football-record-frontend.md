# Football Record Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a browser-runnable UI prototype that lets a user inspect the football record app and click through the core match recording and post-match correction flows.

**Architecture:** A dependency-free static prototype with a single state store in `prototype/app.js`, semantic markup rendered into a phone and watch simulator, and CSS tokens in `prototype/styles.css`. Mock match data is seeded in memory; user actions mutate state and rerender, with no backend or Apple framework dependencies.

**Tech Stack:** HTML5, CSS3, vanilla JavaScript (ES2022), Python `http.server` for local preview.

---

### Task 1: Establish workflow and design artifacts

**Files:**
- Create: `.czy-workflow/runtime/runs/2026-09-15-solo-product-ui/` state and audit artifacts
- Create: `docs/ui-ux-spec.md`
- Create: `docs/frontend-implementation-plan.md`
- Create: `docs/ui-prototype-validation.md`

- [ ] Record the UI-first decision, mock-data scope, and browser preview acceptance criteria.
- [ ] Define four iPhone tabs, watch states, event actions, empty/error states, and accessibility rules.
- [ ] Mark Apple APIs and CloudKit as deferred integrations for the prototype.

### Task 2: Implement responsive visual shell

**Files:**
- Create: `prototype/index.html`
- Create: `prototype/styles.css`

- [ ] Build a responsive dark sports dashboard with phone and watch frames.
- [ ] Provide tab navigation, status chips, event timeline, stat cards, and modal surfaces.
- [ ] Support desktop split view and a stacked mobile layout at 375px.

### Task 3: Implement interactive mock state

**Files:**
- Create: `prototype/app.js`

- [ ] Seed one completed match and one live match with realistic events and stats.
- [ ] Implement tab switching, live match start, starter/substitute choice, pause/resume, enter/leave field, score event selection, match end, history detail, event edit/delete, and career aggregation.
- [ ] Keep score and appearance totals derived from the event list after every mutation.
- [ ] Show confirmation feedback and unavailable-data states without claiming zero values.

### Task 4: Verify runnable interactions

**Files:**
- Create: `tests/prototype-smoke.md`

- [ ] Start `python3 -m http.server 4173 --directory prototype`.
- [ ] Verify the page loads, all primary controls respond, and no console errors occur.
- [ ] Verify desktop and 375px layouts visually, then document observed results and remaining native Apple integration gaps.
