// <ghostty-term src="/term">: one nu_plugin_ghostty terminal in the browser.
//
// Modelled on ptyZZZ's <pty-term>, with one difference: the page never holds
// the scrollback. It holds the rows in view plus a screenful either side, and
// asks for the rows at its scroll position, the way largediff-go-brr asks for
// a window of a diff. The terminal and its history live in the plugin.
//
//   <ghostty-term src="/term"></ghostty-term>
//
// The server under `src` answers:
//   GET  {src}/live            SSE, event "tick": {seq, total, rows} each time
//                              the program writes
//   GET  {src}/win?top&h&fp    the rows top..top+h as {fp, top, total, rows,
//                              cols, cursor, html}, or {unchanged: true}
//   POST {src}/input           NDJSON frames: {t:"key", code, key, mods},
//                              {t:"text", s}, {t:"paste", s},
//                              {t:"resize", cols, rows}
//
// Only the last `rows` rows of a terminal (its active area) can change. Rows
// above it are history and stay as they were. So a tick only costs a request
// when the page shows some of the active area, or follows the output; scrolled
// back into history, a tick just lengthens the scrollbar.
//
// Props:
//   src    the server path above
//   nofit  observe without resizing the terminal
//
// Host API:
//   park()    put focus on this terminal, so typed keys go to it
//   follow()  scroll to the live output and stay there
//   The host carries the class `unstuck` while the user has scrolled away.
//
// The page brings Datastar with Rocket and names it in an import map:
//   <script type=importmap>{"imports": {"datastar": "/datastar-rocket@1.0.4.js"}}</script>

import { rocket } from "datastar";

const NAMED = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End",
  "PageUp", "PageDown", "Insert", "Delete", "Enter", "Tab", "Backspace", "Escape"];

// A key as the plugin takes it: the physical key (KeyboardEvent.code), the
// character it made, and the modifiers (1 shift, 2 alt, 4 ctrl, 8 meta). The
// plugin encodes it against the program's live input modes.
function keyFrame(ev) {
  if (["Shift", "Control", "Alt", "Meta", "CapsLock"].includes(ev.key)) return null;
  const mods = (ev.shiftKey ? 1 : 0) | (ev.altKey ? 2 : 0) | (ev.ctrlKey ? 4 : 0) | (ev.metaKey ? 8 : 0);
  if (ev.key.length === 1) {
    // Cmd+char belongs to the browser (copy, reload, ...).
    if (ev.metaKey) return null;
    // Option as compose (non-US layouts) gives a finished glyph: send the
    // glyph, without the alt bit.
    if (ev.altKey && !ev.ctrlKey) {
      const letter = /^Key([A-Z])$/.exec(ev.code)?.[1]?.toLowerCase();
      if (!(letter && ev.key.toLowerCase() === letter)) return { t: "text", s: ev.key };
    }
    return { t: "key", code: ev.code, key: ev.key, mods };
  }
  if (NAMED.includes(ev.key) || /^F\d+$/.test(ev.key)) return { t: "key", code: ev.code || ev.key, key: "", mods };
  return null;
}

