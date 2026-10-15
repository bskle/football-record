const seed = () => {
  const startedAtMs = Date.now() - 52 * 60 * 1000;
  return {
    activeTab: "match",
    detailMatchId: null,
    contactOpen: false,
    routeOpen: false,
    modal: null,
    quickRecord: null,
    lastQuickScoreAtMs: -Infinity,
    settings: { haptics: true, health: true, analytics: false },
    liveMatch: {
      id: "live-01",
      status: "running",
      title: "周三夜场",
      date: "2026-09-20",
      venue: "北京理工大学足球场",
      home: "蓝队",
      away: "橙队",
      startedAt: "19:30",
      startedAtMs,
      pausedAtMs: null,
      pausedTotalMs: 0,
      finalMatchSeconds: null,
      route: createDemoRoute(2, 52),
      events: [
        { id: "e1", type: "matchStarted", time: "19:30", minute: 0, matchSecond: 0, elapsedSecond: 0, label: "比赛开始", detail: "首发" },
        { id: "e2", type: "enteredField", time: "19:30", minute: 0, matchSecond: 0, elapsedSecond: 0, label: "上场", detail: "首发" },
        { id: "e3", type: "scoreEvent", impact: "for", kind: "normal", scorer: null, assister: "self", time: "19:44", minute: 14, matchSecond: 14 * 60, label: "蓝队进球", detail: "我助攻 · 7号" },
        { id: "e4", type: "leftField", time: "19:58", minute: 28, matchSecond: 28 * 60, elapsedSecond: 28 * 60, label: "下场", detail: "休息" },
        { id: "e5", type: "enteredField", time: "20:07", minute: 37, matchSecond: 37 * 60, elapsedSecond: 37 * 60, label: "上场", detail: "替补" },
        { id: "e6", type: "scoreEvent", impact: "against", kind: "normal", time: "20:13", minute: 43, matchSecond: 43 * 60, label: "橙队进球", detail: "对方 9号" },
        { id: "e7", type: "scoreEvent", impact: "for", kind: "normal", scorer: "self", assister: null, time: "20:19", minute: 49, matchSecond: 49 * 60, label: "蓝队进球", detail: "我进球" }
      ]
    },
    history: [
      {
        id: "m-0912", status: "completed", title: "周六联赛 · 第 4 轮", date: "2026-09-12", venue: "北京理工大学足球场", home: "白队", away: "黑队", scoreBaseline: { for: 2, against: 2 }, final: "3 - 2", result: "win", appearance: "68 分钟", distance: "6.8 km", route: createDemoRoute(0, 85), events: [
          { id: "h1", type: "matchStarted", time: "15:02", minute: 0, label: "比赛开始", detail: "首发" },
          { id: "h2", type: "enteredField", time: "15:02", minute: 0, label: "上场", detail: "首发" },
          { id: "h3", type: "scoreEvent", impact: "for", kind: "normal", scorer: "self", assister: null, time: "15:31", minute: 29, label: "白队进球", detail: "我进球 · 10号" },
          { id: "h4", type: "leftField", time: "16:10", minute: 68, label: "下场", detail: "" },
          { id: "h5", type: "matchEnded", time: "16:27", minute: 85, label: "比赛结束", detail: "" }
        ]
      },
      { id: "m-0905", status: "completed", title: "周五约球", date: "2026-09-05", venue: "北京理工大学足球场", home: "红队", away: "蓝队", scoreBaseline: { for: 1, against: 1 }, final: "1 - 1", result: "draw", appearance: "54 分钟", distance: "5.2 km", route: createDemoRoute(1, 72, false), events: [] },
      { id: "m-0830", status: "completed", title: "周日训练赛", date: "2026-08-30", venue: "将府公园", home: "黄队", away: "绿队", scoreBaseline: { for: 0, against: 2 }, final: "0 - 2", result: "loss", appearance: "31 分钟", distance: "3.4 km", events: [] }
    ]
  };
};

let state = seed();
const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
const health = { heartRate: "142 bpm", distance: "4.6 km", speed: "8.7 km/h", gps: "良好" };
const authorContact = { email: "japdie19450815@qq.com", groupQrSrc: "assets/feedback-group-qr.png" };
// The historical mocks have partial timelines; preserve goals without event details.
const scoreOf = (match) => (match?.events || []).filter((event) => event.type === "scoreEvent").reduce((score, event) => { score[event.impact === "for" ? "for" : "against"] += 1; return score; }, { for: match?.scoreBaseline?.for || 0, against: match?.scoreBaseline?.against || 0 });
const personalStatsOf = (match) => (match?.events || []).filter((event) => event.type === "scoreEvent" && event.impact === "for" && event.kind !== "ownGoal").reduce((stats, event) => {
  if (event.scorer === "self") stats.goals += 1;
  if (event.assister === "self") stats.assists += 1;
  return stats;
}, { goals: 0, assists: 0 });
const eventSecond = (event) => Number.isFinite(event.matchSecond) ? event.matchSecond : (Number(event.minute) || 0) * 60;
const sortedFieldEvents = (match) => (match?.events || []).filter((event) => ["enteredField", "leftField"].includes(event.type)).sort((a, b) => eventSecond(a) - eventSecond(b));
const currentOnField = (match) => { let on = false; sortedFieldEvents(match).forEach((event) => { on = event.type === "enteredField"; }); return on; };
const matchSeconds = (match, at = Date.now()) => {
  if (!match) return 0;
  if (Number.isFinite(match.finalMatchSeconds)) return Math.max(0, match.finalMatchSeconds);
  if (!Number.isFinite(match.startedAtMs)) return (Number(match.minute) || 0) * 60;
  const end = match.status === "paused" ? (match.pausedAtMs || at) : at;
  return Math.max(0, (end - match.startedAtMs - (match.pausedTotalMs || 0)) / 1000);
};
const appearanceSeconds = (match, at = Date.now()) => {
  if (!match) return 0;
  const end = matchSeconds(match, at);
  let total = 0;
  let start = null;
  sortedFieldEvents(match).forEach((event) => {
    const second = Math.min(end, eventSecond(event));
    if (event.type === "enteredField" && start === null) start = second;
    if (event.type === "leftField" && start !== null) { total += Math.max(0, second - start); start = null; }
  });
  if (start !== null) total += Math.max(0, end - start);
  if (!Number.isFinite(match.startedAtMs) && total === 0) return parseInt(match.appearance, 10) * 60 || 0;
  return total;
};
const appearanceMinutes = (match) => Math.floor(appearanceSeconds(match) / 60) || parseInt(match?.appearance, 10) || 0;
const matchLabel = (match) => match.status === "paused" ? "已暂停" : match.status === "running" ? "进行中" : "已完成";
const iconFor = (event) => event.type === "scoreEvent" ? "goal" : ["enteredField", "leftField"].includes(event.type) ? "field" : "";
const pad = (number) => String(Math.max(0, Math.floor(number))).padStart(2, "0");
const formatClock = (seconds) => `${pad(seconds / 60)}:${pad(seconds % 60)}`;
const formatShortDate = () => new Date().toISOString().slice(0, 10);

function formatAppearanceDuration(match) {
  if (!match) return "未记录";
  let seconds;
  if (Number.isFinite(match.startedAtMs) || Number.isFinite(match.finalMatchSeconds)) {
    seconds = appearanceSeconds(match);
  } else {
    const minutes = String(match.appearance ?? "").trim().match(/^(\d+(?:\.\d+)?)\s*(?:分钟|分)?$/);
    if (!minutes) return "未记录";
    seconds = Number(minutes[1]) * 60;
  }
  if (!Number.isFinite(seconds) || seconds < 0) return "未记录";
  const minutes = Math.floor(seconds / 60);
  return `${pad(minutes / 60)}:${pad(minutes % 60)}`;
}

function formatDistanceKm(value) {
  const numeric = String(value ?? "").trim().match(/^(\d+(?:\.\d+)?)\s*(?:km)?$/i);
  if (!numeric || !Number.isFinite(Number(numeric[1]))) return "未记录";
  return String(Number(numeric[1]));
}

