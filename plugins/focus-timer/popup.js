// The focus timer's popup beneath its menu-bar item: the time left and the buttons. The page,
// which runs in the background, ends sessions and counts them; the popup hears its changes.

const $ = (id) => document.getElementById(id);
const errorBox = $("error");

function render() {
  const left = timeLeft();
  $("time").textContent = format(left);
  $("progress").style.setProperty("--value", String(1 - left / (minutes() * 60_000)));
  // The clock already says how long the next session is, so the idle line just says it is ready.
  $("mode").textContent = timer.mode === "break" && !idle() ? "Break" : "Focus";
  $("status").textContent = running() || paused() ? status() : "Ready";
  $("toggle").textContent = running() ? "Pause" : paused() ? "Resume" : "Start";
  $("reset").hidden = idle();
  const count = finishedToday();
  $("today").textContent = count === 1 ? "1 today" : `${count} today`;
}

const attempt = (work) => async () => {
  errorBox.hidden = true;
  try { await work(); } catch (error) { errorBox.textContent = error?.message ?? String(error); errorBox.hidden = false; }
  render();
};

$("toggle").addEventListener("click", attempt(toggle));
$("reset").addEventListener("click", attempt(reset));

if (window.frog) {
  const reload = attempt(load);
  reload();
  frog.on("storage", reload);
  frog.on("settings", reload);
  frog.on("show", reload);
}

render();
setInterval(render, 1000);
