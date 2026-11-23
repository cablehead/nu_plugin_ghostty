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
//                              {t:"resize", cols, rows},
//                              {t:"mouse", kind, button, x, y, mods},
//                              {t:"focus", on}
//
// Only the last `rows` rows of a terminal (its active area) can change. Rows
// above it are history and stay as they were. So a tick only costs a request
// when the page shows some of the active area, or follows the output; scrolled
// back into history, a tick just lengthens the scrollbar.
//
// The scroll area is squeezed, after largediff-go-brr's /anchor/ (itself after
// CodeMirror 6's BigScaler): a browser can't make an element millions of pixels
// tall, so the spacer is at most `cap` pixels. The rows the page holds sit at
// their real height, and the gaps above and below them are squeezed, so
// scrolling among them is the browser's own, 1:1. A new window mid-gesture is
// placed where the row at the top of the view already is, so nothing moves and
// scrollTop is not written; at rest the gaps go back to the even squeeze.
//
// Mouse and focus, as ptyZZZ's <pty-term> has them: the terminal captures the
// mouse only while the program asked for mouse reports and the terminal has
// focus, and never with Shift held, which keeps native selection and scroll.
// Focus in and out go to the program only when it asked for them.
//
// Props:
//   src    the server path above
//   nofit  observe without resizing the terminal
//   cap    the most pixels the scroll area takes (default 12,000,000)
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

// Rows are padded with spaces to the terminal's width; strip trailing space
// per line, so a copy matches what a terminal would give.
document.addEventListener("copy", (ev) => {
  const sel = getSelection();
  if (!sel || !sel.anchorNode?.parentElement?.closest("ghostty-term")) return;
  const text = sel.toString();
  const trimmed = text.split("\n").map((l) => l.replace(/[ \t]+$/, "")).join("\n");
  if (!text || trimmed === text) return;
  ev.clipboardData?.setData("text/plain", trimmed);
  ev.preventDefault();
});

