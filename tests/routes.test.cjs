const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../prototype/app.js"), "utf8");

function openPrototype({ storage = new Map() } = {}) {
  let now = Date.UTC(2026, 9, 14, 11, 30);
  const listeners = new Map();
  const nodes = new Map();
  const queryResults = new Map();
  const timers = new Map();
  let nextTimerId = 1;
  class MockDate extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }
  const context = vm.createContext({
    document: {
      querySelector(selector) {
        if (!nodes.has(selector)) nodes.set(selector, {
          innerHTML: "", textContent: "", value: "",
          classList: { add() {}, remove() {} }
        });
        return nodes.get(selector);
      },
      querySelectorAll(selector) { return queryResults.get(selector) || []; },
      addEventListener(type, listener) { listeners.set(type, listener); }
    },
    Date: MockDate, console,
    localStorage: {
      getItem(key) { return storage.has(String(key)) ? storage.get(String(key)) : null; },
      setItem(key, value) { storage.set(String(key), String(value)); },
      removeItem(key) { storage.delete(String(key)); },
      clear() { storage.clear(); },
      key(index) { return [...storage.keys()][index] ?? null; },
      get length() { return storage.size; }
    },
    setTimeout(callback, delay = 0) { const id = nextTimerId++; timers.set(id, { callback, due: now + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval() { return 1; }
  });
  context.window = context;
  vm.runInContext(source, context, { filename: "prototype/app.js" });
  return {
    click(dataset) { listeners.get("click")({ target: { closest: () => ({ dataset }) } }); },
    advance(ms) { now += ms; },
    setQueryResults(selector, result) { queryResults.set(selector, result); },
    flushTimers() {
      for (;;) {
        const due = [...timers.entries()].filter(([, timer]) => timer.due <= now).sort((a, b) => a[1].due - b[1].due)[0];
        if (!due) break;
        timers.delete(due[0]);
        due[1].callback();
      }
    },
    read(expression) { return JSON.parse(vm.runInContext(`JSON.stringify(${expression})`, context)); },
    run(expression) { vm.runInContext(expression, context); }
  };
}

function assertOnCanvas(points) {
  for (const point of points) {
    assert.equal(Number.isFinite(point.x), true);
    assert.equal(Number.isFinite(point.y), true);
    assert.ok(point.x >= 16 && point.x <= 304, `x=${point.x} must fit the route canvas`);
    assert.ok(point.y >= 16 && point.y <= 200, `y=${point.y} must fit the route canvas`);
  }
}

function makeHeatFixture(elapsed = Array.from({ length: 12 }, (_, index) => index * 10)) {
  return {
    events: [
      { type: "enteredField", matchSecond: 0, elapsedSecond: 0 },
      { type: "leftField", matchSecond: Math.max(...elapsed), elapsedSecond: Math.max(...elapsed) }
    ],
    route: { heatmapAvailable: true, points: elapsed.map(elapsedSecond => ({ latitude: 40, longitude: 116, elapsedSecond, horizontalAccuracy: 8 })) }
  };
}

const totalHeatSeconds = model => model.heatCells.reduce((total, cell) => total + cell.weight, 0);
const segmentPoints = segment => Array.isArray(segment) ? segment : segment.points;
const calibrationCorners = [
  { latitude: 40, longitude: 116 },
  { latitude: 40, longitude: 116.001 },
  { latitude: 40.0006, longitude: 116.001 },
  { latitude: 40.0006, longitude: 116 }
];

function makeMapFrame(tileCount = 2) {
  const status = { hidden: false, textContent: "地图加载中…" };
  const handlers = [];
  const frame = {
    querySelector(selector) { return selector === ".route-map-status" ? status : null; },
    querySelectorAll(selector) { return selector === ".route-tile" ? tiles : []; }
  };
  const tiles = Array.from({ length: tileCount }, (_, index) => {
    handlers[index] = new Map();
    return {
      dataset: {}, isConnected: true,
      classList: { contains(name) { return name === "route-tile"; } },
      closest(selector) { return selector === ".route-map-frame" ? frame : null; },
      addEventListener(type, handler) { handlers[index].set(type, handler); }
    };
  });
  return { status, tiles, fire(index, type) { handlers[index].get(type)({ target: tiles[index], type }); } };
}

test("legacy appearance minutes become HH:MM while missing data stays unrecorded", () => {
  const page = openPrototype();
  for (const [appearance, expected] of [["68 分钟", "01:08"], ["64 分钟", "01:04"], ["54 分钟", "00:54"], ["0 分钟", "00:00"], ["", "未记录"], ["未记录", "未记录"]]) {
    assert.equal(page.read(`formatAppearanceDuration({ appearance: ${JSON.stringify(appearance)} })`), expected);
  }
  assert.equal(page.read("formatAppearanceDuration({})"), "未记录");
  assert.equal(page.read("formatAppearanceDuration(null)"), "未记录");
});

test("native appearance duration uses actual field intervals and floors remaining seconds", () => {
  const page = openPrototype();
  page.run(`var nativeMatch = {
    status: "completed", startedAtMs: 0, finalMatchSeconds: 68 * 60 + 59.999,
    appearance: "999 分钟", events: [{ type: "enteredField", matchSecond: 0 }]
  };`);
  assert.equal(page.read("formatAppearanceDuration(nativeMatch)"), "01:08");
  page.run("nativeMatch.events.push({ type: 'leftField', matchSecond: 64 * 60 + 59 });");
  assert.equal(page.read("formatAppearanceDuration(nativeMatch)"), "01:04");
  page.run("nativeMatch.events = [];");
  assert.equal(page.read("formatAppearanceDuration(nativeMatch)"), "00:00");
});

test("distance is a unit-free numeric string and distinguishes zero from missing data", () => {
  const page = openPrototype();
  for (const [input, expected] of [["6.8 km", "6.8"], [" 5.2km ", "5.2"], [4.6, "4.6"], ["0 km", "0"], [0, "0"], ["0", "0"], ["", "未记录"], [null, "未记录"], ["未记录", "未记录"]]) {
    assert.equal(page.read(`formatDistanceKm(${JSON.stringify(input)})`), expected);
  }
  assert.equal(page.read("formatDistanceKm(undefined)"), "未记录");
});

test("route projection filters invalid coordinates, keeps zero, sorts time and does not mutate input", () => {
  const page = openPrototype();
  page.run(`var fixture = { route: { heatmapAvailable: true, points: [
    { latitude: 0.0001, longitude: 0.0001, elapsedSecond: 30 },
    { latitude: 91, longitude: 1, elapsedSecond: 1 },
    { latitude: 0, longitude: 0, elapsedSecond: 20 },
    { latitude: null, longitude: 0, elapsedSecond: 2 },
    { latitude: 0, longitude: 181, elapsedSecond: 3 },
    { latitude: NaN, longitude: 0, elapsedSecond: 4 },
    { latitude: 0, longitude: Infinity, elapsedSecond: 5 },
    { latitude: -0.0001, longitude: -0.0001, elapsedSecond: 10 }
  ] } };
  fixture.route.points.forEach(Object.freeze);
  Object.freeze(fixture.route.points);
  Object.freeze(fixture.route);`);
  const before = page.read("fixture");
  const model = page.read("createRouteModel(fixture)");
  assert.deepEqual(model.points.map(({ latitude, longitude, elapsedSecond }) => ({ latitude, longitude, elapsedSecond })), [
    { latitude: -0.0001, longitude: -0.0001, elapsedSecond: 10 },
    { latitude: 0, longitude: 0, elapsedSecond: 20 },
    { latitude: 0.0001, longitude: 0.0001, elapsedSecond: 30 }
  ]);
  assertOnCanvas(model.points);
  assert.equal(model.heatAvailable, false);
  assert.deepEqual(page.read("fixture"), before);
});

test("single points and repeated coordinates stay finite; missing routes produce no invented track", () => {
  const page = openPrototype();
  const one = { route: { heatmapAvailable: true, points: [{ latitude: 40, longitude: 116, elapsedSecond: 0 }] } };
  const repeated = { route: { heatmapAvailable: true, points: [0, 5, 10].map(elapsedSecond => ({ latitude: 40, longitude: 116, elapsedSecond })) } };
  for (const fixture of [one, repeated]) {
    const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
    assert.equal(model.points.length, fixture.route.points.length);
    assertOnCanvas(model.points);
    assert.equal(model.heatAvailable, false);
  }
  for (const match of [{}, { route: { points: [], heatmapAvailable: true } }]) {
    const model = page.read(`createRouteModel(${JSON.stringify(match)})`);
    assert.deepEqual(model.points, []);
    assert.deepEqual(model.heatCells, []);
    assert.equal(model.heatAvailable, false);
  }
});

test("heat cells aggregate time spent in a region and normalize intensity", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  fixture.route.points.reverse();
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.heatAvailable, true);
  assert.equal(model.heatScope, "on-field");
  assert.equal(model.heatCells.length, 1);
  assert.equal(model.heatCells[0].weight, 110);
  assert.equal(model.heatCells[0].intensity, 1);
  assertOnCanvas(model.heatCells);
  fixture.route.heatmapAvailable = false;
  assert.equal(page.read(`createRouteModel(${JSON.stringify(fixture)}).heatAvailable`), false);
  fixture.route.heatmapAvailable = true;
  fixture.route.points = fixture.route.points.slice(0, 9);
  assert.equal(page.read(`createRouteModel(${JSON.stringify(fixture)}).heatAvailable`), false);
});