// Fictional samples include a rotated playing area, bench time and missing fixes.
function createDemoRoute(variant, durationMinutes, heatmapAvailable = true) {
  // Public OSM pitch way 352009346; this is a synthetic run, not a recorded visit.
  const centerLatitude = 39.95797595;
  const centerLongitude = 116.30951875;
  const anchors = [[.48, .52], [.48, .52], [.55, .41], [.72, .26], [.83, .31], [.69, .47], [.52, .51], [.65, .69], [.85, .67], [.88, .46], [.67, .32], [.52, .51], [.52, .51], [.35, .47], [.31, .28], [.47, .31], [.55, .5]];
  const duration = Math.max(0, Math.floor(durationMinutes * 60));
  const points = [];
  for (let second = 0; second <= duration; second += 10) {
    if (second >= 1800 && second <= 1850) continue;
    const phase = second / 22;
    const anchor = Math.floor(phase) % anchors.length;
    const a = anchors[anchor];
    const b = anchors[(anchor + 1) % anchors.length];
    const part = phase % 1;
    let x = a[0] + (b[0] - a[0]) * part + Math.sin(second / 53 + variant) * .025;
    let y = a[1] + (b[1] - a[1]) * part + Math.cos(second / 43 + variant) * .025;
    if (variant === 1) x = 1 - x;
    if ((variant === 0 && second > 68 * 60) || (variant === 2 && second > 28 * 60 && second < 37 * 60)) { x = .12; y = 1.12; }
    const angle = 88 * Math.PI / 180;
    const east = (x - .5) * 105 * Math.cos(angle) - (y - .5) * 68 * Math.sin(angle);
    const north = (x - .5) * 105 * Math.sin(angle) + (y - .5) * 68 * Math.cos(angle);
    points.push({ latitude: centerLatitude + north / 111320, longitude: centerLongitude + east / (111320 * Math.cos(centerLatitude * Math.PI / 180)), elapsedSecond: second, horizontalAccuracy: second === 1200 ? 80 : 5 + (second / 10 % 3) });
  }
  return { source: "mock", heatmapAvailable, points };
}

const MAP_RADIUS = 6378137;
const calibrationMemory = new Map();
function validCoordinate(point) { return point && Number.isFinite(point.latitude) && Math.abs(point.latitude) <= 85.05112878 && Number.isFinite(point.longitude) && Math.abs(point.longitude) <= 180; }
function mercator(point) { return { mx: MAP_RADIUS * point.longitude * Math.PI / 180, my: MAP_RADIUS * Math.log(Math.tan(Math.PI / 4 + point.latitude * Math.PI / 360)) }; }
function inverseMercator(mx, my) { return { latitude: (2 * Math.atan(Math.exp(my / MAP_RADIUS)) - Math.PI / 2) * 180 / Math.PI, longitude: mx / MAP_RADIUS * 180 / Math.PI }; }
function projectPoint(point, projection) { const p = mercator(point); return { ...point, ...p, x: 160 + (p.mx - projection.cx) * projection.scale, y: 108 - (p.my - projection.cy) * projection.scale }; }
function unprojectPoint(x, y, projection) { return inverseMercator(projection.cx + (x - 160) / projection.scale, projection.cy - (y - 108) / projection.scale); }
function groundDistance(a, b) { const p = mercator(a), q = mercator(b); return Math.hypot(p.mx - q.mx, p.my - q.my) * Math.cos((a.latitude + b.latitude) * Math.PI / 360); }

function validateCalibrationCorners(corners) {
  if (!Array.isArray(corners) || corners.length !== 4 || !corners.every(validCoordinate)) return false;
  const points = corners.map(mercator);
  const turns = points.map((a, i) => { const b = points[(i + 1) % 4], c = points[(i + 2) % 4]; return (b.mx - a.mx) * (c.my - b.my) - (b.my - a.my) * (c.mx - b.mx); });
  return turns.every(t => t > 1) || turns.every(t => t < -1);
}
function calibrationKey(match) { return `football-venue-v1:${String(match?.venue || "").trim()}`; }
function getVenueCalibration(match) {
  if (!String(match?.venue || "").trim()) return null;
  const key = calibrationKey(match);
  let record = calibrationMemory.get(key);
  if (!record) { try { record = JSON.parse(localStorage.getItem(key)); } catch {} }
  if (!record || !validateCalibrationCorners(record.corners)) return null;
  const samples = filterRouteSamples(match?.route || {}).accepted;
  const median = values => { const sorted = [...values].sort((a, b) => a - b); return sorted[Math.floor(sorted.length / 2)]; };
  const sample = samples.length ? { latitude: median(samples.map(p => p.latitude)), longitude: median(samples.map(p => p.longitude)) } : null;
  const center = { latitude: record.corners.reduce((s, p) => s + p.latitude, 0) / 4, longitude: record.corners.reduce((s, p) => s + p.longitude, 0) / 4 };
  return sample && groundDistance(sample, center) <= 500 ? record : null;
}
function storeVenueCalibration(match, corners) {
  if (!String(match?.venue || "").trim() || !validateCalibrationCorners(corners)) return { ok: false, persisted: false };
  const record = { venue: match.venue, corners: corners.map(({ latitude, longitude }) => ({ latitude, longitude })), updatedAt: new Date().toISOString() };
  calibrationMemory.set(calibrationKey(match), record);
  let persisted = false;
  try { localStorage.setItem(calibrationKey(match), JSON.stringify(record)); persisted = true; } catch {}
  return { ok: true, persisted };
}
function clearVenueCalibration(match) { calibrationMemory.delete(calibrationKey(match)); try { localStorage.removeItem(calibrationKey(match)); } catch {} }

// GPS elapsedSecond is wall time. matchSecond freezes during match pauses.
function heatIntervals(match, end) {
  const relevant = (match?.events || []).filter(e => ["enteredField", "leftField", "matchPaused", "matchResumed", "matchEnded"].includes(e.type));
  const hasPause = relevant.some(e => ["matchPaused", "matchResumed"].includes(e.type));
  if (hasPause && relevant.some(e => !Number.isFinite(e.elapsedSecond))) return { intervals: [], reason: "暂停或上下场的实际时间不完整，暂不生成热力图。" };
  if (!relevant.some(e => e.type === "enteredField")) return { intervals: [], reason: "缺少上场记录，暂不生成上场热力图。" };
  if (relevant.some(e => !Number.isFinite(e.elapsedSecond) && !Number.isFinite(e.matchSecond) && !(e.minute !== undefined && e.minute !== null && String(e.minute).trim() !== "" && Number.isFinite(Number(e.minute))))) return { intervals: [], reason: "上下场记录缺少时间，暂不生成上场热力图。" };
  const events = relevant.map(e => ({ ...e, elapsed: Number.isFinite(e.elapsedSecond) ? e.elapsedSecond : eventSecond(e) })).filter(e => e.elapsed >= 0).sort((a, b) => a.elapsed - b.elapsed);
  let on = false, running = true, previous = 0;
  const intervals = [];
  for (const e of events) {
    const at = Math.min(end, e.elapsed);
    if (on && running && at > previous) intervals.push([previous, at]);
    if (e.type === "enteredField") on = true;
    if (e.type === "leftField") on = false;
    if (e.type === "matchPaused" || e.type === "matchEnded") running = false;
    if (e.type === "matchResumed") running = true;
    previous = at;
    if (e.elapsed > end) break;
  }
  if (on && running && end > previous) intervals.push([previous, end]);
  return { intervals, reason: "" };
}

function filterRouteSamples(route) {
  const quality = { rejected: 0, unknownAccuracy: 0, gaps: 0 };
  const raw = (Array.isArray(route.points) ? route.points : []).map(p => ({ ...p }));
  if (raw.every(p => Number.isFinite(p.elapsedSecond))) raw.sort((a, b) => a.elapsedSecond - b.elapsedSecond);
  const maxGap = Number.isFinite(route.maxGapSeconds) && route.maxGapSeconds > 0 ? route.maxGapSeconds : 30;
  const maxSpeed = Number.isFinite(route.maxSpeedMetersPerSecond) && route.maxSpeedMetersPerSecond > 0 ? route.maxSpeedMetersPerSecond : 12;
  const usable = raw.filter(p => validCoordinate(p) && (!Number.isFinite(p.horizontalAccuracy) || (p.horizontalAccuracy >= 0 && p.horizontalAccuracy <= 30)) && Number.isFinite(p.elapsedSecond) && p.elapsedSecond >= 0);
  const plausible = (a, b) => b.elapsedSecond > a.elapsedSecond && b.elapsedSecond - a.elapsedSecond <= maxGap && groundDistance(a, b) <= maxSpeed * (b.elapsedSecond - a.elapsedSecond) + Math.max(a.horizontalAccuracy || 0, b.horizontalAccuracy || 0);
  const startupRejects = new Set();
  // Confirm a stable startup cluster before allowing an isolated fix to anchor the map.
  for (let i = 0; i + 2 < usable.length; i++) {
    if (!plausible(usable[i], usable[i + 1]) || !plausible(usable[i + 1], usable[i + 2])) continue;
    for (const p of usable.slice(0, i)) {
      const dt = usable[i].elapsedSecond - p.elapsedSecond;
      if (dt > 0 && dt <= maxGap && !plausible(p, usable[i])) startupRejects.add(p);
    }
    break;
  }
  const accepted = [], groups = [];
  let segment = null, previous = null, broken = true, lastKnownElapsed = -Infinity;
  for (const p of raw) {
    const known = Number.isFinite(p.horizontalAccuracy);
    if (startupRejects.has(p) || !validCoordinate(p) || (Number.isFinite(p.elapsedSecond) && p.elapsedSecond < 0) || (known && (p.horizontalAccuracy < 0 || p.horizontalAccuracy > 30))) { quality.rejected++; broken = true; continue; }
    if (Number.isFinite(p.elapsedSecond) && p.elapsedSecond <= lastKnownElapsed) { if (p.elapsedSecond < lastKnownElapsed) broken = true; continue; }
    const timed = previous && Number.isFinite(previous.elapsedSecond) && Number.isFinite(p.elapsedSecond);
    const dt = timed ? p.elapsedSecond - previous.elapsedSecond : null;
    if (dt === 0) continue;
    if (dt > 0 && dt <= maxGap && groundDistance(previous, p) > maxSpeed * dt + Math.max(previous.horizontalAccuracy || 0, p.horizontalAccuracy || 0)) { quality.rejected++; broken = true; continue; }
    if (dt !== null && dt > maxGap) { quality.gaps++; broken = true; }
    if (!known) quality.unknownAccuracy++;
    if (broken || !segment) { segment = []; groups.push(segment); }
    segment.push(p); accepted.push(p); previous = p; broken = false;
    if (Number.isFinite(p.elapsedSecond)) lastKnownElapsed = p.elapsedSecond;
  }
  return { accepted, groups, quality, maxGap };
}

