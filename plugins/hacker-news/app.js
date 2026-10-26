// Hacker News: the top 20 stories from the public Hacker News API.
// Everything that comes from the network is untrusted: text is only ever set with
// textContent, never innerHTML, and only http and https links are opened.

const API = "https://hacker-news.firebaseio.com/v0";
const COUNT = 20;
const CONCURRENCY = 6;
const STALE_AFTER = 5 * 60_000;

const $ = (id) => document.getElementById(id);
const list = $("stories");
const errorBox = $("error");
let fetchedAt = 0;
let loading = false;

// frog.fetch goes through Frog, which only lets it reach the hosts in plugin.json.
async function getJSON(path) {
  const response = await frog.fetch(`${API}/${path}`, { as: "json" });
  if (response.status !== 200) throw new Error(`Hacker News answered with status ${response.status}.`);
  return response.body;
}

// Runs fn over every item with at most `limit` calls in flight, and keeps the order.
async function mapLimit(items, limit, fn) {
  const results = [];
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index]);
    }
  };
  await Promise.all(Array.from({ length: limit }, worker));
  return results;
}

async function loadStories() {
  const ids = await getJSON("topstories.json");
  if (!Array.isArray(ids)) throw new Error("Hacker News sent an answer this plugin does not understand.");
  let failure = null;
  const items = await mapLimit(ids.filter(Number.isInteger).slice(0, COUNT), CONCURRENCY, (id) =>
    getJSON(`item/${id}.json`).catch((error) => { failure = error; return null; }));
  const stories = items.filter((item) => item && !item.deleted && !item.dead && item.title).map((item) => ({
    id: Number(item.id),
    title: String(item.title),
    url: typeof item.url === "string" ? item.url : "",
    type: String(item.type),
    score: Number(item.score) || 0,
    comments: Number(item.descendants) || 0,
    time: Number(item.time) || 0,
  }));
  if (stories.length === 0 && failure) throw failure;
  return stories;
}

const discussionURL = (story) => `https://news.ycombinator.com/item?id=${Number(story.id)}`;

// The story's own link when it is http or https. Without one, its row opens the discussion.
function storyURL(story) {
  try {
    const url = new URL(story.url);
    if (url.protocol === "https:" || url.protocol === "http:") return url;
  } catch {}
  return null;
}

const relative = new Intl.RelativeTimeFormat(undefined, { style: "short" });
function age(seconds) {
  const minutes = Math.max(1, (Date.now() / 1000 - seconds) / 60);
  if (minutes < 60) return relative.format(-Math.round(minutes), "minute");
  if (minutes < 60 * 24) return relative.format(-Math.round(minutes / 60), "hour");
  return relative.format(-Math.round(minutes / (60 * 24)), "day");
}

const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`;

function element(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function row(story, rank) {
  const url = storyURL(story);
  const meta = [url ? url.hostname.replace(/^www\./, "") : "news.ycombinator.com"];
  if (story.type !== "job") meta.push(plural(story.score, "point"));
  meta.push(age(story.time));

  const open = element("button", "frog-item");
  const body = element("span", "");
  body.append(element("span", "title", story.title), element("span", "meta", meta.join(" · ")));
  open.append(element("span", "rank", String(rank)), body);
  open.addEventListener("click", () => openLink(url ? url.href : discussionURL(story)));

  const item = element("li", "story");
  item.append(open);
  if (story.type !== "job") {
    const comments = element("button", "frog-quiet comments", plural(story.comments, "comment"));
    comments.title = "Open the discussion";
    comments.addEventListener("click", () => openLink(discussionURL(story)));
    item.append(comments);
  }
  return item;
}

function render(stories) {
  list.replaceChildren(...stories.map((story, index) => row(story, index + 1)));
  const time = new Date(fetchedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  $("updated").textContent = `Top stories, updated at ${time}`;
}

function showError(message) {
  errorBox.textContent = message;
  errorBox.hidden = false;
}

async function openLink(url) {
  errorBox.hidden = true;
  try {
    await frog.openURL(url);
  } catch (error) {
    showError(`Could not open the link. ${error?.message ?? error}`);
  }
}

async function refresh() {
  if (loading) return;
  loading = true;
  errorBox.hidden = true;
  $("refresh").disabled = true;
  $("spinner").hidden = false;
  $("loading").hidden = list.children.length > 0;
  try {
    const stories = await loadStories();
    fetchedAt = Date.now();
    render(stories);
    await frog.storage.set("cache", { fetchedAt, stories });
  } catch (error) {
    showError(`Could not load the stories. ${error?.message ?? error}`);
  } finally {
    loading = false;
    $("refresh").disabled = false;
    $("spinner").hidden = true;
    $("loading").hidden = true;
  }
}

const refreshIfStale = () => { if (Date.now() - fetchedAt > STALE_AFTER) refresh(); };

if (window.frog) {
  $("refresh").addEventListener("click", refresh);
  frog.on("show", refreshIfStale);
  // Show the last list at once, then fetch a new one if it is more than a few minutes old.
  frog.storage.get("cache")
    .then((cache) => {
      if (!fetchedAt && Array.isArray(cache?.stories) && cache.stories.length) {
        fetchedAt = Number(cache.fetchedAt) || 0;
        render(cache.stories);
      }
    })
    .catch((error) => showError(`Could not read the saved stories. ${error?.message ?? error}`))
    .finally(refreshIfStale);
} else {
  $("outside").hidden = false;
  $("refresh").disabled = true;
}