test("GPS coordinates without sample times remain visible without inventing heat duration", () => {
  const page = openPrototype();
  const fixture = { route: { heatmapAvailable: true, points: Array.from({ length: 12 }, (_, index) => ({ latitude: 40 + index * 0.00001, longitude: 116 })) } };
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.points.length, 12);
  assertOnCanvas(model.points);
  assert.equal(model.heatAvailable, false);
  assert.deepEqual(model.heatCells, []);
});

test("metric projection uses one scale and preserves north and east at nonzero latitude", () => {
  const page = openPrototype();
  const fixture = { route: { points: [
    { latitude: 60, longitude: 10, elapsedSecond: 0, horizontalAccuracy: 8 },
    { latitude: 60, longitude: 10.001, elapsedSecond: 10, horizontalAccuracy: 8 },
    { latitude: 60.0005, longitude: 10, elapsedSecond: 20, horizontalAccuracy: 8 }
  ] } };
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  const [origin, east, north] = model.points;
  assertOnCanvas(model.points);
  assert.ok(east.x > origin.x);
  assert.ok(north.y < origin.y);
  assert.ok(Math.abs(east.y - origin.y) < 0.01);
  assert.ok(Math.abs(north.x - origin.x) < 0.01);
  const ratio = (east.x - origin.x) / (origin.y - north.y);
  assert.ok(Math.abs(ratio - 1) < 0.01, `equal physical distances should use equal pixel distances; ratio=${ratio}`);
});