function createRouteModel(match) {
  const route = match?.route || {};
  const { accepted, groups, quality, maxGap } = filterRouteSamples(route);
  const model = { points: [], segments: [], heatCells: [], heatAvailable: false, heatScope: "on-field", heatReason: "没有可用于生成热力图的 GPS 轨迹。", quality, calibration: getVenueCalibration(match), source: route.source };
  if (!accepted.length) return model;
  const extent = accepted.concat(model.calibration?.corners || []).map(mercator);
  const minX = Math.min(...extent.map(p => p.mx)), maxX = Math.max(...extent.map(p => p.mx));
  const minY = Math.min(...extent.map(p => p.my)), maxY = Math.max(...extent.map(p => p.my));
  const factor = Math.cos(accepted.reduce((s, p) => s + p.latitude, 0) / accepted.length * Math.PI / 180);
  const scale = Math.min(288 / Math.max(maxX - minX + 20 / factor, 40 / factor), 184 / Math.max(maxY - minY + 20 / factor, 40 / factor));
  model.projection = { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, scale, factor, metersPerPixel: factor / scale };
  model.points = accepted.map(p => projectPoint(p, model.projection));
  model.segments = groups.map(group => group.map(p => projectPoint(p, model.projection)));
  const end = Math.max(0, ...accepted.map(p => Number.isFinite(p.elapsedSecond) ? p.elapsedSecond : 0));
  const scope = heatIntervals(match, end);
  const accuracies = accepted.filter(p => Number.isFinite(p.horizontalAccuracy)).map(p => p.horizontalAccuracy).sort((a, b) => a - b);
  const cellMeters = Math.max(5, Math.ceil((accuracies[Math.floor(accuracies.length / 2)] || 5) / 5) * 5);
  const cellSize = cellMeters / factor;
  const heatOriginX = Math.floor(Math.min(...model.points.map(p => p.mx)) / cellSize) * cellSize;
  const heatOriginY = Math.floor(Math.min(...model.points.map(p => p.my)) / cellSize) * cellSize;
  const regions = new Map();
  for (const group of model.segments) for (let i = 1; i < group.length; i++) {
    const a = group[i - 1], b = group[i];
    if (![a.elapsedSecond, b.elapsedSecond, a.horizontalAccuracy, b.horizontalAccuracy].every(Number.isFinite)) continue;
    const dt = b.elapsedSecond - a.elapsedSecond;
    if (dt <= 0 || dt > maxGap) continue;
    for (const [from, to] of scope.intervals) {
      const finish = Math.min(to, b.elapsedSecond);
      for (let second = Math.max(from, a.elapsedSecond); second < finish; second += 1) {
        const weight = Math.min(1, finish - second);
        const fraction = (second + weight / 2 - a.elapsedSecond) / dt;
        const mx = a.mx + (b.mx - a.mx) * fraction, my = a.my + (b.my - a.my) * fraction;
        const col = Math.floor((mx - heatOriginX) / cellSize), row = Math.floor((my - heatOriginY) / cellSize), key = `${col}:${row}`;
        const cell = regions.get(key) || { x: 160 + (heatOriginX + (col + .5) * cellSize - model.projection.cx) * scale, y: 108 - (heatOriginY + (row + .5) * cellSize - model.projection.cy) * scale, weight: 0 };
        cell.weight += weight; regions.set(key, cell);
      }
    }
  }
  const maximum = Math.max(1, ...Array.from(regions.values(), c => c.weight));
  model.heatCells = Array.from(regions.values(), c => ({ ...c, intensity: c.weight / maximum }));
  model.cellPixels = cellSize * scale;
  model.heatAvailable = route.heatmapAvailable !== false && accepted.length >= 10 && model.heatCells.length > 0;
  model.heatReason = model.heatAvailable ? "" : route.heatmapAvailable === false ? "本场尚未生成热力图，GPS 轨迹仍可查看。" : scope.reason || (quality.unknownAccuracy ? "定位精度未知，保留轨迹但不估算停留时长。" : "有效采样不足，或上场区间没有连续且可靠的定位。" );
  return model;
}

function render() {
  const routeScroll = state.routeOpen && $(".route-gallery")?.dataset?.routeMatch === state.detailMatchId ? $(".phone-main")?.scrollTop : null;
  const calibrationScroll = state.modal?.type === "calibration" ? $(".calibration-modal")?.scrollTop : null;
  $("#app").innerHTML = `<div class="app-shell">
    <header class="topbar"><h1 class="brand">踢球履历</h1><p class="topbar-note">iPhone 与 Apple Watch · 交互预览</p></header>
    <div class="device-grid">
      <div class="phone-preview"><div class="device-label">iPhone <span>基准 390 × 844 pt</span></div>
        <section class="phone"><div class="phone-screen"><div class="phone-status"><span>9:41</span><span aria-hidden="true">● ● ▮</span></div><main class="phone-main">${renderPhone()}</main></div></section>
      </div>
      <aside class="watch-wrap">${renderWatch()}</aside>
    </div>
  </div>${state.modal ? renderModal() : ""}`;
  refreshLiveClocks();
  monitorMapTiles();
  if (Number.isFinite(routeScroll)) $(".phone-main").scrollTop = routeScroll;
  if (Number.isFinite(calibrationScroll)) $(".calibration-modal").scrollTop = calibrationScroll;
}

function renderPhone() {
  if (state.contactOpen) return renderAuthorContact();
  if (state.routeOpen && state.detailMatchId) return renderRouteGallery();
  if (state.detailMatchId) return renderDetail();
  const labels = { match: "比赛", history: "历史", career: "生涯", settings: "设置" };
  const nav = Object.keys(labels).map((tab) => `<button class="tab ${state.activeTab === tab ? "active" : ""}" data-tab="${tab}" aria-current="${state.activeTab === tab ? "page" : "false"}">${labels[tab]}</button>`).join("");
  const content = state.activeTab === "match" ? renderMatch() : state.activeTab === "history" ? renderHistory() : state.activeTab === "career" ? renderCareer() : renderSettings();
  return `<nav class="phone-nav" aria-label="主导航">${nav}</nav>${content}`;
}

function renderStartScreen(surface = "phone") {
  const last = state.history[0];
  if (surface === "watch") return `<div class="watch-label">Apple Watch · 45mm <span>198 × 242 pt</span></div>
    <div class="watch-multi watch-start-layout"><div class="watch-preview-page"><div class="watch-page-caption">开始比赛</div>
      <section class="watch-card"><div class="watch-screen">
        <div class="watch-top"><span>9:41</span><span class="watch-state">准备记录</span></div>
        <div class="watch-start-copy"><strong>下一场，上场吧</strong><span>记录比赛时间、<br>上场时间与健康数据</span></div>
        <button class="watch-primary-action" data-action="new-match">开始比赛</button>
        <div class="watch-last-match">上一场 ${esc(last?.final || "暂无记录")}</div>
      </div></section>
    </div></div><p class="watch-hint">结束后可继续开始下一场。</p>`;
  return `<div class="section-head"><div><h2>比赛</h2><p>准备好，再开始下一场。</p></div></div><section class="match-start-screen"><span class="start-kicker">下一场比赛</span><h3>上场，留下记录</h3><p>选择首发或替补，记录比分、上场时间与运动数据。</p><button class="primary-button start-button" data-action="new-match">开始一场比赛</button>${last ? `<div class="last-match-note">上一场：${esc(last.title)} · ${esc(last.final)}</div>` : ""}</section>`;
}

