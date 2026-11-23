// The panes page: one stream for every terminal, columns that come and go,
// and the keys of ptyZZZ's panes. Everything inside a pane is <ghostty-term>.
//
// /sse sends a "tick" per terminal write, {pane, seq, total, rows, alive,
// code}. Each goes to its pane's element as a "ghostty-tick" event on
// document. A tick for a pane this page doesn't show, or a pane's last tick,
// means the layout moved: fetch /strip and lay it out again, keeping the
// panes already here, so their terminals aren't drawn from scratch.

const $ = (s) => document.querySelector(s);
const panes = () => [...document.querySelectorAll(".pane")];
let selected = null;
let mode = "navigate";

const select = (pid) => {
  selected = pid && document.getElementById(`pane-${pid}`) ? pid : panes()[0]?.dataset.pane ?? null;
  panes().forEach((p) => p.classList.toggle("selected", p.dataset.pane === selected));
};

const setMode = (m) => {
  mode = m;
  document.body.classList.toggle("focus", m === "focus");
  $("#bar .mode").textContent = m;
  const term = document.querySelector(`#pane-${selected} ghostty-term`);
  if (m === "focus") term?.park?.();
  else document.activeElement?.blur?.();
};

let refreshing = null;
const refreshStrip = () => refreshing ??= (async () => {
  try {
    const html = await (await fetch("/strip")).text();
    const t = document.createElement("template");
    t.innerHTML = html.trim();
    const next = t.content.firstElementChild;
    // Panes already on the page move into the new layout as they are.
    next.querySelectorAll(".pane").forEach((p) => {
      const old = document.getElementById(p.id);
      if (old) p.replaceWith(old);
    });
    $("#strip").replaceWith(next);
    select(selected);
  } finally { refreshing = null; }
})();

const es = new EventSource("/sse");
es.addEventListener("open", refreshStrip);
es.addEventListener("tick", (ev) => {
  const t = JSON.parse(ev.data);
  if (!document.getElementById(`pane-${t.pane}`)) return refreshStrip();
  document.dispatchEvent(new CustomEvent("ghostty-tick", { detail: t }));
  if (t.alive === false) refreshStrip();
});

const post = async (path) => (await fetch(path, { method: "POST" })).json();
const act = {
  n: async () => { const r = await post(`/pane/new-column?after=${selected ?? ""}`); await refreshStrip(); select(r.pane); },
  s: async () => { if (!selected) return; const r = await post(`/pane/split?pane=${selected}`); await refreshStrip(); select(r.pane); },
  x: async () => {
    if (!selected) return;
    const order = panes().map((p) => p.dataset.pane), i = order.indexOf(selected);
    await post(`/pane/close?pane=${selected}`);
    await refreshStrip();
    select(order[i + 1] ?? order[i - 1]);
  },
};

const move = (dc, dp) => {
  const cols = [...document.querySelectorAll(".column")].map((c) => [...c.querySelectorAll(".pane")].map((p) => p.dataset.pane));
  const ci = cols.findIndex((c) => c.includes(selected));
  if (ci < 0) return select(null);
  const pi = cols[ci].indexOf(selected);
  const nc = Math.max(0, Math.min(cols.length - 1, ci + dc));
  const np = dc ? Math.min(pi, cols[nc].length - 1) : Math.max(0, Math.min(cols[ci].length - 1, pi + dp));
  select(cols[nc][np]);
  document.getElementById(`pane-${selected}`)?.scrollIntoView({ block: "nearest", inline: "nearest" });
};

let leader = false;
document.addEventListener("keydown", (ev) => {
  const mod = ev.metaKey || ev.ctrlKey;
  const take = () => { ev.preventDefault(); ev.stopPropagation(); };
  if (mod && ev.key === "Enter") { take(); return setMode(mode === "focus" ? "navigate" : "focus"); }
  if (mod && ev.key.toLowerCase() === "k") { take(); leader = true; $("#panel").hidden = false; return; }
  if (leader) {
    take();
    leader = false; $("#panel").hidden = true;
    if (ev.key === "x") act.x();
    return;
  }
  if (mode === "focus" || mod || ev.altKey) return;
  const go = { h: () => move(-1, 0), l: () => move(1, 0), j: () => move(0, 1), k: () => move(0, -1), n: act.n, s: act.s, Enter: () => setMode("focus") }[ev.key];
  if (go) { take(); go(); }
}, true);

document.addEventListener("click", (ev) => {
  const p = ev.target.closest?.(".pane");
  if (p) { select(p.dataset.pane); if (mode !== "focus") setMode("focus"); }
});

select(null);