test("poor-accuracy outliers interrupt both polyline segments and heat intervals", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  Object.assign(fixture.route.points[5], { latitude: 40.01, horizontalAccuracy: 80 });
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.ok(Array.isArray(model.segments));
  const segments = model.segments.map(segmentPoints);
  assert.ok(segments.length >= 2);
  assert.equal(segments.flat().some(point => point.elapsedSecond === 50), false);
  for (const segment of segments) {
    assert.equal(segment.some(point => point.elapsedSecond === 40) && segment.some(point => point.elapsedSecond === 60), false);
  }
  assert.equal(totalHeatSeconds(model), 90);
});

test("an impossible speed jump breaks the track without enlarging its viewport", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  const baseline = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  fixture.route.points[5].latitude += 0.01;
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.points.some(point => point.elapsedSecond === 50), false);
  assert.ok(model.segments.length >= 2);
  for (const segment of model.segments.map(segmentPoints)) {
    assert.equal(segment.some(point => point.elapsedSecond === 40) && segment.some(point => point.elapsedSecond === 60), false);
  }
  assert.equal(totalHeatSeconds(model), 90);
  assert.ok(Math.abs(model.projection.metersPerPixel - baseline.projection.metersPerPixel) < 0.000001);
  assertOnCanvas(model.points);
});