function renderMatch() {
  if (!state.liveMatch) return renderStartScreen("phone");
  const match = state.liveMatch;
  const score = scoreOf(match);
  const on = currentOnField(match);
  const recent = [...match.events].sort((a, b) => eventSecond(b) - eventSecond(a)).slice(0, 4);
  return `<div class="section-head"><div><h2>比赛</h2><p>${esc(match.venue)} · ${esc(match.startedAt)} 开始</p></div><span class="live-dot">● ${matchLabel(match)}</span></div>
    <section class="hero-match"><div class="match-kicker"><span>${esc(match.title)}</span><span>本场比分</span></div>
      <div class="scoreline"><div class="team-name">${esc(match.home)}<small>我方</small></div><div class="big-score">${score.for}<span class="score-divider">:</span>${score.against}</div><div class="team-name team-away">${esc(match.away)}<small>对方</small></div></div>
    </section>
    <section class="time-panel"><div class="time-grid"><div><small>比赛时间</small><b data-live-match-clock>${formatClock(matchSeconds(match))}</b></div><div><small>上场时间</small><b data-live-appearance-clock>${formatClock(appearanceSeconds(match))}</b></div></div></section>
    <section class="health-panel"><div class="panel-head"><h3>实时数据</h3><span>持续采集</span></div>
      <div class="health-grid"><div><small>心率</small><b>${health.heartRate}</b></div><div><small>距离</small><b>${health.distance}</b></div><div><small>速度</small><b>${health.speed}</b></div><div><small>GPS 状态</small><b class="good">${health.gps}</b></div></div>
    </section>
    <div class="control-pair"><button class="primary-button control-field" data-action="toggle-field">${on ? "下场" : "上场"}</button><button class="secondary-button control-menu" data-action="open-controls">比赛控制<small>${match.status === "paused" ? "继续" : "暂停"} / 结束</small></button></div>
    <section class="panel timeline-panel"><div class="panel-head"><h3>最近操作</h3><span>与手表同步</span></div><div class="timeline">${recent.map(renderTimelineRow).join("")}</div></section>`;
}

function renderTimelineRow(event) { return `<div class="timeline-row"><span class="timeline-time">${esc(event.time)}</span><span class="timeline-node ${iconFor(event)}"></span><div><div class="timeline-title">${esc(event.label)}</div><div class="timeline-detail">${esc(event.detail || "操作记录")}</div></div><button class="event-action" data-event-id="${esc(event.id)}" title="编辑事件">编辑</button></div>`; }

function renderHistory() { return `<div class="section-head"><div><h2>历史</h2><p>每一场都保留，随时可以回看。</p></div><button class="ghost-button" data-action="new-match">＋ 新比赛</button></div><div class="history-list">${state.history.map((match) => `<button class="history-card" data-history-id="${match.id}"><div><div class="history-date">${match.date} · ${match.venue}</div><div class="history-title">${match.title}</div><div class="history-sub">${match.appearance} 出场 · ${match.distance} · ${match.result === "win" ? "胜" : match.result === "loss" ? "负" : "平"}</div></div><div class="history-score ${match.result}">${match.final}</div></button>`).join("")}</div>`; }

function renderCareer() {
  const completed = state.history.length;
  const wins = state.history.filter((m) => m.result === "win").length;
  const goals = state.history.reduce((total, match) => total + personalStatsOf(match).goals, 0);
  return `<div class="section-head"><div><h2>生涯</h2><p>从下一场开始，数据会一直累积。</p></div><span class="updated-note">更新于刚刚</span></div>
    <section class="career-hero"><span class="metric-label">已记录比赛</span><div class="career-total">${completed + (state.liveMatch ? 1 : 0)}</div><div class="career-caption">场比赛 · ${wins} 胜 · ${state.history.filter((m) => m.result === "draw").length} 平 · ${state.history.filter((m) => m.result === "loss").length} 负</div></section>
    <section class="panel"><div class="panel-head"><h3>我的关键数字</h3><span>只统计已完成比赛</span></div><div class="stat-table"><div class="stat-cell"><b>${state.history.reduce((sum, m) => sum + parseInt(m.appearance, 10), 0)}</b><span>总出场分钟</span></div><div class="stat-cell"><b>${goals}</b><span>我的进球</span></div><div class="stat-cell"><b>${wins / Math.max(1, completed) * 100 | 0}%</b><span>胜率</span></div><div class="stat-cell"><b>15.4 km</b><span>累计距离</span></div></div></section>
    <section class="panel"><div class="panel-head"><h3>统计口径</h3><span>透明可修正</span></div><p class="data-explanation">只把已完成且实际出场的比赛计入胜率和体能。缺失的 HealthKit 数据显示为未记录，不会填成 0。</p></section>`;
}

function renderSettings() {
  const rows = [["haptics", "触觉反馈", "记录成功时轻触提醒"], ["health", "HealthKit 数据", "心率、距离和路线"], ["analytics", "匿名产品分析", "帮助改进记录流程"]];
  return `<div class="section-head"><div><h2>设置</h2><p>设备、数据和隐私都由你掌控。</p></div></div>
  <section class="panel"><div class="panel-head"><h3>记录设备</h3><span class="live-dot">已连接</span></div><div class="setting-row"><div><strong>Apple Watch Series 9 · 45mm</strong><span>本场唯一记录设备</span></div><span class="status-good">正常</span></div><div class="setting-row"><div><strong>iCloud 私有空间</strong><span>上次同步：刚刚 · 待同步 0 场</span></div><span class="status-good">正常</span></div></section>
  <section class="panel"><div class="panel-head"><h3>偏好</h3></div>${rows.map(([key, title, description]) => `<div class="setting-row"><div><strong>${title}</strong><span>${description}</span></div><button class="switch ${state.settings[key] ? "on" : ""}" data-setting="${key}" role="switch" aria-checked="${state.settings[key]}" aria-label="${title}"><i></i></button></div>`).join("")}</section>
  <section class="panel author-entry-panel"><button class="author-contact-entry" data-action="contact-author"><span><strong>联系作者</strong><small>扫码进群交流，或通过邮件反馈</small></span><span class="entry-chevron" aria-hidden="true">›</span></button></section>
  <section class="panel"><div class="panel-head"><h3>账号与数据</h3></div><button class="text-button" style="display:block;width:100%;text-align:left" data-action="toast" data-message="Apple 登录在原生版本接入">通过 Apple 登录 <span style="float:right">›</span></button><button class="text-button" style="display:block;width:100%;text-align:left" data-action="toast" data-message="删除入口已预留">删除账号与数据 <span style="float:right">›</span></button></section>`;
}

function renderAuthorContact() {
  const qr = authorContact.groupQrSrc;
  return `<button class="back-link contact-back" data-action="back-settings">‹ 返回设置</button>
  <div class="section-head contact-heading"><div><h2>联系作者</h2><p>聊聊使用体验，一起把踢球记录做好。</p></div></div>
  <section class="panel contact-group-panel"><div class="panel-head"><h3>加入 QQ 交流群</h3><span>问题 · 建议 · 交流</span></div><p class="contact-description">扫码进群，直接与作者沟通，分享你的反馈和功能建议。</p>
  ${qr ? `<div class="contact-qr-frame"><div class="contact-qr-viewport"><img class="contact-group-qr" src="${esc(qr)}" alt="足球记录 QQ 交流群入群二维码" /></div></div><a class="contact-save-qr" href="${esc(qr)}" download="足球记录交流群二维码.png">保存二维码图片</a><p class="contact-qr-hint">使用 QQ 扫一扫，或保存图片后在 QQ 中识别。</p>` : `<div class="contact-qr-placeholder" role="status"><strong>群二维码待提供</strong><span>你也可以先通过下方邮箱联系作者</span></div>`}</section>
  <section class="panel contact-email-panel"><div class="panel-head"><h3>邮件联系</h3><span>随时欢迎反馈</span></div><p class="contact-description">使用问题、功能建议，都可以写信告诉我。</p><a class="contact-email-address" href="mailto:${authorContact.email}">${authorContact.email}</a><a class="primary-button contact-email-action" href="mailto:${authorContact.email}">发送邮件<span aria-hidden="true">↗</span></a></section>`;
}

function renderDetail() {
  const match = state.history.find((item) => item.id === state.detailMatchId);
  if (!match) return "";
  const score = scoreOf(match);
  return `<button class="back-link" data-action="back-history">‹ 返回历史</button><div class="section-head" style="margin-top:20px"><div><h2>${esc(match.title)}</h2><p>${esc(match.date)} · ${esc(match.venue)}</p></div><span class="${match.result}">${match.result === "win" ? "胜" : match.result === "loss" ? "负" : "平"}</span></div>
    <section class="panel"><div class="detail-score"><span>${esc(match.home)}<br><small class="detail-team-label">我方</small></span><strong>${match.final || `${score.for} - ${score.against}`}</strong><span style="text-align:right">${esc(match.away)}<br><small class="detail-team-label">对方</small></span></div><div class="metric-grid detail-metric-grid" style="margin:0"><div class="metric"><span class="metric-label">出场时间</span><b class="metric-value">${formatAppearanceDuration(match)}</b></div><div class="metric"><span class="metric-label">距离(km)</span><b class="metric-value">${formatDistanceKm(match.distance)}</b></div></div><button class="route-entry" data-action="open-routes" aria-label="查看比赛路线"><span><strong>路线</strong><small>GPS 轨迹 · 热力图</small></span><span class="entry-chevron" aria-hidden="true">›</span></button></section>
    <section class="panel"><div class="panel-head"><h3>完整时间线</h3><button class="ghost-button" data-action="add-event">＋ 补录</button></div><div class="timeline">${(match.events || []).length ? match.events.map(renderTimelineRow).join("") : `<div class="empty-state" style="padding:20px"><p>这场比赛没有事件明细</p><button class="secondary-button" data-action="add-event">补录第一条事件</button></div>`}</div></section>
    <section class="panel"><div class="panel-head"><h3>数据说明</h3><span>可修正</span></div><p class="data-explanation">修改或删除事件后，比分、出场区间和生涯统计会自动重算。HealthKit 没有数据时显示“未记录”。</p></section>`;
}

