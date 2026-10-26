// Word counter: counts the text in the box as you type, and keeps it for next time.
// Counting needs no permission; reading the clipboard needs "clipboard-read".

const $ = (id) => document.getElementById(id);
const text = $("text");
const errorBox = $("error");

const WORDS_PER_MINUTE = 230;
const wordSegmenter = new Intl.Segmenter(undefined, { granularity: "word" });
const sentenceSegmenter = new Intl.Segmenter(undefined, { granularity: "sentence" });
const characterSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const number = new Intl.NumberFormat();

// Intl.Segmenter also splits languages without spaces, such as Japanese, into words.
function count(value) {
  const segments = (segmenter, keep) => [...segmenter.segment(value)].filter(keep).length;
  return {
    words: segments(wordSegmenter, (part) => part.isWordLike),
    characters: segments(characterSegmenter, () => true),
    sentences: segments(sentenceSegmenter, (part) => /[\p{L}\p{N}]/u.test(part.segment)),
    paragraphs: value.split(/\n+/).filter((line) => line.trim()).length,
  };
}

function readingTime(words) {
  if (words === 0) return "0 min";
  const minutes = Math.round(words / WORDS_PER_MINUTE);
  if (minutes < 1) return "< 1 min";
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

function render() {
  const totals = count(text.value);
  for (const key of ["words", "characters", "sentences", "paragraphs"]) {
    $(key).textContent = number.format(totals[key]);
  }
  $("reading").textContent = readingTime(totals.words);
}

function showError(error) {
  errorBox.textContent = error?.message ?? String(error);
  errorBox.hidden = false;
}

// Save shortly after the last keystroke rather than on every one.
let saveTimer;
function saveSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => frog.storage.set("text", text.value).catch(showError), 400);
}

function setText(value) {
  text.value = value;
  render();
  if (window.frog) saveSoon();
}

async function useClipboard() {
  errorBox.hidden = true;
  try {
    const clipboard = await frog.clipboard.readText();
    if (!clipboard) throw new Error("The clipboard has no text to count.");
    setText(clipboard);
  } catch (error) {
    showError(error);
  }
}

text.addEventListener("input", () => setText(text.value));
$("clear").addEventListener("click", () => { setText(""); text.focus(); });
$("paste").addEventListener("click", useClipboard);

if (window.frog) {
  // Register for commands first, so a command that opened the page is not missed.
  frog.on("command", (id) => { if (id === "count") useClipboard(); });
  frog.storage.get("text")
    .then((saved) => { if (typeof saved === "string" && !text.value) { text.value = saved; render(); } })
    .catch(showError);
} else {
  $("outside").hidden = false;
  $("paste").disabled = true;
}
render();
