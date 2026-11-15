// The drive page's part of the daily run (website/web/game.slang's
// launcher imports it). It asks the server which day it is and gives the
// game that day's valley (game/daily); when the game says its Summit Run
// reached the summit, it sends the run (the first of the day counts) and
// hands the day's times back to the game, which draws them.
import { api, player, name, clock, ordinal, thousands, date, shareText, header } from "./common.js";

let today = null;
let share = "";

const $ = (id) => document.getElementById(id);

// what the page says of the player's run of the day, before and after
function showDone(run) {
  if (!run) return;
  $("done").hidden = false;
  $("done").textContent = `Your run today: ${clock(run.time)}. Drive again to practise; it stays your run of the day.`;
}

function showResult(results, counted) {
  const you = results.you;
  if (!you) return;
  const what = counted ? "Your run of the day" : "Practice. Your run of the day";
  $("result").innerHTML = "";
  $("result").append(`${what}: ${clock(you.time)}, ${ordinal(you.rank)} of ${thousands(results.count)} · `);
  const link = document.createElement("a");
  link.href = "board.html";
  link.textContent = "see the board";
  $("result").append(link);
  share = shareText(results.day, you, results.count);
  $("share").hidden = false;
}

export async function setup(page) {
  header();
  $("share").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(share);
      $("share").textContent = "Copied";
    } catch {
      $("share").textContent = "Copy failed";
    }
    setTimeout(() => { $("share").textContent = "Share"; }, 1600);
  });
  try {
    today = await api(`/api/today?player=${player()}`);
    $("stamp").textContent = `Expedition no. ${today.day}`;
    $("today").textContent = `Today · ${date(today.date)} · valley ${today.seed}`;
    showDone(today.run);
  } catch {
    $("today").textContent = "The day's valley cannot be reached; try again later";
  }
}

export async function beforeStart(page) {
  if (!today) today = await api(`/api/today?player=${player()}`);
  page.env.SWITCHBACK_DAILY = today.day;
  page.env.SWITCHBACK_DAILY_DATE = today.date;
  page.env.SWITCHBACK_SEED = today.seed;
  if (today.run) page.env.SWITCHBACK_DAILY_TIME = today.run.time;
}

export function progress() {
  document.body.classList.add("loading");
}

export function started() {
  if (window.fitCanvas) window.fitCanvas();
}

export async function message(text, page) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  if (msg.kind !== "run") return;
  try {
    const answer = await api("/api/runs", { ...msg, player: player(), name: name() || undefined });
    const results = answer.results;
    if (!results) throw new Error(answer.reason || "the run was not taken");
    page.send(JSON.stringify({ kind: "results", counted: answer.ok === true, results }));
    showResult(results, answer.ok === true);
  } catch (e) {
    page.send(JSON.stringify({ kind: "offline", error: String(e && e.message || e) }));
  }
}