function canLoadMapTiles(model) { return model.source === "mock" && /^https?:$/.test(window.location?.protocol || ""); }
function renderMapBackground(model, muted = false) {
  let tiles = "";
  if (canLoadMapTiles(model)) {
    const p = model.projection, half = Math.PI * MAP_RADIUS;
    const zoom = Math.max(0, Math.min(19, Math.floor(Math.log2(2 * half * p.scale / 256))));
    const count = 2 ** zoom, size = 2 * half / count, pixels = size * p.scale;
    const left = p.cx - 160 / p.scale, right = p.cx + 160 / p.scale, top = p.cy + 108 / p.scale, bottom = p.cy - 108 / p.scale;
    for (let x = Math.floor((left + half) / size); x <= Math.floor((right + half) / size); x++) for (let y = Math.floor((half - top) / size); y <= Math.floor((half - bottom) / size); y++) {
      if (y < 0 || y >= count) continue;
      tiles += `<image class="route-tile" href="https://tile.openstreetmap.org/${zoom}/${(x % count + count) % count}/${y}.png" x="${160 + (-half + x * size - p.cx) * p.scale}" y="${108 - (half - y * size - p.cy) * p.scale}" width="${pixels + .2}" height="${pixels + .2}"/>`;
    }
  }
  return `<rect width="320" height="216" fill="#e2e8df"/><path d="M0 54H320M0 108H320M0 162H320M80 0V216M160 0V216M240 0V216" stroke="#cad5c9" stroke-width=".6"/>${tiles}${muted ? '<rect width="320" height="216" fill="#fff" fill-opacity=".45"/>' : ""}`;
}
function renderMapScale(model) {
  const meters = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000].filter(m => m / model.projection.metersPerPixel <= 75).at(-1) || 1;
  const width = meters / model.projection.metersPerPixel;
  return `<g fill="#183d2e" font-size="14"><rect x="10" y="179" width="${Math.max(48, width + 18)}" height="30" rx="5" fill="#fff" fill-opacity=".9"/><path d="M18 194v7h${width}v-7" fill="none" stroke="#183d2e" stroke-width="1.5"/><text x="18" y="192">${meters} m</text><rect x="285" y="8" width="27" height="42" rx="5" fill="#fff" fill-opacity=".9"/><text x="298" y="23" text-anchor="middle">北</text><path d="M298 29l-4 12h8z"/></g>`;
}
function renderCalibrationBoundary(model) {
  if (!model.calibration) return "";
  return `<polygon points="${model.calibration.corners.map(c => { const p = projectPoint(c, model.projection); return `${p.x},${p.y}`; }).join(" ")}" fill="#315e51" fill-opacity=".04" stroke="#315e51" stroke-width="1.6" stroke-dasharray="5 3"><title>用户校准的场地边界</title></polygon>`;
}
function renderRouteMap(model, type, editing = false) {
  let content;
  if (type === "heat") {
    const cells = [...model.heatCells].sort((a, b) => a.intensity - b.intensity).map(cell => `<circle cx="${cell.x}" cy="${cell.y}" r="${Math.min(14, Math.max(4, model.cellPixels * .52))}" fill="hsl(${Math.round(52 - cell.intensity * 48)}, 95%, 49%)" opacity="${.1 + cell.intensity * .82}"/>`).join("");
    content = `<defs><filter id="route-heat-soften"><feGaussianBlur stdDeviation="1.6"/></filter></defs><g filter="url(#route-heat-soften)">${cells}</g>`;
  } else {
    content = model.segments.map(segment => `<polyline points="${segment.map(p => `${p.x.toFixed(2)},${p.y.toFixed(2)}`).join(" ")}" fill="none" stroke="#126756" stroke-width="1.5" stroke-opacity=".75" stroke-linejoin="round" stroke-linecap="round"/>`).join("");
    const start = model.points[0], end = model.points.at(-1);
    if (start) content += `<circle cx="${start.x}" cy="${start.y}" r="4.5" fill="#d5ff60" stroke="#183d2e" stroke-width="1.5"><title>开始</title></circle><circle cx="${end.x}" cy="${end.y}" r="4.5" fill="#ed8059" stroke="#183d2e" stroke-width="1.5"><title>结束</title></circle>`;
  }
  if (editing) content += `<polygon points="${state.modal.corners.map(c => { const p = projectPoint(c, model.projection); return `${p.x},${p.y}`; }).join(" ")}" fill="#315e51" fill-opacity=".06" stroke="#315e51" stroke-width="1.5" ${state.modal.confirmed.every(Boolean) ? "" : 'stroke-dasharray="4 3"'}/>${state.modal.corners.map((c, i) => { const p = projectPoint(c, model.projection); return `<g><circle cx="${p.x}" cy="${p.y}" r="11" fill="${i === state.modal.corner ? "#183d2e" : "#fff"}" stroke="#183d2e"/><text x="${p.x}" y="${p.y + 4}" text-anchor="middle" font-size="14" fill="${i === state.modal.corner ? "#fff" : "#183d2e"}">${i + 1}</text></g>`; }).join("")}`;
  return `<div class="route-map-frame"><svg class="route-map" ${editing ? 'data-calibration-map="true"' : 'role="img"'} viewBox="0 0 320 216" aria-label="${editing ? "点击地图设置所选场地角点" : type === "heat" ? "仅上场区间的 GPS 停留热力图" : "比赛期间的 GPS 运行轨迹"}"><title>${type === "heat" ? "上场热力图" : "比赛 GPS 路线图"}</title>${renderMapBackground(model, type === "heat")}${editing ? "" : renderCalibrationBoundary(model)}${content}${renderMapScale(model)}</svg>${canLoadMapTiles(model) ? `<p class="route-map-status" role="status">地图加载中…</p><span class="route-attribution">© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap contributors</a></span>` : `<p class="route-map-status">${model.source === "mock" ? "本地文件模式无底图，请从预览网址打开。" : "底图未接入，轨迹仍按实际比例和方位展示。"}</p>`}</div>`;
}

function renderRouteGallery() {
  const match = state.history.find((item) => item.id === state.detailMatchId);
  if (!match) return renderHistory();
  const model = createRouteModel(match);
  const hasRoute = model.points.length >= 2;
  const isDemo = match.route?.source === "mock";
  return `<button class="back-link route-back" data-action="back-detail">‹ 返回比赛详情</button>
    <div class="section-head route-page-heading"><div><h2>比赛路线</h2><p>${esc(match.title)}<br>${esc(match.date)} · ${esc(match.venue)}</p></div></div>
    ${hasRoute ? `<p class="route-quality-note">${model.calibration ? "已校准场地边界" : "未校准场地 · 保留实际比例与方位"}${model.quality.rejected || model.quality.gaps ? `<br>已跳过 ${model.quality.rejected} 个无效定位，${model.quality.gaps} 处断采已断开。` : ""}${model.quality.unknownAccuracy ? `<br>${model.quality.unknownAccuracy} 个定位点精度未知，不计入热力图。` : ""}</p>` : ""}
    <div class="route-gallery" data-route-match="${esc(match.id)}">
      <figure class="panel route-figure"><div class="route-figure-head"><h3>GPS 路线图</h3>${isDemo && hasRoute ? `<span class="route-simulation-label">模拟数据</span>` : ""}</div>
        ${hasRoute ? `${renderRouteMap(model, "gps")}<figcaption class="route-legend"><span><i class="route-legend-dot start" aria-hidden="true"></i>开始</span><span><i class="route-legend-dot end" aria-hidden="true"></i>结束</span><span>含场下轨迹</span></figcaption>` : `<div class="route-empty"><strong>${model.points.length ? "轨迹数据不足" : "路线未记录"}</strong><p>${model.points.length ? "有效定位点不足，无法形成完整路线。" : "这场比赛没有 GPS 轨迹数据。"}</p></div>`}
      </figure>
      <figure class="panel route-figure"><div class="route-figure-head"><h3>热力图</h3>${isDemo && model.heatAvailable ? `<span class="route-simulation-label">模拟数据</span>` : ""}</div>
        <p class="route-scope-note">仅上场 · 暂停与断采不计入</p>${model.heatAvailable ? `${renderRouteMap(model, "heat")}<figcaption class="heat-legend"><span>停留少</span><i class="heat-gradient" aria-hidden="true"></i><span>停留多</span></figcaption>` : `<div class="route-empty"><strong>${hasRoute ? "热力图未生成" : "暂无热力图"}</strong><p>${esc(model.heatReason)}</p></div>`}
      </figure>
    </div>${hasRoute ? `<button class="route-calibration-entry" data-action="calibrate-venue">${model.calibration ? "调整场地校准" : "校准场地（可选）"}</button><span class="route-calibration-status">赛后标记四角，同一场地可复用；不改变原始轨迹。</span>` : ""}`;
}

