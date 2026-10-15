const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../prototype/app.js"), "utf8");

function openPrototype() {
  let now = Date.UTC(2026, 9, 13, 11, 30);
  const listeners = new Map();
  const nodes = new Map();
  class MockDate extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }
  const document = {
    querySelector(selector) {
      if (!nodes.has(selector)) nodes.set(selector, {
        innerHTML: "", textContent: "", value: "",
        classList: { add() {}, remove() {} }
      });
      return nodes.get(selector);
    },
    querySelectorAll() { return []; },
    addEventListener(type, listener) { listeners.set(type, listener); }
  };
  const context = vm.createContext({
    document, Date: MockDate, console,
    setTimeout() { return 1; }, clearTimeout() {},
    setInterval() { return 1; }
  });
  context.window = context;
  vm.runInContext(source, context, { filename: "prototype/app.js" });
  return {
    click(dataset) { listeners.get("click")({ target: { closest: () => ({ dataset }) } }); },
    advance(ms) { now += ms; },
    read(expression) { return JSON.parse(vm.runInContext(`JSON.stringify(${expression})`, context)); },
    run(expression) { vm.runInContext(expression, context); }
  };
}

const quick = (page, kind) => page.click({ action: "quick-score", quick: kind });
const lastScore = (page) => page.read('state.liveMatch.events.filter(event => event.type === "scoreEvent").at(-1)');
const personal = (page) => page.read('({ goals: state.liveMatch.events.filter(event => event.scorer === "self").length, assists: state.liveMatch.events.filter(event => event.assister === "self").length })');

