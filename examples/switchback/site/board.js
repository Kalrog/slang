// The board: a day's times to the summit (today's by default, ?day=n for
// another), as a graph with the player's own among them, and the fastest
// of those who gave a name.
import { api, player, clock, ordinal, thousands, date, shareText, header } from "./common.js";

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

let today = null;
let shown = null;

async function load() {
  try {
    today = await api("/api/today");
  } catch {
    $("field").innerHTML = `<div class="none">The board cannot be reached; try again later.</div>`;
    return;
  }
  $("stamp").textContent = `Expedition no. ${today.day}`;
  const asked = Number(new URLSearchParams(location.search).get("day"));
  const day = Number.isInteger(asked) && asked >= 1 && asked <= today.day ? asked : today.day;
  await show(day);
}

async function show(day) {
  let r;
  try {
    r = await api(`/api/days/${day}?player=${player()}`);
  } catch {
    $("field").innerHTML = `<div class="none">The board cannot be reached; try again later.</div>`;
    return;
  }
  shown = r;
  const isToday = day === today.day;
  $("kicker").textContent = isToday ? "Today's board" : "A day's board";
  $("title").textContent = `Expedition no. ${day}`;
  // (the date of another day: today's, n days back)
  const when = new Date(Date.parse(today.date + "T00:00:00Z") - (today.day - day) * 86400000).toISOString().slice(0, 10);
  $("when").textContent = date(when);
  const arrow = (to, label, glyph) => (to >= 1 && to <= today.day)
    ? `<a href="?day=${to}" aria-label="${label}">${glyph}</a>` : `<span aria-hidden="true">${glyph}</span>`;
  $("arrows").innerHTML = arrow(day - 1, "the day before", "‹") + arrow(day + 1, "the day after", "›");
  field(r, isToday);
  fastest(r, isToday);
}

function field(r, isToday) {
  if (r.count === 0) {
    $("field").innerHTML = `<div class="none">${isToday ? "Nobody has reached the summit today yet." : "Nobody reached the summit that day."}</div>` + youCard(r, isToday);
    bindShare(r);
    return;
  }
  const counts = r.bins.counts;
  const most = Math.max(1, ...counts);
  const mine = r.you ? Math.min(counts.length - 1, Math.max(0, Math.floor((r.you.time - r.bins.from) / r.bins.width))) : -1;
  const bars = counts.map((c, k) => {
    const from = r.bins.from + k * r.bins.width;
    const last = k === counts.length - 1;
    const range = `${clock(from, false)}–${last ? "" : clock(from + r.bins.width, false)}`;
    const cls = [k === mine ? "you" : "", c === 0 ? "empty" : ""].join(" ").trim();
    return `<i class="${cls}" style="height:${Math.max(c ? 2 : 1, 100 * c / most)}%">` +
      `${k === mine ? '<span class="flag">you</span>' : ""}<span class="tip">${range} · ${thousands(c)}</span></i>`;
  }).join("");
  $("field").innerHTML = `
    <div class="stats">
      <div><div class="caps">Drivers</div><div class="v num">${thousands(r.count)}</div></div>
      <div><div class="caps">Median</div><div class="v num">${clock(r.median)}</div></div>
      <div><div class="caps">Fastest</div><div class="v num">${clock(r.best)}</div></div>
    </div>
    <div class="graph">${bars}</div>
    <div class="axis"><span>${clock(r.bins.from, false)}</span><span>time to the summit</span><span>${clock(r.bins.from + r.bins.width * counts.length, false)}+</span></div>
    ${youCard(r, isToday)}`;
  bindShare(r);
}

function youCard(r, isToday) {
  if (r.you) {
    const ahead = r.count > 1 ? `faster than <b>${Math.round(r.you.ahead_of * 100)}%</b> of the day's drivers` : "the first to the summit";
    return `<div class="you-card"><div class="place num">${ordinal(r.you.rank)}</div>
      <div class="what">Your run: <b class="num">${clock(r.you.time)}</b><br>${ahead}</div>
      <button class="btn" id="share">Share</button></div>`;
  }
  if (isToday) {
    return `<div class="you-card idle"><div class="what">You have not driven today's valley yet. Your first run to the summit goes on the board.</div>
      <a class="btn" href="./" style="text-decoration:none">Start the expedition</a></div>`;
  }
  return "";
}

function bindShare(r) {
  const button = $("share");
  if (!button || !r.you) return;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(shareText(r.day, r.you, r.count));
      button.textContent = "Copied";
    } catch {
      button.textContent = "Copy failed";
    }
    setTimeout(() => { button.textContent = "Share"; }, 1600);
  });
}

function fastest(r, isToday) {
  const rows = r.top.map((t, i) =>
    `<li class="${t.you ? "you" : ""}"><span class="n">${i + 1}</span><span class="who">${esc(t.name)}</span><span class="num">${clock(t.time)}</span></li>`).join("");
  $("fastest").innerHTML = `<h2>Fastest ${isToday ? "today" : "that day"}</h2>
    ${rows ? `<ol>${rows}</ol>` : `<p class="hint">No named runs yet.</p>`}
    <p class="hint">Only drivers with a name are listed; give yours with the button at the top right.</p>`;
}

header(() => { if (shown) show(shown.day); });
load();
