// The focus timer's state, shared by its page and its popup. Both keep it in frog.storage and
// hear "storage" when the other one changes it. The timer keeps the time it ends at, not a count
// of ticks, so it stays right however often the page runs.

const defaults = { length: 25, break: 5, "menubar-time": true };
let settings = { ...defaults };
// mode is "focus" or "break"; endsAt is set while it runs, remaining while it is paused.
let timer = { mode: "focus", minutes: defaults.length, endsAt: null, remaining: null };
let today = { day: dayKey(), count: 0 };

function dayKey(date = new Date()) {
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

const running = () => timer.endsAt !== null;
const paused = () => timer.remaining !== null;
const idle = () => !running() && !paused();
const minutes = () => (idle() ? settings.length : timer.minutes);
const timeLeft = () =>
  running() ? Math.max(0, timer.endsAt - Date.now()) : paused() ? timer.remaining : settings.length * 60_000;
const finishedToday = () => (today.day === dayKey() ? today.count : 0);

function format(ms) {
  const total = Math.ceil(ms / 1000);
  const [h, m, s] = [Math.floor(total / 3600), Math.floor(total / 60) % 60, total % 60];
  const pad = (n) => String(n).padStart(2, "0");
  return h ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

const clock = (time) => new Date(time).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

function status() {
  const what = timer.mode === "break" ? "Break" : "Focusing";
  if (running()) return `${what} until ${clock(timer.endsAt)}`;
  if (paused()) return `${what} paused`;
  return `Ready for ${settings.length} minutes`;
}

async function load() {
  const [savedTimer, savedToday, savedSettings] = await Promise.all([
    frog.storage.get("timer"), frog.storage.get("today"), frog.settings.all(),
  ]);
  timer = { ...timer, ...savedTimer };
  if (savedToday) today = savedToday;
  settings = { ...defaults, ...savedSettings };
}

const save = () => frog.storage.set("timer", timer);

// The end is scheduled with macOS when the timer starts, so it shows on time whatever Frog does.
// Its buttons come back to the page as a "notification" event.
function scheduleEnd() {
  const [title, body, actions] = timer.mode === "focus"
    ? ["Focus session done", `${timer.minutes} minutes of focus.`,
       [{ id: "break", title: `Take a ${settings.break}-minute break` }, { id: "focus", title: "Focus again" }]]
    : ["Break is over", "Ready for the next session?", [{ id: "focus", title: "Start focusing" }]];
  return frog.notify(title, body, { at: timer.endsAt, id: "end", actions });
}

async function start(mode) {
  if (running()) return;
  if (idle() || (mode && mode !== timer.mode)) {
    timer.mode = mode ?? "focus";
    timer.minutes = timer.mode === "break" ? settings.break : settings.length;
    timer.remaining = null;
  }
  timer.endsAt = Date.now() + (timer.remaining ?? timer.minutes * 60_000);
  timer.remaining = null;
  await save();
  await scheduleEnd();
}

async function pause() {
  if (!running()) return;
  timer.remaining = Math.max(0, timer.endsAt - Date.now());
  timer.endsAt = null;
  await save();
  await frog.cancelNotification("end");
}

async function reset() {
  timer = { ...timer, mode: "focus", endsAt: null, remaining: null };
  await save();
  await frog.cancelNotification("end");
}

const toggle = () => (running() ? pause() : start());
