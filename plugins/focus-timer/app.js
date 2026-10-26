// Focus timer: a Pomodoro-style countdown that notifies you when a session ends.
// The timer keeps the time it ends at, not a count of ticks: a page Frog keeps in the
// background has its timers slowed down, and the end time stays right regardless.

const $ = (id) => document.getElementById(id);
const errorBox = $("error");
const choices = [...document.querySelectorAll("[data-choice]")];

// endsAt is set while the timer runs; remaining is set while it is paused.
let timer = { choice: "25", custom: 15, endsAt: null, remaining: null };
let today = { day: dayKey(), count: 0 };
let startedByCommand = false;

function dayKey(date = new Date()) {
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

const minutes = () => (timer.choice === "custom" ? timer.custom : Number(timer.choice));
const running = () => timer.endsAt !== null;
const paused = () => timer.remaining !== null;
const timeLeft = () =>
  running() ? Math.max(0, timer.endsAt - Date.now()) : paused() ? timer.remaining : minutes() * 60_000;

function format(ms) {
  const total = Math.ceil(ms / 1000);
  const [h, m, s] = [Math.floor(total / 3600), Math.floor(total / 60) % 60, total % 60];
  const pad = (n) => String(n).padStart(2, "0");
  return h ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

const clock = (time) => new Date(time).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

function render() {
  const left = timeLeft();
  $("time").textContent = format(left);
  $("progress").style.width = `${(1 - left / (minutes() * 60_000)) * 100}%`;
  $("status").textContent = running() ? `Focusing until ${clock(timer.endsAt)}`
    : paused() ? "Paused" : `Ready for ${minutes()} minutes`;
  $("toggle").textContent = running() ? "Pause" : paused() ? "Resume" : "Start";
  $("reset").disabled = !running() && !paused();
  // During a session the other lengths are disabled; the chosen one stays readable.
  for (const button of choices) {
    const chosen = button.dataset.choice === timer.choice;
    button.setAttribute("aria-pressed", String(chosen));
    button.disabled = !chosen && (running() || paused());
  }
  $("custom-field").hidden = timer.choice !== "custom";
  $("custom").disabled = running() || paused();
  if (document.activeElement !== $("custom")) $("custom").value = timer.custom;
  $("today").textContent = today.day === dayKey() ? today.count : 0;
}

function showError(error) {
  errorBox.textContent = error?.message ?? String(error);
  errorBox.hidden = false;
}

// Every change is saved, so a page Frog reloads picks the session up where it was.
function save() {
  if (!window.frog) return;
  frog.storage.set("timer", timer).catch(showError);
}

// The end of a session is scheduled with macOS when it starts, so it shows on time even when
// Frog unloads the page or quits.
function scheduleEnd() {
  if (!window.frog) return;
  frog.notify("Focus session done", `${minutes()} minutes of focus. Time for a short break.`, { at: timer.endsAt, id: "done" })
    .catch(showError);
}

function cancelEnd() {
  if (window.frog) frog.cancelNotification("done").catch(showError);
}

function start() {
  if (running()) return;
  timer.endsAt = Date.now() + (timer.remaining ?? minutes() * 60_000);
  timer.remaining = null;
  save();
  scheduleEnd();
  render();
}

function pause() {
  if (!running()) return;
  timer.remaining = Math.max(0, timer.endsAt - Date.now());
  timer.endsAt = null;
  save();
  cancelEnd();
  render();
}

function clear() {
  timer.endsAt = null;
  timer.remaining = null;
  save();
  render();
}

function reset() {
  clear();
  cancelEnd();
}

async function finish() {
  // The notification was scheduled when the session started, so it is not cancelled here.
  clear();
  if (today.day !== dayKey()) today = { day: dayKey(), count: 0 };
  today.count += 1;
  render();
  if (!window.frog) return;
  try {
    await frog.storage.set("today", today);
  } catch (error) {
    showError(error);
  }
  // A session started from the command bar ran without the page; Frog unloads it unless it is shown.
  if (startedByCommand) frog.close();
  startedByCommand = false;
}

function tick() {
  if (running() && Date.now() >= timer.endsAt) finish();
  else render();
}

$("toggle").addEventListener("click", () => (running() ? pause() : start()));
$("reset").addEventListener("click", reset);
for (const button of choices) {
  button.addEventListener("click", () => { timer.choice = button.dataset.choice; save(); render(); });
}
$("custom").addEventListener("change", () => {
  const value = Math.round(Number($("custom").value));
  timer.custom = Math.min(240, Math.max(1, Number.isFinite(value) ? value : 15));
  save();
  render();
});
document.addEventListener("keydown", (event) => {
  if (event.key === " " && event.target === document.body) {
    event.preventDefault();
    $("toggle").click();
  }
});

async function onCommand(id) {
  errorBox.hidden = true;
  try {
    if (id === "start") {
      const already = running();
      startedByCommand = startedByCommand || !already;
      start();
      await frog.notify(already ? "Focus session already running" : "Focus session started",
        `Focus until ${clock(timer.endsAt)}.`);
    } else if (id === "stop") {
      const wasActive = running() || paused();
      reset();
      startedByCommand = false;
      await frog.notify("Focus timer", wasActive ? "Stopped the focus session." : "No focus session was running.");
      frog.close();
    }
  } catch (error) {
    showError(error);
  }
}

async function restore() {
  try {
    const [savedTimer, savedToday] = await Promise.all([frog.storage.get("timer"), frog.storage.get("today")]);
    if (savedTimer) timer = { ...timer, ...savedTimer };
    if (savedToday?.day === dayKey()) today = savedToday;
  } catch (error) {
    showError(error);
  }
  tick();
}

if (window.frog) {
  // Listen for commands as soon as the script runs, so the command that loaded the page is
  // not missed, and handle each one once the saved session length and state are back.
  const restored = restore();
  frog.on("command", (id) => restored.then(() => onCommand(id)));
  frog.on("show", tick);
} else {
  $("outside").hidden = false;
}

render();
setInterval(tick, 500);
document.addEventListener("visibilitychange", tick);