function renderWatch() {
  const match = state.liveMatch;
  if (!match) return renderStartScreen("watch");
  const score = scoreOf(match);
  const on = currentOnField(match);
  const personal = personalStatsOf(match);
  return `<div class="watch-label">Apple Watch · 45mm <span>198 × 242 pt</span></div><div class="watch-multi">
    <div class="watch-preview-page"><div class="watch-page-caption">比赛与实时数据</div><section class="watch-card"><div class="watch-screen">
      <div class="watch-top"><span>9:41</span><span class="watch-state">${match.status === "paused" ? "已暂停" : "记录中"}</span></div>
      <div class="watch-compact-score"><span class="watch-team">我方</span><div class="watch-score-value"><strong>${score.for}</strong><em>:</em><strong>${score.against}</strong></div><span class="watch-team">对方</span></div>
      <div class="watch-clock-grid"><div class="watch-clock"><span>比赛时间</span><b data-live-match-clock>${formatClock(matchSeconds(match))}</b></div><div class="watch-clock"><span>上场时间</span><b data-live-appearance-clock>${formatClock(appearanceSeconds(match))}</b></div></div>
      <div class="watch-health-grid"><div><span>心率</span><b>${health.heartRate}</b></div><div><span>距离</span><b>${health.distance}</b></div><div><span>速度</span><b>${health.speed}</b></div><div><span>GPS</span><b class="good">${health.gps}</b></div></div>
      <div class="watch-control-pair"><button class="watch-primary-action" data-action="toggle-field">${on ? "下场" : "上场"}</button><button class="watch-secondary-action" data-action="open-controls">比赛控制</button></div>
    </div></section></div>
    <div class="watch-preview-page"><div class="watch-page-caption">快速记录</div><section class="watch-card"><div class="watch-screen">
      <div class="watch-top"><span>9:41</span><span class="watch-state">快速记录</span></div>
      <div class="watch-quick-head"><h3>本场比分</h3><b class="watch-inline-score">${score.for} : ${score.against}</b></div>
      <div class="watch-personal-stats"><span>进球 <b data-personal-goals>${personal.goals}</b></span><span>助攻 <b data-personal-assists>${personal.assists}</b></span></div>
      <div class="watch-score-grid"><button class="watch-score-button" data-action="quick-score" data-quick="mine">我进球</button><button class="watch-score-button" data-action="quick-score" data-quick="assist">我助攻</button><button class="watch-score-button" data-action="quick-score" data-quick="for">进球</button><button class="watch-score-button" data-action="quick-score" data-quick="against">失球</button></div>
      ${renderQuickRecordFeedback(match)}
    </div></section></div>
  </div><p class="watch-hint">两个页面同时展示，可直接点击操作。</p>`;
}

function renderQuickRecordFeedback(match) {
  const record = state.quickRecord;
  const saved = record?.matchId === match.id && match.events.some((event) => event.id === record.eventId);
  if (!saved) return `<div class="watch-record-feedback" role="status" aria-live="polite"><span><b>单击即记录</b><small>记错可撤销</small></span></div>`;
  const score = scoreOf(match);
  return `<div class="watch-record-feedback recorded" role="status" aria-live="polite"><span><b>✓ 已记：${esc(record.label)}</b><small>比分 ${score.for} : ${score.against}</small></span><button class="watch-undo-button" data-action="undo-score" aria-label="撤销${esc(record.label)}">撤销</button></div>`;
}

function renderModal() {
  if (state.modal.type === "calibration") return renderCalibrationModal();
  if (state.modal.type === "start") return `<div class="modal-backdrop"><div class="modal"><h2>开始一场比赛</h2><p>比赛开始后，比赛时间、上场时间和健康数据会按规则持续记录。</p><div class="choice-grid"><button class="choice ${state.modal.role === "starter" ? "selected" : ""}" data-choice-role="starter"><b>首发</b><span>比赛开始自动上场</span></button><button class="choice ${state.modal.role === "sub" ? "selected" : ""}" data-choice-role="sub"><b>替补</b><span>需要时再点击上场</span></button></div><label class="field-label">比赛名称</label><input class="text-input" id="match-title" value="周末约球" /><label class="field-label">场地</label><input class="text-input" id="match-venue" value="朝阳公园 3 号场" /><div class="modal-actions"><button class="secondary-button" data-action="close-modal">取消</button><button class="primary-button" data-action="confirm-start">开始记录</button></div></div></div>`;
  if (state.modal.type === "controls") return `<div class="modal-backdrop"><div class="modal"><h2>比赛控制</h2><p>暂停会同时冻结比赛时间和上场时间，健康数据仍保持实时展示。</p><div class="control-modal-grid"><button class="primary-button" data-action="${state.liveMatch?.status === "paused" ? "resume" : "pause"}">${state.liveMatch?.status === "paused" ? "继续比赛" : "暂停比赛"}</button><button class="secondary-button danger-button" data-action="end">结束比赛</button></div><div class="modal-actions"><button class="secondary-button" data-action="close-modal">返回比赛</button></div></div></div>`;
  if (state.modal.type === "end") return `<div class="modal-backdrop"><div class="modal"><h2>结束这场比赛？</h2><p>结束后记录会保存到历史，下一场比赛仍可从比赛主页重新开始。</p><div class="modal-actions"><button class="secondary-button" data-action="close-modal">继续比赛</button><button class="primary-button" data-action="confirm-end">结束并保存</button></div></div></div>`;
  if (state.modal.type === "score") return `<div class="modal-backdrop"><div class="modal"><h2>记录比分事件</h2><p>先记下发生了什么，球员姓名可以赛后在 iPhone 补充。</p><div class="choice-grid"><button class="choice ${state.modal.impact === "for" ? "selected" : ""}" data-score-impact="for"><b>我方进球</b><span>比分 +1</span></button><button class="choice ${state.modal.impact === "against" ? "selected" : ""}" data-score-impact="against"><b>对方进球</b><span>比分 -1</span></button></div><div class="choice-grid"><button class="choice ${state.modal.kind === "normal" ? "selected" : ""}" data-score-kind="normal"><b>普通进球</b><span>记录进球人</span></button><button class="choice ${state.modal.kind === "ownGoal" ? "selected" : ""}" data-score-kind="ownGoal"><b>乌龙球</b><span>记录归属</span></button></div><label class="field-label">快速备注</label><input class="text-input" id="score-note" value="${esc(state.modal.note || "我进球")}" /><div class="modal-actions"><button class="secondary-button" data-action="close-modal">取消</button><button class="primary-button" data-action="confirm-score">保存事件</button></div></div></div>`;
  if (state.modal.type === "edit") { const event = state.modal.event; return `<div class="modal-backdrop"><div class="modal"><h2>编辑时间线</h2><p>${esc(event.label)} · ${esc(event.time)}。你可以把误记的事件删除，统计会自动重算。</p><div class="panel" style="margin:0;background:#f0eee7"><div class="timeline-row"><span class="timeline-time">${esc(event.time)}</span><span class="timeline-node ${iconFor(event)}"></span><div><div class="timeline-title">${esc(event.label)}</div><div class="timeline-detail">${esc(event.detail || "操作记录")}</div></div></div></div><div class="modal-actions"><button class="secondary-button" data-action="close-modal">保留</button><button class="primary-button event-delete-button" data-action="delete-event">删除事件</button></div></div></div>`; }
  return "";
}