test("Watch provides four quick buttons; my goal records immediately without a modal", () => {
  const page = openPrototype();
  const html = page.read("renderWatch()");
  assert.deepEqual([...html.matchAll(/data-quick="([^"]+)"/g)].map(match => match[1]), ["mine", "assist", "for", "against"]);
  const before = page.read("scoreOf(state.liveMatch)");
  const stats = personal(page);
  quick(page, "mine");
  assert.equal(page.read("state.modal"), null);
  assert.deepEqual(page.read("scoreOf(state.liveMatch)"), { for: before.for + 1, against: before.against });
  assert.equal(lastScore(page).scorer, "self");
  assert.equal(lastScore(page).assister, null);
  assert.deepEqual(personal(page), { goals: stats.goals + 1, assists: stats.assists });
  assert.deepEqual(page.read("state.quickRecord"), { eventId: lastScore(page).id, matchId: "live-01", label: "我进球" });
});

test("assist, team goal and conceded goal use the correct score and personal attribution", () => {
  const page = openPrototype();
  const before = page.read("scoreOf(state.liveMatch)");
  const stats = personal(page);
  quick(page, "assist");
  assert.equal(lastScore(page).impact, "for");
  assert.equal(lastScore(page).scorer, null);
  assert.equal(lastScore(page).assister, "self");
  page.advance(1001);
  quick(page, "for");
  assert.equal(lastScore(page).impact, "for");
  assert.equal(lastScore(page).scorer, null);
  assert.equal(lastScore(page).assister, null);
  page.advance(1001);
  quick(page, "against");
  assert.equal(lastScore(page).impact, "against");
  assert.equal(lastScore(page).scorer, null);
  assert.equal(lastScore(page).assister, null);
  assert.equal(page.read("state.modal"), null);
  assert.deepEqual(page.read("scoreOf(state.liveMatch)"), { for: before.for + 2, against: before.against + 1 });
  assert.deepEqual(personal(page), { goals: stats.goals, assists: stats.assists + 1 });
});

test("undo restores score and personal totals once and preserves the preceding record", () => {
  for (const [preceding, latest] of [["mine", "assist"], ["assist", "mine"]]) {
    const page = openPrototype();
    quick(page, preceding);
    const precedingId = lastScore(page).id;
    const scoreBeforeLast = page.read("scoreOf(state.liveMatch)");
    const statsBeforeLast = personal(page);
    page.advance(1001);
    quick(page, latest);
    const removedId = lastScore(page).id;
    page.click({ action: "undo-score" });
    assert.deepEqual(page.read("scoreOf(state.liveMatch)"), scoreBeforeLast);
    assert.deepEqual(personal(page), statsBeforeLast);
    assert.equal(page.read(`state.liveMatch.events.some(event => event.id === ${JSON.stringify(removedId)})`), false);
    assert.equal(page.read(`state.liveMatch.events.some(event => event.id === ${JSON.stringify(precedingId)})`), true);
    assert.equal(page.read("state.quickRecord"), null);
    const afterUndo = page.read("state.liveMatch.events");
    page.click({ action: "undo-score" });
    assert.deepEqual(page.read("state.liveMatch.events"), afterUndo);
  }
});

test("all quick buttons share a one second duplicate guard, then accept another record", () => {
  const page = openPrototype();
  const before = page.read("state.liveMatch.events.length");
  quick(page, "mine");
  quick(page, "mine");
  page.advance(999);
  quick(page, "against");
  assert.equal(page.read("state.liveMatch.events.length"), before + 1);
  page.advance(2);
  quick(page, "against");
  assert.equal(page.read("state.liveMatch.events.length"), before + 2);
  assert.equal(lastScore(page).impact, "against");
});

test("undo allows an immediate correction even inside the duplicate guard interval", () => {
  const page = openPrototype();
  const before = page.read("scoreOf(state.liveMatch)");
  const stats = personal(page);
  quick(page, "mine");
  page.click({ action: "undo-score" });
  quick(page, "against");
  assert.deepEqual(page.read("scoreOf(state.liveMatch)"), { for: before.for, against: before.against + 1 });
  assert.deepEqual(personal(page), stats);
  assert.equal(lastScore(page).impact, "against");
  assert.equal(page.read("state.quickRecord.eventId"), lastScore(page).id);
  assert.equal(page.read("state.modal"), null);
});

test("ending and starting a match clears old undo state and accepts the first new record", () => {
  const page = openPrototype();
  quick(page, "mine");
  page.click({ action: "confirm-end" });
  assert.equal(page.read("state.liveMatch"), null);
  assert.equal(page.read("state.quickRecord"), null);
  assert.equal(page.read("state.lastQuickScoreAtMs === -Infinity"), true);
  const finishedEvents = page.read("state.history[0].events");
  page.click({ action: "undo-score" });
  assert.deepEqual(page.read("state.history[0].events"), finishedEvents);
  page.click({ action: "new-match" });
  page.click({ action: "confirm-start" });
  assert.equal(page.read("state.quickRecord"), null);
  quick(page, "assist");
  assert.deepEqual(page.read("scoreOf(state.liveMatch)"), { for: 1, against: 0 });
  assert.deepEqual(personal(page), { goals: 0, assists: 1 });
  assert.equal(lastScore(page).matchSecond, 0);
  assert.deepEqual(page.read("state.history[0].events"), finishedEvents);
});

test("Watch quick records still target the live match while the phone shows historical detail", () => {
  const page = openPrototype();
  page.click({ historyId: "m-0912" });
  const historyBefore = page.read("state.history");
  const liveBefore = page.read("state.liveMatch.events.length");
  quick(page, "mine");
  assert.deepEqual(page.read("state.history"), historyBefore);
  assert.equal(page.read("state.detailMatchId"), "m-0912");
  assert.equal(page.read("state.liveMatch.events.length"), liveBefore + 1);
  assert.equal(lastScore(page).scorer, "self");
  assert.equal(page.read("state.modal"), null);
});

test("with no active match, quick record and undo cannot change historical data", () => {
  const page = openPrototype();
  page.run('state.liveMatch = null; state.detailMatchId = "m-0912";');
  const before = page.read("state.history");
  quick(page, "mine");
  page.click({ action: "undo-score" });
  assert.deepEqual(page.read("state.history"), before);
  assert.equal(page.read("state.modal"), null);
  assert.equal(page.read("state.liveMatch"), null);
});

test("quick record timestamps respect the live clock, field changes and match pauses", () => {
  const page = openPrototype();
  page.advance(2500);
  quick(page, "mine");
  assert.equal(lastScore(page).matchSecond, 52 * 60 + 2.5);
  page.advance(1001);
  page.click({ action: "toggle-field" });
  const offField = page.read("({ match: matchSeconds(state.liveMatch), appearance: appearanceSeconds(state.liveMatch) })");
  page.advance(2000);
  assert.equal(page.read("matchSeconds(state.liveMatch)"), offField.match + 2);
  assert.equal(page.read("appearanceSeconds(state.liveMatch)"), offField.appearance);
  page.click({ action: "pause" });
  const paused = page.read("({ match: matchSeconds(state.liveMatch), appearance: appearanceSeconds(state.liveMatch) })");
  page.advance(10000);
  quick(page, "against");
  assert.equal(lastScore(page).matchSecond, paused.match);
  assert.equal(page.read("matchSeconds(state.liveMatch)"), paused.match);
  assert.equal(page.read("appearanceSeconds(state.liveMatch)"), paused.appearance);
  page.click({ action: "resume" });
  page.advance(2000);
  assert.equal(page.read("matchSeconds(state.liveMatch)"), paused.match + 2);
  assert.equal(page.read("appearanceSeconds(state.liveMatch)"), paused.appearance);
  page.click({ action: "toggle-field" });
  page.advance(1000);
  assert.equal(page.read("appearanceSeconds(state.liveMatch)"), paused.appearance + 1);
});

test("historical own-goal supplementation and deletion recalculate the result while preserving unlisted goals", () => {
  const page = openPrototype();
  const summary = () => page.read('({ final: state.history[0].final, result: state.history[0].result })');
  const liveBefore = page.read("state.liveMatch.events");
  page.click({ historyId: "m-0912" });
  assert.deepEqual(summary(), { final: "3 - 2", result: "win" });
  page.click({ action: "add-event" });
  page.click({ scoreKind: "ownGoal" });
  page.click({ scoreImpact: "against" });
  page.click({ action: "confirm-score" });
  const added = page.read('state.history[0].events.find(event => event.type === "scoreEvent" && event.kind === "ownGoal")');
  assert.equal(added.impact, "against");
  assert.deepEqual(summary(), { final: "3 - 3", result: "draw" });
  assert.deepEqual(page.read("state.liveMatch.events"), liveBefore);
  page.click({ eventId: added.id });
  page.click({ action: "delete-event" });
  assert.deepEqual(summary(), { final: "3 - 2", result: "win" });
  assert.deepEqual(page.read("state.liveMatch.events"), liveBefore);
  assert.deepEqual(page.read("scoreOf(state.liveMatch)"), { for: 2, against: 1 });
});

test("deleting a listed historical goal subtracts just that goal from the saved final score", () => {
  const page = openPrototype();
  page.click({ historyId: "m-0912" });
  page.click({ eventId: "h3" });
  page.click({ action: "delete-event" });
  assert.equal(page.read('state.history[0].events.some(event => event.id === "h3")'), false);
  assert.deepEqual(page.read('({ final: state.history[0].final, result: state.history[0].result })'), { final: "2 - 2", result: "draw" });
  assert.deepEqual(page.read("scoreOf(state.liveMatch)"), { for: 2, against: 1 });
});