test("an isolated first GPS drift cannot become the anchor that rejects the main track", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  fixture.route.points = fixture.route.points.map((point, index) => ({ ...point, latitude: 40 + index * 0.000005, longitude: 116 + index * 0.000005, horizontalAccuracy: 5 }));
  const baseline = { ...fixture, route: { ...fixture.route, points: fixture.route.points.slice(1) } };
  const expected = page.read(`createRouteModel(${JSON.stringify(baseline)})`);
  fixture.route.points[0].latitude += 0.009;
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.points.some(point => point.elapsedSecond === 0), false);
  assert.equal(model.points.length, 11);
  assert.ok(model.projection.metersPerPixel <= expected.projection.metersPerPixel * 1.1);
  assertOnCanvas(model.points);
});

test("unknown, negative or excessive GPS accuracy never generates reliable heat", () => {
  const page = openPrototype();
  for (const accuracy of [undefined, -1, 31]) {
    const fixture = makeHeatFixture();
    for (const point of fixture.route.points) {
      if (accuracy === undefined) delete point.horizontalAccuracy;
      else point.horizontalAccuracy = accuracy;
    }
    const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
    assert.equal(model.heatAvailable, false);
    assert.equal(totalHeatSeconds(model), 0);
    if (accuracy === undefined) {
      assert.equal(model.points.length, 12);
      assertOnCanvas(model.points);
      assert.equal(model.quality.unknownAccuracy, 12);
    }
  }
});

test("sampling gaps break tracks and contribute no heat unless allowed by the configured limit", () => {
  const page = openPrototype();
  const times = [...Array.from({ length: 10 }, (_, index) => index * 5), ...Array.from({ length: 10 }, (_, index) => 105 + index * 5)];
  const fixture = makeHeatFixture(times);
  fixture.route.maxGapSeconds = 40;
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.segments.length, 2);
  assert.equal(totalHeatSeconds(model), 90);
  for (const segment of model.segments.map(segmentPoints)) {
    for (let index = 1; index < segment.length; index += 1) {
      assert.ok(segment[index].elapsedSecond - segment[index - 1].elapsedSecond <= 40);
    }
  }
  fixture.route.maxGapSeconds = 60;
  const allowed = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(allowed.segments.length, 1);
  assert.equal(totalHeatSeconds(allowed), 150);
});

test("duplicate, reordered and negative timestamps cannot inflate heat duration", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture([0, 10, 20, 30, 40, 50, 60, 70, 80, 90]);
  fixture.route.points.push({ ...fixture.route.points[1] }, { ...fixture.route.points[0], elapsedSecond: -10 });
  fixture.route.points.reverse();
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(totalHeatSeconds(model), 90);
});

test("a sample without a timestamp cannot bridge the neighboring timed heat intervals", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  delete fixture.route.points[5].elapsedSecond;
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.points.length, 12);
  assert.equal(totalHeatSeconds(model), 90);
  assert.equal(model.heatAvailable, true);
});

test("replayed older samples cannot add duplicate heat when mixed with an untimed point", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  delete fixture.route.points[5].elapsedSecond;
  const baseline = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  const replayed = fixture.route.points.filter(point => point.elapsedSecond >= 20 && point.elapsedSecond <= 70).map(point => ({ ...point }));
  fixture.route.points.splice(8, 0, ...replayed);
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.ok(totalHeatSeconds(model) <= totalHeatSeconds(baseline), `old samples added duplicate heat: ${totalHeatSeconds(model)} > ${totalHeatSeconds(baseline)}`);
});

test("heat intersects actual field intervals and excludes wall-clock pause time", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  fixture.events = [
    { type: "enteredField", matchSecond: 10, elapsedSecond: 10 },
    { type: "leftField", matchSecond: 35, elapsedSecond: 35 },
    { type: "enteredField", matchSecond: 55, elapsedSecond: 55 },
    { type: "matchPaused", matchSecond: 70, elapsedSecond: 70 },
    { type: "matchResumed", matchSecond: 70, elapsedSecond: 80 },
    { type: "leftField", matchSecond: 90, elapsedSecond: 100 }
  ];
  const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(model.heatAvailable, true);
  assert.equal(model.heatScope, "on-field");
  assert.equal(totalHeatSeconds(model), 60);
});