function openCalibration() {
  const match = state.history.find(m => m.id === state.detailMatchId);
  const model = createRouteModel(match);
  if (!model.projection) return;
  const saved = model.calibration;
  state.modal = { type: "calibration", matchId: match.id, model, baseScale: model.projection.scale, corner: 0, confirmed: saved ? [true, true, true, true] : [false, false, false, false], corners: saved ? saved.corners.map(c => ({ ...c })) : [[64, 52], [256, 52], [256, 164], [64, 164]].map(([x, y]) => unprojectPoint(x, y, model.projection)) };
  zoomCalibration(.55, false);
  render();
}
function renderCalibrationModal() {
  const draft = state.modal;
  const count = draft.confirmed.filter(Boolean).length;
  const valid = validateCalibrationCorners(draft.corners);
  return `<div class="modal-backdrop"><div class="modal calibration-modal" role="dialog" aria-modal="true" aria-labelledby="calibration-title"><h2 id="calibration-title">校准场地</h2><p>在地图上按顺时针标记场地四角。选中角点后可点击地图，或用方向按钮微调。</p><div class="calibration-preview">${renderRouteMap(draft.model, "gps", true)}</div><div class="calibration-nudge"><button data-map-zoom="out">－ 缩小地图</button><button data-map-zoom="in">＋ 放大地图</button></div><div>${draft.corners.map((c, i) => `<button class="corner-control ${draft.corner === i ? "selected" : ""}" data-corner="${i}" aria-pressed="${draft.corner === i}"><strong>角点 ${i + 1}</strong><span>${draft.confirmed[i] ? "已标记" : "待标记"}${draft.corner === i ? " · 当前" : ""}</span></button>`).join("")}</div><div class="calibration-nudge"><button data-nudge="north">↑ 向北 1 米</button><button data-nudge="south">↓ 向南 1 米</button><button data-nudge="west">← 向西 1 米</button><button data-nudge="east">→ 向东 1 米</button></div><p class="route-quality-note" role="status">${count < 4 ? `已标记 ${count}/4 个角点，默认位置仅作参考。` : valid ? "边界可保存，将在同一场地的比赛中复用。" : "四角不能交叉或重合，请按顺时针调整。"}</p>${draft.model.calibration ? `<button class="route-calibration-entry" data-action="clear-calibration">清除当前场地校准</button>` : ""}<div class="calibration-actions"><button class="secondary-button" data-action="close-modal">取消</button><button class="primary-button" data-action="save-calibration" ${count < 4 || !valid ? "disabled" : ""}>保存场地</button></div></div></div>`;
}
function zoomCalibration(multiplier, rerender = true) {
  if (state.modal?.type !== "calibration") return;
  const draft = state.modal, p = draft.model.projection;
  const scale = Math.max(draft.baseScale * .1, Math.min(draft.baseScale * 4, p.scale * multiplier));
  draft.model.projection = { ...p, scale, metersPerPixel: p.factor / scale };
  draft.model.points = draft.model.points.map(point => projectPoint(point, draft.model.projection));
  draft.model.segments = draft.model.segments.map(segment => segment.map(point => projectPoint(point, draft.model.projection)));
  if (rerender) render();
}
function nudgeCalibration(direction) {
  if (state.modal?.type !== "calibration") return;
  const draft = state.modal, point = mercator(draft.corners[draft.corner]);
  const meter = 1 / draft.model.projection.factor;
  if (direction === "north") point.my += meter;
  if (direction === "south") point.my -= meter;
  if (direction === "west") point.mx -= meter;
  if (direction === "east") point.mx += meter;
  draft.corners[draft.corner] = inverseMercator(point.mx, point.my);
  draft.confirmed[draft.corner] = true;
  render();
}

function updateMapTileStatus(event) {
  const tile = event.target;
  if (!tile?.classList?.contains?.("route-tile")) return;
  tile.dataset.loaded = event.type === "load" ? "true" : "failed";
  const frame = tile.closest(".route-map-frame"), status = frame?.querySelector(".route-map-status");
  if (!status) return;
  const images = [...frame.querySelectorAll(".route-tile")];
  const failed = images.some(image => image.dataset.loaded === "failed");
  const ready = images.every(image => image.dataset.loaded === "true");
  status.hidden = !failed && ready;
  status.textContent = failed ? "底图未完整加载，轨迹仍按实际比例展示。" : !ready && frame.dataset?.mapTimedOut === "true" ? "底图暂不可用，轨迹仍按实际比例展示。" : "地图加载中…";
}
function monitorMapTiles() {
  const tiles = [...document.querySelectorAll(".route-tile")];
  tiles.forEach(tile => { tile.addEventListener("load", updateMapTileStatus); tile.addEventListener("error", updateMapTileStatus); });
  if (tiles.length) setTimeout(() => {
    tiles.forEach(tile => {
      if (tile.isConnected && !tile.dataset.loaded) {
        const frame = tile.closest(".route-map-frame");
        const status = frame?.querySelector(".route-map-status");
        if (frame?.dataset) frame.dataset.mapTimedOut = "true";
        if (status) { status.hidden = false; status.textContent = "底图暂不可用，轨迹仍按实际比例展示。"; }
      }
    });
  }, 10000);
}

function toast(message) { const el = $("#toast"); el.textContent = message; el.classList.add("show"); clearTimeout(window.__toast); window.__toast = setTimeout(() => el.classList.remove("show"), 2300); }
function addEventToMatch(match, event) { match.events.push(event); match.events.sort((a, b) => eventSecond(a) - eventSecond(b)); }
function refreshHistoricalScore(match) {
  if (match.status !== "completed") return;
  const score = scoreOf(match);
  match.final = `${score.for} - ${score.against}`;
  match.result = score.for > score.against ? "win" : score.for < score.against ? "loss" : "draw";
}
function nowTime() { return new Date().toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }); }
function makeLiveEvent(type, label, detail = "") { const match = state.liveMatch; const second = matchSeconds(match); return { id: `e${Date.now()}`, type, time: nowTime(), minute: Math.floor(second / 60), matchSecond: second, elapsedSecond: Math.max(0, (Date.now() - match.startedAtMs) / 1000), label, detail }; }

function refreshLiveClocks() {
  const match = state.liveMatch;
  if (!match) return;
  const matchClock = formatClock(matchSeconds(match));
  const appearanceClock = formatClock(appearanceSeconds(match));
  document.querySelectorAll("[data-live-match-clock]").forEach((node) => { node.textContent = matchClock; });
  document.querySelectorAll("[data-live-appearance-clock]").forEach((node) => { node.textContent = appearanceClock; });
}

function togglePause() {
  const match = state.liveMatch;
  if (!match) return;
  const at = Date.now();
  if (match.status === "paused") {
    match.pausedTotalMs = (match.pausedTotalMs || 0) + Math.max(0, at - (match.pausedAtMs || at));
    match.pausedAtMs = null;
    match.status = "running";
    addEventToMatch(match, makeLiveEvent("matchResumed", "比赛继续", "时间继续计时"));
    toast("比赛继续，两个时间同步计时");
  } else {
    match.pausedAtMs = at;
    match.status = "paused";
    addEventToMatch(match, makeLiveEvent("matchPaused", "比赛暂停", "比赛时间与上场时间冻结"));
    toast("比赛已暂停，两个时间冻结");
  }
  state.modal = null;
  render();
}

function toggleField() {
  const match = state.liveMatch;
  if (!match) return;
  const entering = !currentOnField(match);
  addEventToMatch(match, makeLiveEvent(entering ? "enteredField" : "leftField", entering ? "上场" : "下场", entering ? "开始累计上场时间" : "停止累计上场时间"));
  toast(entering ? "已上场，上场时间开始累计" : "已下场，上场时间暂停累计");
  render();
}

function confirmStart() {
  const title = $("#match-title")?.value.trim() || "周末约球";
  const venue = $("#match-venue")?.value.trim() || "未命名场地";
  const role = state.modal.role || "starter";
  const startedAtMs = Date.now();
  const startedAt = new Date(startedAtMs).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
  const events = [{ id: `e${startedAtMs}`, type: "matchStarted", time: startedAt, minute: 0, matchSecond: 0, elapsedSecond: 0, label: "比赛开始", detail: role === "starter" ? "首发 · 自动上场" : "替补 · 等待上场" }];
  if (role === "starter") events.push({ id: `e${startedAtMs + 1}`, type: "enteredField", time: startedAt, minute: 0, matchSecond: 0, elapsedSecond: 0, label: "上场", detail: "首发" });
  state.liveMatch = { id: `live-${startedAtMs}`, status: "running", title, venue, date: formatShortDate(), home: "蓝队", away: "橙队", startedAt, startedAtMs, pausedAtMs: null, pausedTotalMs: 0, finalMatchSeconds: null, events };
  state.quickRecord = null;
  state.lastQuickScoreAtMs = -Infinity;
  state.modal = null;
  state.contactOpen = false;
  state.routeOpen = false;
  state.detailMatchId = null;
  state.activeTab = "match";
  toast("比赛已开始，Watch 与 iPhone 已同步");
  render();
}

