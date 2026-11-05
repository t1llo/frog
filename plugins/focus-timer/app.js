// The focus timer's page. It runs in the background from Frog's start, so it ends sessions on time,
// counts the finished ones, keeps the menu-bar item's time current and answers the shortcut, the
// command bar and the notification's buttons. The timer's state is in timer.js.

const $ = (id) => document.getElementById(id);
const errorBox = $("error");
const choices = [...document.querySelectorAll("[data-choice]")];
const presets = choices.map((button) => button.dataset.choice).filter((choice) => choice !== "custom");
let customChosen = false;
let shownInMenuBar = "";

function render() {
  const left = timeLeft();
  $("time").textContent = format(left);
  $("progress").style.setProperty("--value", String(1 - left / (minutes() * 60_000)));
  $("status").textContent = status();
  $("toggle").textContent = running() ? "Pause" : paused() ? "Resume" : "Start";
  $("reset").disabled = idle();
  // During a session the other lengths are disabled; the chosen one stays readable.
  const chosen = customChosen || !presets.includes(String(settings.length)) ? "custom" : String(settings.length);
  for (const button of choices) {
    button.setAttribute("aria-pressed", String(button.dataset.choice === chosen));
    button.disabled = button.dataset.choice !== chosen && !idle();
  }
  $("custom-field").hidden = chosen !== "custom";
  $("custom").disabled = !idle();
  if (document.activeElement !== $("custom")) $("custom").value = settings.length;
  $("today").textContent = finishedToday();
  updateMenuBar();
}

// The time beside the menu-bar icon, sent only when it changes.
function updateMenuBar() {
  if (!window.frog) return;
  const title = settings["menubar-time"] && !idle() ? format(timeLeft()) : "";
  const symbol = paused() ? "pause.circle" : running() && timer.mode === "break" ? "cup.and.saucer" : "timer";
  const shown = `${symbol} ${title}`;
  if (shown === shownInMenuBar) return;
  shownInMenuBar = shown;
  frog.menubar.set({ title, symbol, tooltip: `Focus timer: ${status()}` }).catch(showError);
}

function showError(error) {
  errorBox.textContent = error?.message ?? String(error);
  errorBox.hidden = false;
}

const attempt = (work) => async (...args) => {
  errorBox.hidden = true;
  try { await work(...args); } catch (error) { showError(error); }
  render();
};

async function finish() {
  const finishedFocus = timer.mode === "focus";
  timer = { ...timer, mode: "focus", endsAt: null, remaining: null };
  await save();
  if (finishedFocus) {
    if (today.day !== dayKey()) today = { day: dayKey(), count: 0 };
    today.count += 1;
    await frog.storage.set("today", today);
  }
}

// Only the page ends a session, so a finished one is counted once.
async function tick() {
  if (running() && Date.now() >= timer.endsAt) await attempt(finish)();
  else render();
}

const setLength = attempt((value) => frog.settings.set("length", value));

$("toggle").addEventListener("click", attempt(toggle));
$("reset").addEventListener("click", attempt(reset));
for (const button of choices) {
  button.addEventListener("click", () => {
    customChosen = button.dataset.choice === "custom";
    if (customChosen) render();
    else setLength(Number(button.dataset.choice));
  });
}
$("custom").addEventListener("change", () => {
  const value = Math.round(Number($("custom").value));
  setLength(Math.min(240, Math.max(1, Number.isFinite(value) ? value : 15)));
});
document.addEventListener("keydown", (event) => {
  if (event.key === " " && event.target === document.body) {
    event.preventDefault();
    $("toggle").click();
  }
});

if (window.frog) {
  // Actions and events are registered at once, so the one that loaded the page is not missed,
  // and each waits until the saved state is back.
  const loaded = load().catch(showError).then(tick);
  const after = (work) => async (...args) => { await loaded; await tick(); const result = await work(...args); render(); return result; };

  frog.action("toggle", after(async () => {
    await toggle();
    return running() ? status() : "Paused the focus timer.";
  }));
  frog.action("start", after(async () => {
    const already = running();
    await start("focus");
    return already ? `Already running: ${status()}.` : `${status()}.`;
  }));
  frog.action("stop", after(async () => {
    const wasActive = !idle();
    await reset();
    return wasActive ? "Stopped the focus timer." : "No focus session was running.";
  }));

  // A button on the notification that ended a session or a break.
  frog.on("notification", after(async ({ id, action }) => {
    if (id !== "end") return;
    if (action === "break") await start("break");
    if (action === "focus") await start("focus");
  }));
  frog.on("storage", after(async ({ key }) => {
    if (key === "timer") timer = { ...timer, ...(await frog.storage.get("timer")) };
    if (key === "today") today = (await frog.storage.get("today")) ?? today;
  }));
  frog.on("settings", after(async ({ key, value }) => {
    if (key in defaults) settings[key] = value ?? defaults[key];
    if (key === "length") customChosen = false;
  }));
  // A session that ended while the Mac slept is finished as soon as it wakes.
  frog.on("wake", tick);
  frog.on("show", tick);
} else {
  $("outside").hidden = false;
}

render();
setInterval(tick, 1000);
document.addEventListener("visibilitychange", tick);