test("missing field events or incomplete legacy pause times disable heat with an explanation", () => {
  const page = openPrototype();
  for (const events of [[], [
    { type: "enteredField", matchSecond: 0 },
    { type: "matchPaused", matchSecond: 30 },
    { type: "matchResumed", matchSecond: 30 },
    { type: "leftField", matchSecond: 100 }
  ]]) {
    const fixture = makeHeatFixture();
    fixture.events = events;
    const model = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
    assert.equal(model.heatAvailable, false);
    assert.equal(totalHeatSeconds(model), 0);
    assert.equal(typeof model.heatReason, "string");
    assert.ok(model.heatReason.trim().length > 0);
  }
});

test("a field event with no actual timestamp cannot imply zero, while explicit legacy zero stays valid", () => {
  const page = openPrototype();
  const fixture = makeHeatFixture();
  fixture.events = [{ type: "enteredField" }, { type: "leftField", matchSecond: 110 }];
  const unknown = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
  assert.equal(unknown.heatAvailable, false);
  assert.deepEqual(unknown.heatCells, []);
  assert.equal(typeof unknown.heatReason, "string");
  assert.ok(unknown.heatReason.trim().length > 0);
  for (const explicitZero of [{ matchSecond: 0 }, { minute: 0 }]) {
    fixture.events[0] = { type: "enteredField", ...explicitZero };
    const legacy = page.read(`createRouteModel(${JSON.stringify(fixture)})`);
    assert.equal(legacy.heatAvailable, true);
    assert.equal(totalHeatSeconds(legacy), 110);
  }
});

test("live events keep wall-clock elapsed time while match time freezes during a pause", () => {
  const page = openPrototype();
  page.click({ action: "new-match" });
  page.click({ action: "confirm-start" });
  assert.equal(page.read("state.liveMatch.events.every(event => event.elapsedSecond === 0)"), true);
  page.advance(10000);
  page.click({ action: "pause" });
  const paused = page.read('state.liveMatch.events.find(event => event.type === "matchPaused")');
  assert.equal(paused.elapsedSecond, 10);
  assert.equal(paused.matchSecond, 10);
  page.advance(20000);
  page.click({ action: "quick-score", quick: "mine" });
  const score = page.read('state.liveMatch.events.find(event => event.type === "scoreEvent")');
  assert.equal(score.elapsedSecond, 30);
  assert.equal(score.matchSecond, 10);
  page.click({ action: "resume" });
  const resumed = page.read('state.liveMatch.events.find(event => event.type === "matchResumed")');
  assert.equal(resumed.elapsedSecond, 30);
  assert.equal(resumed.matchSecond, 10);
  page.advance(5000);
  page.click({ action: "toggle-field" });
  const offField = page.read('state.liveMatch.events.find(event => event.type === "leftField")');
  assert.equal(offField.elapsedSecond, 35);
  assert.equal(offField.matchSecond, 15);
});

test("the seeded live match can still generate reliable heat after pause, resume and completion", () => {
  const page = openPrototype();
  assert.equal(page.read("createRouteModel(state.liveMatch).heatAvailable"), true);
  page.click({ action: "pause" });
  page.advance(20000);
  page.click({ action: "resume" });
  page.advance(10000);
  page.click({ action: "confirm-end" });
  assert.equal(page.read("state.liveMatch"), null);
  const model = page.read("createRouteModel(state.history[0])");
  assert.equal(model.heatAvailable, true, model.heatReason);
  assert.ok(totalHeatSeconds(model) > 0);
  assert.equal(page.read('state.history[0].events.filter(event => ["enteredField", "leftField", "matchPaused", "matchResumed", "matchEnded"].includes(event.type)).every(event => Number.isFinite(event.elapsedSecond))'), true);
});