rocket("ghostty-term", {
  mode: "light",
  props: ({ string, bool }) => ({
    src: string.trim,
    nofit: bool,
  }),
  setup: ({ host, props, cleanup, defineHostProp }) => {
    const src = props.src.replace(/\/$/, "");
    const nofit = props.nofit || new URLSearchParams(location.search).has("nofit");

    host.innerHTML = `<div class="scroll"><div class="spacer"></div><div class="win"></div><div class="cursor" hidden></div></div>
      <textarea class="compose" aria-hidden="true" tabindex="-1" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>`;
    const box = host.querySelector(".scroll");
    const spacer = host.querySelector(".spacer");
    const win = host.querySelector(".win");
    const cursorEl = host.querySelector(".cursor");
    const ta = host.querySelector(".compose");

    // ---- cell size: one row of the terminal font, measured once
    let cell = null;
    const measure = () => {
      const probe = document.createElement("div");
      probe.textContent = "M".repeat(80);
      probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre";
      win.appendChild(probe);
      const r = probe.getBoundingClientRect();
      probe.remove();
      cell = r.width && r.height ? { w: r.width / 80, h: r.height } : null;
      return cell;
    };

    // ---- what the page holds
    const st = {
      total: 0, rows: 0, cols: 0,   // the terminal: rows kept, and its size
      top: -1, h: 0, fp: "",        // the window this page holds
      cursor: null,
      stick: true,                  // following the live output
      busy: false, again: false,
    };

    const rowH = () => cell?.h || 18;
    const viewRows = () => Math.max(1, Math.ceil(box.clientHeight / rowH()));
    const activeTop = () => Math.max(0, st.total - st.rows);

    // The rows the page wants: those in view plus a screenful either side.
    const wanted = () => {
      const first = Math.floor(box.scrollTop / rowH());
      const n = viewRows();
      return { top: Math.max(0, first - n), h: n * 3 };
    };
    const covers = (w) => st.top >= 0 && w.top >= st.top && w.top + w.h <= st.top + st.h + 1;
    const showsActive = () => st.top >= 0 && st.top + st.h > activeTop();

    const setTotal = (total, rows) => {
      st.total = total;
      if (rows) st.rows = rows;
      spacer.style.height = total * rowH() + "px";
    };

    // ---- following the output
    let lastWrote = -1;
    const setStick = (on) => { st.stick = on; host.classList.toggle("unstuck", !on); };
    const toBottom = () => {
      const max = Math.max(0, box.scrollHeight - box.clientHeight);
      if (box.scrollTop !== max) box.scrollTop = max;
      lastWrote = box.scrollTop;
    };
    defineHostProp("follow", { value: () => { setStick(true); toBottom(); fetchWindow(true); } });

    // ---- asking for rows: one request in flight; a newer need waits for it
    const fetchWindow = async (force) => {
      if (st.busy) { st.again = true; return; }
      const w = wanted();
      if (!force && covers(w) && !showsActive() && !st.stick) return;
      st.busy = true;
      try {
        const same = w.top === st.top && w.h === st.h;
        const q = `top=${w.top}&h=${w.h}` + (same && st.fp ? `&fp=${st.fp}` : "");
        const res = await fetch(`${src}/win?${q}`);
        const r = await res.json();
        if (!r.unchanged) {
          win.innerHTML = r.html;
          win.style.top = r.top * rowH() + "px";
          st.top = r.top; st.h = w.h; st.fp = r.fp;
          st.cols = r.cols;
          setTotal(r.total, r.rows);
          st.cursor = r.cursor;
          drawCursor();
        }
        if (st.stick) toBottom();
      } catch {}
      st.busy = false;
      if (st.again) { st.again = false; fetchWindow(true); }
    };

    const drawCursor = () => {
      const c = st.cursor;
      const show = c && c.visible && host.contains(document.activeElement);
      cursorEl.hidden = !show;
      if (!show) return;
      cursorEl.style.top = c.y * rowH() + "px";
      cursorEl.style.left = c.x * (cell?.w || 8) + "px";
      cursorEl.style.width = (cell?.w || 8) + "px";
      cursorEl.style.height = rowH() + "px";
    };
    host.addEventListener("focusin", drawCursor);
    host.addEventListener("focusout", () => setTimeout(drawCursor));

    box.addEventListener("scroll", () => {
      if (box.scrollTop !== lastWrote) setStick(box.scrollTop >= box.scrollHeight - box.clientHeight - rowH());
      if (!covers(wanted())) fetchWindow(true);
    }, { passive: true });

    // ---- the live stream: a tick per write
    const live = new EventSource(`${src}/live`);
    live.addEventListener("tick", (ev) => {
      const t = JSON.parse(ev.data);
      setTotal(t.total, t.rows);
      // Scrolled back into history, nothing in view can have changed.
      if (st.stick || showsActive()) fetchWindow(false);
    });
    cleanup(() => live.close());

    // ---- input: an awaited queue, so frames reach the terminal in order
    const queue = [];
    let sending = false;
    const send = (frame) => { queue.push(JSON.stringify(frame)); drain(); };
    const drain = async () => {
      if (sending) return;
      sending = true;
      while (queue.length) {
        const batch = queue.splice(0).join("\n") + "\n";
        try { await fetch(`${src}/input`, { method: "POST", body: batch }); } catch {}
      }
      sending = false;
    };

    const park = () => requestAnimationFrame(() => {
      const sel = getSelection();
      if (sel && !sel.isCollapsed) return;
      try { ta.focus({ preventScroll: true }); } catch {}
    });
    defineHostProp("park", { value: park });
    host.addEventListener("click", () => {
      const sel = getSelection();
      if (sel && !sel.isCollapsed) return;
      ta.focus({ preventScroll: true });
    });

    let composing = false;
    ta.addEventListener("compositionstart", () => { composing = true; });
    ta.addEventListener("compositionend", (ev) => {
      composing = false;
      const data = ev.data || ta.value;
      ta.value = "";
      if (data) send({ t: "text", s: data });
    });
    host.addEventListener("keydown", (ev) => {
      if (ev.isComposing || ev.keyCode === 229 || composing) return;
      if (ev.ctrlKey && !ev.altKey && !ev.metaKey && ev.key === "c") {
        const sel = getSelection().toString();
        if (sel) { navigator.clipboard.writeText(sel).catch(() => {}); ev.preventDefault(); return; }
      }
      const frame = keyFrame(ev);
      if (!frame) return;
      if (document.activeElement !== ta) ta.focus({ preventScroll: true });
      ev.preventDefault();
      ta.value = "";
      // Typing goes to the live output: follow it again.
      if (!st.stick) { setStick(true); toBottom(); }
      send(frame);
    });
    host.addEventListener("paste", (ev) => {
      const text = ev.clipboardData?.getData("text");
      if (!text) return;
      ev.preventDefault();
      send({ t: "paste", s: text });
    });

    // ---- fit the terminal to the box: whole columns and rows
    let lastFit = null;
    const fit = () => {
      if (!host.clientWidth || !host.clientHeight || !measure()) return;
      const cols = Math.max(20, Math.floor(box.clientWidth / cell.w));
      const rows = Math.max(5, Math.floor(host.clientHeight / cell.h));
      box.style.height = rows * cell.h + "px";
      if (!lastFit || lastFit.cols !== cols || lastFit.rows !== rows) {
        lastFit = { cols, rows };
        send({ t: "resize", cols, rows });
      }
      setTotal(st.total, st.rows);
      fetchWindow(true);
    };
    if (nofit) {
      measure();
      fetchWindow(true);
    } else {
      let timer = null;
      const ro = new ResizeObserver(() => {
        if (timer === null) fit();
        clearTimeout(timer);
        timer = setTimeout(() => { timer = null; fit(); }, 80);
      });
      ro.observe(host);
      cleanup(() => { ro.disconnect(); clearTimeout(timer); });
      document.fonts.ready.then(fit);
    }
  },
});
