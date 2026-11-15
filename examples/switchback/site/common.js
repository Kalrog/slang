// What both pages of the daily site share: the player (a random id kept
// in this browser, and the name they gave), the server's API, times as
// the game writes them, and the header (the day, the time to the next
// valley, the player's chip and its popover).

const PLAYER = "switchback.player";
const NAME = "switchback.name";
export const NAME_LENGTH = 20;

function store(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    if (value === null || value === "") localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {}
  return null;
}

// the player's id: 32 hex digits, made once
export function player() {
  let id = store(PLAYER);
  if (!/^[0-9a-f]{32}$/.test(id || "")) {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    id = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    store(PLAYER, id);
  }
  return id;
}

export const name = () => store(NAME) || "";

// GET path, or POST body to it: the JSON answer
export async function api(path, body) {
  const options = body === undefined ? {} : {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
  const res = await fetch(path, options);
  const data = await res.json().catch(() => null);
  if (!data) throw new Error(`the server answered ${res.status}`);
  return data;
}

// 812.4 -> "13:32.4"; tenths false -> "13:32"
export function clock(seconds, tenths = true) {
  if (seconds == null) return "-:--";
  const all = Math.floor(seconds * 10 + 0.0001);
  const minutes = Math.floor(all / 600);
  const rest = all - minutes * 600;
  const text = `${minutes}:${String(Math.floor(rest / 10)).padStart(2, "0")}`;
  return tenths ? `${text}.${rest % 10}` : text;
}

export function ordinal(n) {
  const tens = n % 100;
  if (tens >= 11 && tens <= 13) return `${n}th`;
  return n + (["th", "st", "nd", "rd"][n % 10] || "th");
}

export const thousands = (n) => n.toLocaleString("en-US");

// "2026-11-17" -> "17 Nov 2026"
export function date(iso) {
  const [y, m, d] = iso.split("-").map(Number);
  return `${d} ${["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]} ${y}`;
}

// the line to share: the day, the time, the place
export function shareText(day, you, count) {
  return `Switchback daily no. ${day}: ${clock(you.time)} to the summit, ` +
    `${ordinal(you.rank)} of ${thousands(count)} · ${location.origin}/`;
}

// the time to midnight UTC, ticking in el
function countdown(el) {
  const tick = () => {
    const now = new Date();
    const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
    const s = Math.max(0, Math.floor((next - now.getTime()) / 1000));
    const p = (n) => String(n).padStart(2, "0");
    el.innerHTML = `next valley in <b class="num">${p(Math.floor(s / 3600))}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}</b>`;
  };
  tick();
  setInterval(tick, 1000);
}

// the header's live parts: the countdown and the player's chip (its
// popover sets the name: kept here and sent to the server). onName(name)
// hears a change.
export function header(onName) {
  const top = document.querySelector(".top");
  countdown(top.querySelector(".countdown"));
  const who = top.querySelector(".who");
  who.innerHTML = `
    <button class="chip" aria-expanded="false" aria-haspopup="dialog">
      <span class="avatar"></span><span><span class="label">Driving as </span><span class="name"></span></span>
    </button>
    <div class="pop" role="dialog" aria-label="Your name" hidden>
      <h3>Your name on the board</h3>
      <p>Shown next to your time among the day's fastest. Leave it empty to stay anonymous; your runs count either way.</p>
      <div class="field"><input maxlength="${NAME_LENGTH}" placeholder="a name" spellcheck="false"><button class="btn">Save</button></div>
      <div class="error"></div>
      <button class="link">Stay anonymous</button>
    </div>`;
  const chip = who.querySelector(".chip");
  const pop = who.querySelector(".pop");
  const input = pop.querySelector("input");
  const error = pop.querySelector(".error");
  const show = () => {
    const n = name();
    who.querySelector(".avatar").textContent = n ? [...n][0].toUpperCase() : "?";
    who.querySelector(".name").textContent = n || "Anonymous";
  };
  const open = (yes) => {
    pop.hidden = !yes;
    chip.setAttribute("aria-expanded", String(yes));
    if (yes) {
      input.value = name();
      error.textContent = "";
      input.focus();
      input.select();
    }
  };
  const save = async (value) => {
    value = value.trim();
    try {
      const answer = await api("/api/name", { player: player(), name: value });
      if (!answer.ok) {
        error.textContent = "That name cannot be used (no more than 20 characters).";
        return;
      }
    } catch {
      error.textContent = "The server cannot be reached; try again later.";
      return;
    }
    store(NAME, value || null);
    show();
    open(false);
    if (onName) onName(value);
  };
  chip.addEventListener("click", () => open(pop.hidden));
  pop.querySelector(".btn").addEventListener("click", () => save(input.value));
  pop.querySelector(".link").addEventListener("click", () => save(""));
  // (keys typed into the name are the page's, not the game's)
  for (const type of ["keydown", "keyup", "keypress"]) {
    input.addEventListener(type, (e) => {
      e.stopPropagation();
      if (type === "keydown" && e.key === "Enter") save(input.value);
      if (type === "keydown" && e.key === "Escape") open(false);
    });
  }
  document.addEventListener("click", (e) => { if (!e.target.closest(".who")) open(false); });
  show();
}