test("calibration accepts ordered convex GPS corners and rejects invalid boundaries", () => {
  const page = openPrototype();
  assert.equal(page.read(`validateCalibrationCorners(${JSON.stringify(calibrationCorners)})`), true);
  const invalid = [
    [calibrationCorners[0], calibrationCorners[2], calibrationCorners[1], calibrationCorners[3]],
    [calibrationCorners[0], calibrationCorners[1], calibrationCorners[1], calibrationCorners[3]],
    calibrationCorners.slice(0, 3),
    [{ latitude: 91, longitude: 116 }, ...calibrationCorners.slice(1)],
    [0, 1, 2, 3].map(index => ({ latitude: 40, longitude: 116 + index * 0.001 }))
  ];
  for (const corners of invalid) {
    assert.equal(page.read(`validateCalibrationCorners(${JSON.stringify(corners)})`), false);
  }
});

test("saving and clearing a field calibration preserves original GPS coordinates", () => {
  const page = openPrototype();
  const fixture = { ...makeHeatFixture(), venue: "测试球场" };
  page.run(`var calibrationMatch = ${JSON.stringify(fixture)};`);
  const original = page.read("calibrationMatch.route.points");
  const saved = page.read(`storeVenueCalibration(calibrationMatch, ${JSON.stringify(calibrationCorners)})`);
  assert.equal(saved.ok, true);
  assert.equal(saved.persisted, true);
  const record = page.read("getVenueCalibration(calibrationMatch)");
  assert.equal(record.venue, fixture.venue);
  assert.deepEqual(record.corners, calibrationCorners);
  assert.ok(record.updatedAt);
  assert.ok(page.read("createRouteModel(calibrationMatch).calibration"));
  assert.deepEqual(page.read("calibrationMatch.route.points"), original);
  page.run("clearVenueCalibration(calibrationMatch)");
  assert.equal(page.read("getVenueCalibration(calibrationMatch)"), null);
  assert.equal(page.read("createRouteModel(calibrationMatch).calibration"), null);
  assert.deepEqual(page.read("calibrationMatch.route.points"), original);
});

test("persisted calibration is reusable nearby but not by a distant venue with the same name", () => {
  const storage = new Map();
  const first = openPrototype({ storage });
  const fixture = { ...makeHeatFixture(), venue: "测试球场" };
  assert.equal(first.read(`storeVenueCalibration(${JSON.stringify(fixture)}, ${JSON.stringify(calibrationCorners)}).persisted`), true);
  const next = openPrototype({ storage });
  const nearby = { ...fixture, id: "next-match", route: { ...fixture.route, points: fixture.route.points.map(point => ({ ...point, latitude: point.latitude + 0.0001, longitude: point.longitude + 0.0001 })) } };
  assert.deepEqual(next.read(`getVenueCalibration(${JSON.stringify(nearby)}).corners`), calibrationCorners);
  const distant = { ...fixture, route: { ...fixture.route, points: fixture.route.points.map(point => ({ ...point, latitude: 45, longitude: 120 })) } };
  assert.equal(next.read(`getVenueCalibration(${JSON.stringify(distant)})`), null);
  assert.equal(next.read(`getVenueCalibration(${JSON.stringify({ ...nearby, venue: "另一球场" })})`), null);
});

test("calibration reuse follows the reliable location majority instead of the first raw coordinate", () => {
  const page = openPrototype();
  const fixture = { ...makeHeatFixture(), venue: "测试球场" };
  assert.equal(page.read(`storeVenueCalibration(${JSON.stringify(fixture)}, ${JSON.stringify(calibrationCorners)}).ok`), true);
  const nearBody = { ...fixture, route: { ...fixture.route, points: [
    { latitude: 45, longitude: 120, elapsedSecond: 0, horizontalAccuracy: 80 },
    ...fixture.route.points.map(point => ({ ...point, elapsedSecond: point.elapsedSecond + 10 }))
  ] } };
  const nearbyCalibration = page.read(`getVenueCalibration(${JSON.stringify(nearBody)})`);
  assert.ok(nearbyCalibration, "a rejected distant first fix must not prevent nearby venue reuse");
  assert.deepEqual(nearbyCalibration.corners, calibrationCorners);
  const distantBody = { ...fixture, route: { ...fixture.route, points: [
    { latitude: 40, longitude: 116, elapsedSecond: 0, horizontalAccuracy: 5 },
    ...fixture.route.points.map(point => ({ ...point, latitude: 45, longitude: 120, elapsedSecond: point.elapsedSecond + 10 }))
  ] } };
  assert.equal(page.read(`getVenueCalibration(${JSON.stringify(distantBody)})`), null);
});

