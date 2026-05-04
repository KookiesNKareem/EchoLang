// LocalLearning student PWA — vanilla JS, no framework, no build step.

const LANGS = [
  { code: "ar", native: "العربية", english: "Arabic", rtl: true },
  { code: "uk", native: "Українська", english: "Ukrainian" },
  { code: "es", native: "Español", english: "Spanish" },
  { code: "zh", native: "中文", english: "Mandarin" },
  { code: "fr", native: "Français", english: "French" },
  { code: "ps", native: "پښتو", english: "Pashto", rtl: true },
  { code: "fa", native: "فارسی", english: "Farsi", rtl: true },
  { code: "en", native: "English", english: "(original)" },
];

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const state = {
  studentId: localStorage.getItem("ll.studentId") || crypto.randomUUID(),
  lang: localStorage.getItem("ll.lang") || null,
  classId: new URLSearchParams(location.search).get("class"),
  classMeta: null,
  source: null, // EventSource
};
localStorage.setItem("ll.studentId", state.studentId);

// ---- helpers ----------------------------------------------------------------

function setStatus(text, kind = "idle") {
  const el = $("#status");
  el.textContent = text;
  el.className = `status ${kind}`;
}

function show(screenId) {
  $$(".screen").forEach((s) => s.classList.toggle("hidden", s.id !== screenId));
}

function fmtTime(iso) {
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

// ---- language picker --------------------------------------------------------

function renderLangGrid() {
  const grid = $("#lang-grid");
  grid.innerHTML = "";
  LANGS.forEach((l) => {
    const tile = document.createElement("button");
    tile.className = "lang-tile" + (state.lang === l.code ? " selected" : "");
    tile.dataset.code = l.code;
    tile.innerHTML = `<span class="native" ${l.rtl ? 'dir="rtl"' : ""}>${l.native}</span>
                      <span class="english">${l.english}</span>`;
    tile.addEventListener("click", () => pickLang(l.code));
    grid.appendChild(tile);
  });
  $("#join-btn").disabled = !state.lang;
}

function pickLang(code) {
  state.lang = code;
  localStorage.setItem("ll.lang", code);
  renderLangGrid();
}

$("#join-btn").addEventListener("click", () => {
  if (!state.lang) return;
  startStream();
});

// ---- live captions ----------------------------------------------------------

function startStream() {
  show("screen-live");
  const lang = LANGS.find((l) => l.code === state.lang);
  $("#class-meta").innerHTML = state.classMeta
    ? `<strong>${escapeHtml(state.classMeta.title)}</strong> · <span ${lang.rtl ? 'dir="rtl"' : ""}>${lang.native}</span>`
    : `Live · <span ${lang.rtl ? 'dir="rtl"' : ""}>${lang.native}</span>`;

  if (state.source) state.source.close();
  const url = `/api/stream/${encodeURIComponent(state.classId)}/${encodeURIComponent(state.lang)}`;
  const es = new EventSource(url);
  state.source = es;

  setStatus("Live", "live");

  es.addEventListener("caption", (ev) => {
    const data = JSON.parse(ev.data);
    appendCaption(data);
  });
  es.addEventListener("ping", () => {});
  es.addEventListener("error", () => {
    setStatus("Reconnecting…", "error");
  });
  es.addEventListener("open", () => {
    setStatus("Live", "live");
  });
}

function appendCaption(data) {
  $("#empty-state").classList.add("hidden");
  const list = $("#captions");
  const li = document.createElement("li");
  li.className = "cap";
  li.dataset.index = data.caption_index ?? data.index;
  const lang = LANGS.find((l) => l.code === state.lang);
  if (lang?.rtl) li.setAttribute("dir", "rtl");

  const when = document.createElement("span");
  when.className = "when";
  // English captions carry started_at; translations don't include it — we still want a stamp
  when.textContent = data.started_at ? fmtTime(data.started_at) : "";

  const text = document.createElement("span");
  text.className = "text";
  text.textContent = data.text;

  const pill = document.createElement("span");
  pill.className = "mark-pill";
  pill.textContent = "marked";

  li.appendChild(when);
  li.appendChild(text);
  li.appendChild(pill);
  li.addEventListener("click", () => toggleConfusion(li));
  list.appendChild(li);

  // autoscroll if user is near the bottom
  const nearBottom = window.innerHeight + window.scrollY > document.body.offsetHeight - 200;
  if (nearBottom) li.scrollIntoView({ behavior: "smooth", block: "end" });
}

async function toggleConfusion(li) {
  const wasMarked = li.classList.toggle("confused");
  if (!wasMarked) return; // unmark is local-only for now
  const idx = parseInt(li.dataset.index, 10);
  try {
    await fetch(`/api/class/${encodeURIComponent(state.classId)}/confusion`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ student_id: state.studentId, caption_index: idx }),
    });
  } catch (e) {
    console.warn("confusion mark failed; keeping local", e);
  }
}

// ---- teacher console (no-class screen) --------------------------------------

async function startClassFromTeacher() {
  const title = $("#t-title").value.trim() || "Untitled lecture";
  const teacher = $("#t-name").value.trim() || null;
  $("#t-result").textContent = "Starting…";
  try {
    const r = await fetch("/api/class", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title, teacher }),
    });
    if (!r.ok) throw new Error(await r.text());
    const session = await r.json();
    const url = `${location.origin}/join?class=${session.id}`;
    $("#t-result").innerHTML = `Class started. Students join at <span class="url">${url}</span>`;
    const qr = $("#t-qr");
    qr.innerHTML = `<img alt="QR code" src="/api/qr/${session.id}" />
                    <div class="url">${url}</div>`;
  } catch (e) {
    $("#t-result").textContent = "Couldn't start class: " + e.message;
  }
}

$("#t-start").addEventListener("click", startClassFromTeacher);

// ---- bootstrap --------------------------------------------------------------

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function bootstrap() {
  // No class id in URL → check active or show no-class screen
  if (!state.classId) {
    try {
      const r = await fetch("/api/class/active");
      if (r.status === 204) {
        show("screen-noclass");
        setStatus("No class", "idle");
        return;
      }
      const session = await r.json();
      state.classId = session.id;
      state.classMeta = session;
    } catch (e) {
      show("screen-noclass");
      setStatus("Offline", "error");
      return;
    }
  } else {
    try {
      const r = await fetch(`/api/class/${state.classId}`);
      if (r.ok) state.classMeta = (await r.json()).session;
    } catch {}
  }

  if (state.lang && state.classId) {
    // skip language picker for returning students
    renderLangGrid();
    startStream();
  } else {
    renderLangGrid();
    show("screen-lang");
    setStatus("Pick a language", "idle");
  }
}

bootstrap();