function finishMatch() {
  const match = state.liveMatch;
  if (!match) return;
  if (match.status === "paused") {
    const at = Date.now();
    match.pausedTotalMs = (match.pausedTotalMs || 0) + Math.max(0, at - (match.pausedAtMs || at));
    match.pausedAtMs = null;
  }
  match.finalMatchSeconds = matchSeconds(match);
  match.endMinute = Math.floor(match.finalMatchSeconds / 60);
  if (currentOnField(match)) addEventToMatch(match, { ...makeLiveEvent("leftField", "下场", "比赛结束自动闭合"), matchSecond: match.finalMatchSeconds, minute: match.endMinute });
  addEventToMatch(match, { ...makeLiveEvent("matchEnded", "比赛结束", "已保存在本地"), matchSecond: match.finalMatchSeconds, minute: match.endMinute });
  match.status = "completed";
  const score = scoreOf(match);
  state.history.unshift({ ...match, final: `${score.for} - ${score.against}`, result: score.for > score.against ? "win" : score.for < score.against ? "loss" : "draw", appearance: `${Math.floor(appearanceSeconds(match) / 60)} 分钟`, distance: health.distance });
  state.liveMatch = null;
  state.quickRecord = null;
  state.lastQuickScoreAtMs = -Infinity;
  state.activeTab = "match";
  state.contactOpen = false;
  state.routeOpen = false;
  state.detailMatchId = null;
  state.modal = null;
  toast("比赛已结束，下一场比赛可以立即开始");
  render();
}

function recordQuickScore(quick) {
  const actions = {
    mine: { impact: "for", label: "我进球", scorer: "self", assister: null },
    assist: { impact: "for", label: "我助攻", scorer: null, assister: "self" },
    for: { impact: "for", label: "我方进球", scorer: null, assister: null },
    against: { impact: "against", label: "对方进球", scorer: null, assister: null }
  };
  const match = state.liveMatch;
  const action = actions[quick];
  if (!match || !action) return;
  const at = Date.now();
  if (at - state.lastQuickScoreAtMs < 1000) return;
  const event = { ...makeLiveEvent("scoreEvent", action.label), ...action, id: `quick-${match.id}-${at}`, kind: "normal", detail: quick === "for" || quick === "against" ? "进球人待补充" : action.label };
  addEventToMatch(match, event);
  state.lastQuickScoreAtMs = at;
  state.quickRecord = { matchId: match.id, eventId: event.id, label: action.label };
  state.modal = null;
  render();
}

function undoQuickScore() {
  const record = state.quickRecord;
  const match = state.liveMatch;
  if (!record || !match || record.matchId !== match.id) return;
  match.events = match.events.filter((event) => event.id !== record.eventId);
  state.quickRecord = null;
  state.lastQuickScoreAtMs = -Infinity;
  render();
  toast("已撤销，比分和个人统计已恢复");
}

function confirmScore() {
  if (!state.liveMatch && !state.detailMatchId) return;
  const match = state.detailMatchId ? state.history.find((item) => item.id === state.detailMatchId) : state.liveMatch;
  const note = $("#score-note")?.value.trim() || "比分事件";
  const second = state.detailMatchId ? (match.minute || 0) * 60 : matchSeconds(match);
  const personalGoal = state.modal.impact === "for" && state.modal.kind === "normal" && note.includes("我进球");
  const personalAssist = state.modal.impact === "for" && state.modal.kind === "normal" && note.includes("我助攻");
  addEventToMatch(match, { id: `${state.detailMatchId ? "h" : "e"}${Date.now()}`, type: "scoreEvent", impact: state.modal.impact, kind: state.modal.kind, scorer: personalGoal ? "self" : null, assister: personalAssist ? "self" : null, time: state.detailMatchId ? "赛后补录" : nowTime(), minute: Math.floor(second / 60), matchSecond: second, label: state.modal.impact === "for" ? "我方进球" : "对方进球", detail: note });
  refreshHistoricalScore(match);
  state.modal = null;
  toast(state.detailMatchId ? "已补录，统计已重算" : "比分事件已记录");
  render();
}

function deleteEvent() { const match = state.modal.matchId === state.liveMatch?.id ? state.liveMatch : state.history.find((item) => item.id === state.modal.matchId); if (match) { match.events = match.events.filter((entry) => entry.id !== state.modal.event.id); refreshHistoricalScore(match); if (state.quickRecord?.eventId === state.modal.event.id && state.quickRecord.matchId === match.id) { state.quickRecord = null; state.lastQuickScoreAtMs = -Infinity; } state.modal = null; toast("事件已删除，统计已重算"); render(); } }

function handleClick(event) {
  if (state.modal?.type === "calibration" && Number.isFinite(event.clientX)) {
    const svg = event.target.closest("[data-calibration-map]");
    if (svg) {
      const box = svg.getBoundingClientRect(), draft = state.modal;
      draft.corners[draft.corner] = unprojectPoint((event.clientX - box.left) / box.width * 320, (event.clientY - box.top) / box.height * 216, draft.model.projection);
      draft.confirmed[draft.corner] = true;
      const next = draft.confirmed.findIndex(done => !done);
      if (next >= 0) draft.corner = next;
      render(); return;
    }
  }
  const target = event.target.closest("button");
  if (!target) return;
  if (target.dataset.corner !== undefined && state.modal?.type === "calibration") { state.modal.corner = Number(target.dataset.corner); render(); return; }
  if (target.dataset.mapZoom) { zoomCalibration(target.dataset.mapZoom === "out" ? .8 : 1.25); return; }
  if (target.dataset.nudge) { nudgeCalibration(target.dataset.nudge); return; }
  if (target.dataset.tab) { state.activeTab = target.dataset.tab; state.detailMatchId = null; state.contactOpen = false; state.routeOpen = false; render(); return; }
  if (target.dataset.historyId) { state.detailMatchId = target.dataset.historyId; state.routeOpen = false; render(); return; }
  if (target.dataset.setting) { state.settings[target.dataset.setting] = !state.settings[target.dataset.setting]; toast(`${target.dataset.setting === "health" ? "HealthKit 数据" : target.dataset.setting === "haptics" ? "触觉反馈" : "匿名产品分析"}已${state.settings[target.dataset.setting] ? "开启" : "关闭"}`); render(); return; }
  if (target.dataset.choiceRole) { state.modal.role = target.dataset.choiceRole; render(); return; }
  if (target.dataset.scoreImpact) { state.modal.impact = target.dataset.scoreImpact; render(); return; }
  if (target.dataset.scoreKind) { state.modal.kind = target.dataset.scoreKind; render(); return; }
  if (target.dataset.eventId) { const match = state.detailMatchId ? state.history.find((item) => item.id === state.detailMatchId) : state.liveMatch; const item = match?.events.find((entry) => entry.id === target.dataset.eventId); if (item) { state.modal = { type: "edit", event: item, matchId: match.id }; render(); } return; }
  const action = target.dataset.action;
  if (action === "calibrate-venue") { openCalibration(); return; }
  if (action === "save-calibration" && state.modal?.type === "calibration") {
    if (!state.modal.confirmed.every(Boolean)) return;
    const match = state.history.find(m => m.id === state.modal.matchId);
    const saved = storeVenueCalibration(match, state.modal.corners);
    if (!saved.ok) return;
    state.modal = null; render(); toast(saved.persisted ? "场地校准已保存，下次可直接复用" : "已校准，当前浏览器无法持久保存"); return;
  }
  if (action === "clear-calibration" && state.modal?.type === "calibration") { clearVenueCalibration(state.history.find(m => m.id === state.modal.matchId)); state.modal = null; render(); toast("已清除场地校准，原始轨迹保持不变"); return; }
  if (action === "open-routes") { if (state.history.some((match) => match.id === state.detailMatchId)) { state.routeOpen = true; render(); } return; }
  if (action === "back-detail") { state.routeOpen = false; render(); return; }
  if (action === "contact-author") { state.contactOpen = true; state.detailMatchId = null; state.routeOpen = false; state.activeTab = "settings"; render(); return; }
  if (action === "back-settings") { state.contactOpen = false; state.activeTab = "settings"; render(); return; }
  if (action === "new-match") { state.modal = { type: "start", role: "starter" }; render(); return; }
  if (action === "close-modal") { state.modal = null; render(); return; }
  if (action === "confirm-start") { confirmStart(); return; }
  if (action === "open-controls") { state.modal = { type: "controls" }; render(); return; }
  if (action === "quick-score") { recordQuickScore(target.dataset.quick); return; }
  if (action === "undo-score") { undoQuickScore(); return; }
  if (action === "score") { state.modal = { type: "score", impact: "for", kind: "normal", note: "我进球" }; render(); return; }
  if (action === "toggle-field") { toggleField(); return; }
  if (action === "pause" || action === "resume") { togglePause(); return; }
  if (action === "end") { if (state.liveMatch) { state.modal = { type: "end" }; render(); } return; }
  if (action === "confirm-end") { finishMatch(); return; }
  if (action === "confirm-score") { confirmScore(); return; }
  if (action === "delete-event") { deleteEvent(); return; }
  if (action === "add-event") { state.modal = { type: "score", impact: "for", kind: "normal", note: "补录我方进球" }; render(); return; }
  if (action === "back-history") { state.detailMatchId = null; state.routeOpen = false; render(); return; }
  if (action === "toast") toast(target.dataset.message || "操作已记录");
}

document.addEventListener("click", handleClick);
window.__setTab = (tab) => { state.activeTab = tab; state.detailMatchId = null; state.contactOpen = false; state.routeOpen = false; render(); };
window.setInterval(refreshLiveClocks, 1000);
render();