test("map tile errors show a fallback and successful loading hides the map status", () => {
  const page = openPrototype();
  const map = makeMapFrame();
  page.setQueryResults(".route-tile", map.tiles);
  page.run("monitorMapTiles()");
  map.fire(0, "error");
  assert.equal(map.status.hidden, false);
  assert.match(map.status.textContent, /底图未完整加载/);
  map.fire(1, "load");
  assert.equal(map.status.hidden, false);
  map.fire(0, "load");
  assert.equal(map.status.hidden, true);
});

test("pending map tiles show a timed fallback while retired and loaded maps stay unaffected", () => {
  const page = openPrototype();
  const retired = makeMapFrame(1);
  page.setQueryResults(".route-tile", retired.tiles);
  page.run("monitorMapTiles()");
  retired.tiles[0].isConnected = false;
  const pending = makeMapFrame(1);
  const loaded = makeMapFrame(1);
  page.setQueryResults(".route-tile", [...pending.tiles, ...loaded.tiles]);
  page.run("monitorMapTiles()");
  loaded.fire(0, "load");
  assert.equal(loaded.status.hidden, true);
  page.advance(9999);
  page.flushTimers();
  assert.equal(pending.status.textContent, "地图加载中…");
  page.advance(1);
  page.flushTimers();
  assert.equal(pending.status.hidden, false);
  assert.match(pending.status.textContent, /底图暂不可用/);
  assert.equal(retired.status.textContent, "地图加载中…");
  assert.equal(loaded.status.hidden, true);
});

test("seeded histories cover route with heat, route without heat and unavailable route", () => {
  const page = openPrototype();
  const models = page.read("state.history.map(createRouteModel)");
  assert.ok(models[0].points.length >= 10);
  assert.equal(models[0].heatAvailable, true);
  assert.ok(models[0].heatCells.length > 0);
  for (const cell of models[0].heatCells) {
    assert.equal(Number.isFinite(cell.weight), true);
    assert.ok(cell.weight >= 0);
    assert.equal(Number.isFinite(cell.intensity), true);
    assert.ok(cell.intensity >= 0 && cell.intensity <= 1);
  }
  assert.ok(models[1].points.length > 0);
  assert.equal(models[1].heatAvailable, false);
  assert.deepEqual(models[2].points, []);
  assert.equal(models[2].heatAvailable, false);
});

test("route gallery opens for selected history and returns to the same match detail", () => {
  const page = openPrototype();
  page.click({ historyId: "m-0912" });
  page.click({ action: "open-routes" });
  assert.equal(page.read("state.routeOpen === true"), true);
  assert.equal(page.read("state.detailMatchId"), "m-0912");
  page.run('var originalGallery = renderRouteGallery; renderRouteGallery = () => "__ROUTE_GALLERY__";');
  assert.match(page.read("renderPhone()"), /__ROUTE_GALLERY__/);
  page.run("renderRouteGallery = originalGallery;");
  page.click({ action: "back-detail" });
  assert.equal(page.read("state.routeOpen === false"), true);
  assert.equal(page.read("state.detailMatchId"), "m-0912");
});

test("history navigation, tabs, author contact and match restart clear the route view", () => {
  const transitions = [
    page => page.click({ action: "back-history" }),
    page => page.click({ tab: "settings" }),
    page => page.run('window.__setTab("history")'),
    page => page.click({ action: "contact-author" }),
    page => page.click({ historyId: "m-0905" }),
    page => { page.click({ action: "new-match" }); page.click({ action: "confirm-start" }); }
  ];
  for (const transition of transitions) {
    const page = openPrototype();
    page.click({ historyId: "m-0912" });
    page.click({ action: "open-routes" });
    assert.equal(page.read("state.routeOpen === true"), true);
    transition(page);
    assert.equal(page.read("state.routeOpen === false"), true);
    page.run('var originalGallery = renderRouteGallery; renderRouteGallery = () => "__STALE_ROUTE_GALLERY__";');
    assert.doesNotMatch(page.read("renderPhone()"), /__STALE_ROUTE_GALLERY__/);
  }
});