rocket("ghostty-term", {
  mode: "light",
  props: ({ string, bool }) => ({
    src: string.trim,
    nofit: bool,
    cap: string.trim,
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

    // ---- the squeeze. Document pixels are rows * rowH; scroller pixels are
    // the capped spacer's. g: {o, b, total, span, dTop, dBot}: the window's
    // document top and bottom, the document and spacer heights, and where the
    // window sits in the spacer.
    const REST = 300;
    let g = null, lastScroll = 0, restTimer = 0;
    const geo = (dTop) => {
      const total = st.total * rowH();
      const span = Math.max(Math.min(total, Number(props.cap) || 12_000_000), box.clientHeight);
      const o = Math.max(0, st.top) * rowH();
      const b = o + Math.max(0, st.h) * rowH();
      const wh = b - o;
      if (!(total > span && span > wh)) return { o, b, total, span: Math.max(total, 1), dTop: o, dBot: b };
      const even = Math.round(o * (span - wh) / (total - wh));
      const top = Math.min(Math.max(dTop ?? even, 0), span - wh);
      return { o, b, total, span, dTop: top, dBot: top + wh };
    };
    const fromDOM = (g, n) => {
      if (n < g.dTop) return g.dTop > 0 ? n * g.o / g.dTop : 0;
      if (n <= g.dBot) return g.o + (n - g.dTop);
      const gap = g.span - g.dBot;
      return gap > 0 ? g.b + (n - g.dBot) * (g.total - g.b) / gap : g.b;
    };
    const toDOM = (g, y) => {
      if (y < g.o) return g.o > 0 ? y * g.dTop / g.o : 0;
      if (y <= g.b) return g.dTop + (y - g.o);
      const gap = g.total - g.b;
      return gap > 0 ? g.dBot + (y - g.b) * (g.span - g.dBot) / gap : g.dBot;
    };
    // Show geometry `next` with document pixel y at the top of the view.
    const place = (next, y) => {
      g = next;
      spacer.style.height = g.span + "px";
      win.style.top = g.dTop + "px";
      drawCursor();
      if (y == null) return;
      const t = toDOM(g, y);
      if (Math.abs(box.scrollTop - t) > 1) { box.scrollTop = t; lastWrote = box.scrollTop; }
    };
    // The document pixel at the top of the view.
    const docY = () => fromDOM(g || geo(null), box.scrollTop);

    // The rows the page wants: those in view plus a screenful either side.
    const wanted = () => {
      const first = Math.floor(docY() / rowH());
      const n = viewRows();
      return { top: Math.max(0, first - n), h: n * 3 };
    };
    const covers = (w) => st.top >= 0 && w.top >= st.top && w.top + w.h <= st.top + st.h + 1;
    const showsActive = () => st.top >= 0 && st.top + st.h > activeTop();

    const setTotal = (total, rows) => {
      st.total = total;
      if (rows) st.rows = rows;
      // Following, the bottom is the place; otherwise keep the row at the top.
      place(geo(g ? g.dTop : null), st.stick ? null : docY());
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
          const y = docY();
          const old = g;
          win.innerHTML = r.html;
          st.top = r.top; st.h = w.h; st.fp = r.fp;
          st.cols = r.cols; st.total = r.total; st.rows = r.rows;
          st.cursor = r.cursor;
          st.mouse = r.mouse;
          host.classList.toggle("grabbed", !!r.mouse);
          if (st.stick) {
            place(geo(null), null);
          } else if (performance.now() - lastScroll >= REST || !old) {
            place(geo(null), y);
          } else {
            // Mid-gesture: the row at the top of the view stays where it is.
            const o = r.top * rowH(), b = o + w.h * rowH();
            const dTop = y >= o && y <= b ? box.scrollTop - (y - o) : toDOM(old, o);
            place(geo(dTop), y);
          }
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
      // The cursor's row is a document row: place it within the window.
      cursorEl.style.top = (g ? g.dTop : 0) + (c.y - Math.max(0, st.top)) * rowH() + "px";
      cursorEl.style.left = c.x * (cell?.w || 8) + "px";
      cursorEl.style.width = (cell?.w || 8) + "px";
      cursorEl.style.height = rowH() + "px";
    };
    host.addEventListener("focusin", drawCursor);
    host.addEventListener("focusout", () => setTimeout(drawCursor));

    box.addEventListener("scroll", () => {
      if (box.scrollTop !== lastWrote) {
        lastScroll = performance.now();
        setStick(box.scrollTop >= box.scrollHeight - box.clientHeight - rowH());
        clearTimeout(restTimer);
        // At rest, the even squeeze again: one scrollTop write while nothing moves.
        restTimer = setTimeout(() => { if (!st.stick && g) place(geo(null), docY()); }, REST);
      }
      if (!covers(wanted())) fetchWindow(true);
    }, { passive: true });
    cleanup(() => clearTimeout(restTimer));

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

    // ---- focus reports: only a real change, and a press waits for its click
    let focused = null, pressing = false;
    const sendFocus = (on) => { if (on === focused) return; focused = on; send({ t: "focus", on }); };
    host.addEventListener("focusin", () => sendFocus(true));
    host.addEventListener("focusout", (ev) => { if (!pressing && !host.contains(ev.relatedTarget)) sendFocus(false); });
    host.addEventListener("pointerdown", () => { pressing = true; }, true);
    const settle = () => {
      if (!pressing) return;
      pressing = false;
      setTimeout(() => sendFocus(document.hasFocus() && host.contains(document.activeElement)));
    };
    addEventListener("pointerup", settle, true);
    addEventListener("pointercancel", settle, true);
    cleanup(() => { removeEventListener("pointerup", settle, true); removeEventListener("pointercancel", settle, true); });

    // Shift down shows the text cursor over a grabbed terminal.
    const shiftState = (ev) => host.classList.toggle("shift", ev.shiftKey);
    addEventListener("keydown", shiftState, true);
    addEventListener("keyup", shiftState, true);
    box.addEventListener("pointermove", shiftState);
    cleanup(() => { removeEventListener("keydown", shiftState, true); removeEventListener("keyup", shiftState, true); });

    // ---- mouse: captured only while the program asked and this terminal has focus
    const grabbed = () => st.mouse && host.contains(document.activeElement);
    host.classList.toggle("grabbed", false);
    const mods = (ev) => (ev.shiftKey ? 1 : 0) | (ev.altKey ? 2 : 0) | (ev.ctrlKey ? 4 : 0) | (ev.metaKey ? 8 : 0);
    // The cell under the pointer, in active-area coordinates, clamped to it.
    const cellAt = (ev) => {
      if (!cell) return null;
      const r = win.getBoundingClientRect();
      const row = Math.max(0, st.top) + Math.floor((ev.clientY - r.top) / cell.h);
      const x = Math.max(0, Math.min(st.cols - 1, Math.floor((ev.clientX - r.left) / cell.w)));
      const y = Math.max(0, Math.min(st.rows - 1, row - activeTop()));
      return { x, y };
    };
    const BUTTONS = [["left", 1], ["middle", 4], ["right", 2]];
    let down = 0, lastCell = null, pendingMove = null;
    const press = (kind, b, ev) => {
      const p = cellAt(ev);
      if (!p) return;
      lastCell = p.x + "," + p.y;
      send({ t: "mouse", kind, button: BUTTONS[b][0], ...p, mods: mods(ev) });
    };
    box.addEventListener("pointerdown", (ev) => {
      if (!grabbed() || ev.shiftKey || !BUTTONS[ev.button]) return;
      ev.preventDefault();
      try { ta.focus({ preventScroll: true }); } catch {}
      box.setPointerCapture(ev.pointerId);
      down |= BUTTONS[ev.button][1];
      press("press", ev.button, ev);
    });
    box.addEventListener("pointermove", (ev) => {
      if (!down && (!grabbed() || ev.shiftKey)) return;
      const p = cellAt(ev);
      if (!p) return;
      const at = p.x + "," + p.y;
      if (at === lastCell) return;
      lastCell = at;
      send({ t: "mouse", kind: "move", ...p, mods: mods(ev) });
    });
    box.addEventListener("pointerup", (ev) => {
      const bit = BUTTONS[ev.button]?.[1];
      if (!bit || !(down & bit)) return;
      down &= ~bit;
      press("release", ev.button, ev);
    });
    box.addEventListener("pointercancel", (ev) => {
      for (let b = 0; b < BUTTONS.length; b++) if (down & BUTTONS[b][1]) press("release", b, ev);
      down = 0;
    });
    box.addEventListener("contextmenu", (ev) => { if (grabbed() && !ev.shiftKey) ev.preventDefault(); });
    // Wheel: a step per row of travel, the remainder kept, so a trackpad's
    // burst of small deltas scrolls by distance, not by event count.
    let wheelY = 0, wheelX = 0;
    box.addEventListener("wheel", (ev) => {
      if (!grabbed() || ev.shiftKey || !cell) return;
      ev.preventDefault();
      const [sx, sy] = ev.deltaMode === 1 ? [1, 1] : ev.deltaMode === 2 ? [1 / st.cols, 1 / st.rows] : [cell.w, cell.h];
      wheelX += ev.deltaX; wheelY += ev.deltaY;
      const p = cellAt(ev);
      if (!p) return;
      const step = (button) => send({ t: "mouse", kind: "press", button, ...p, mods: mods(ev) });
      for (; wheelY >= sy; wheelY -= sy) step("wheeldown");
      for (; wheelY <= -sy; wheelY += sy) step("wheelup");
      for (; wheelX >= sx; wheelX -= sx) step("wheelright");
      for (; wheelX <= -sx; wheelX += sx) step("wheelleft");
    }, { passive: false });

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
