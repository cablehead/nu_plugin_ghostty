// nu_plugin_ghostty: a terminal kept in libghostty-vt, asked for rows like
// largediff asks for a window of a diff.
//
//   let t = ghostty spawn [bash -l] --cols 100 --rows 30
//   $t | ghostty input "ls\r"
//   $t | ghostty window 0 30 --fp $fp     # {fp, top, total, rows, cols, html} or {unchanged: true}
//   $t | ghostty changes                  # one record each time the program writes
//   $t | ghostty key ArrowUp --mods 4      # a browser key, encoded as the program asked
//   $t | ghostty paste "two\nlines"       # bracketed when the program asked
//   $t | ghostty mouse press --button left --x 4 --y 2   # reported when the program asked
//   $t | ghostty focus true                # reported when the program asked
//   $t | ghostty resize 120 40
//   $t | ghostty palette                  # the <style> block the HTML's colours refer to
//   $t | ghostty info
//
// Speaks nushell's plugin protocol, JSON encoding, over stdin and stdout.
// A handle is an int. A reader thread per terminal feeds the program's
// output into libghostty under that terminal's lock; every call reads under
// the same lock.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const keys = @import("keys.zig");

/// The nushell minor versions whose plugin messages this speaks. The plugin
/// answers the engine's Hello with the engine's own version when its minor
/// is one of these, and with the first otherwise, which nushell refuses.
const nu_minors = [_][]const u8{ "0.117.", "0.116." };
const plugin_version = "0.1.0";
const alloc = std.heap.c_allocator;

// ---------------------------------------------------------------- output

var out_lock: c.pthread_mutex_t = undefined;

fn send(msg: []const u8) void {
    _ = c.pthread_mutex_lock(&out_lock);
    defer _ = c.pthread_mutex_unlock(&out_lock);
    writeAll(1, msg);
    writeAll(1, "\n");
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// A JSON string being built. Errors are out-of-memory only, which ends
/// the plugin anyway.
const J = struct {
    buf: std.ArrayList(u8) = .empty,

    fn raw(self: *J, s: []const u8) void {
        self.buf.appendSlice(alloc, s) catch @panic("oom");
    }
    fn fmt(self: *J, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(alloc, f, args) catch @panic("oom");
        defer alloc.free(s);
        self.raw(s);
    }
    fn str(self: *J, s: []const u8) void {
        self.raw("\"");
        for (s) |ch| {
            switch (ch) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                0...8, 11, 12, 14...31, 127 => self.fmt("\\u{x:0>4}", .{ch}),
                else => self.buf.append(alloc, ch) catch @panic("oom"),
            }
        }
        self.raw("\"");
    }
    fn deinit(self: *J) void {
        self.buf.deinit(alloc);
    }
};

const Span = struct { start: i64, end: i64 };

fn spanJ(j: *J, s: Span) void {
    j.fmt("{{\"start\":{d},\"end\":{d}}}", .{ s.start, s.end });
}

fn intV(j: *J, v: i64, s: Span) void {
    j.fmt("{{\"Int\":{{\"val\":{d},\"span\":", .{v});
    spanJ(j, s);
    j.raw("}}");
}

fn boolV(j: *J, v: bool, s: Span) void {
    j.fmt("{{\"Bool\":{{\"val\":{},\"span\":", .{v});
    spanJ(j, s);
    j.raw("}}");
}

fn strV(j: *J, v: []const u8, s: Span) void {
    j.raw("{\"String\":{\"val\":");
    j.str(v);
    j.raw(",\"span\":");
    spanJ(j, s);
    j.raw("}}");
}

fn respondValue(id: i64, value: []const u8) void {
    var j: J = .{};
    defer j.deinit();
    j.fmt("{{\"CallResponse\":[{d},{{\"PipelineData\":{{\"Value\":[", .{id});
    j.raw(value);
    j.raw(",null]}}]}");
    send(j.buf.items);
}

fn respondError(id: i64, msg: []const u8, s: Span) void {
    var j: J = .{};
    defer j.deinit();
    j.fmt("{{\"CallResponse\":[{d},{{\"Error\":{{\"msg\":", .{id});
    j.str(msg);
    j.raw(",\"labels\":[{\"text\":");
    j.str(msg);
    j.raw(",\"span\":");
    spanJ(&j, s);
    j.raw("}]}}]}");
    send(j.buf.items);
}

// ---------------------------------------------------------------- terminals

const max_terms = 32;
const max_subs = 16;

const Term = struct {
    t: c.GhosttyTerminal,
    fmt: c.GhosttyFormatter,
    enc: c.GhosttyKeyEncoder = null,
    menc: c.GhosttyMouseEncoder = null,
    fd: c_int,
    pid: c.pid_t,
    lock: c.pthread_mutex_t,
    seq: i64 = 0,
    alive: bool = true,
    cols: u16,
    rows: u16,
    /// stream ids of open `ghostty changes`, 0 when free
    subs: [max_subs]i64 = @splat(0),
    sub_span: [max_subs]Span = undefined,
};

var terms: [max_terms]?*Term = @splat(null);
var terms_lock: c.pthread_mutex_t = undefined;
var next_stream: i64 = 1;

fn getTerm(h: i64) ?*Term {
    if (h < 1 or h > max_terms) return null;
    _ = c.pthread_mutex_lock(&terms_lock);
    defer _ = c.pthread_mutex_unlock(&terms_lock);
    return terms[@intCast(h - 1)];
}

/// libghostty calls this when the program asks the terminal something
/// (cursor position, device attributes): the answer goes back to the pty.
fn onWritePty(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const term: *Term = @ptrCast(@alignCast(userdata.?));
    writeAll(term.fd, data[0..len]);
}

fn reader(term: *Term) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(term.fd, &buf, buf.len);
        if (n <= 0) break;
        var subs: [max_subs]i64 = undefined;
        var seq: i64 = 0;
        var total: usize = 0;
        var rows: u16 = 0;
        {
            _ = c.pthread_mutex_lock(&term.lock);
            defer _ = c.pthread_mutex_unlock(&term.lock);
            c.ghostty_terminal_vt_write(term.t, &buf, @intCast(n));
            term.seq += 1;
            seq = term.seq;
            subs = term.subs;
            _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total);
            rows = term.rows;
        }
        for (subs, 0..) |sid, i| {
            if (sid == 0) continue;
            var j: J = .{};
            defer j.deinit();
            const s = term.sub_span[i];
            j.fmt("{{\"Data\":[{d},{{\"List\":{{\"Record\":{{\"val\":{{\"seq\":", .{sid});
            intV(&j, seq, s);
            j.raw(",\"total\":");
            intV(&j, @intCast(total), s);
            j.raw(",\"rows\":");
            intV(&j, rows, s);
            j.raw("},\"span\":");
            spanJ(&j, s);
            j.raw("}}}]}");
            send(j.buf.items);
        }
    }
    var subs: [max_subs]i64 = undefined;
    {
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        term.alive = false;
        subs = term.subs;
        term.subs = @splat(0);
    }
    for (subs) |sid| {
        if (sid == 0) continue;
        var j: J = .{};
        defer j.deinit();
        j.fmt("{{\"End\":{d}}}", .{sid});
        send(j.buf.items);
    }
    var status: c_int = 0;
    _ = c.waitpid(term.pid, &status, 0);
}

fn spawnTerm(argv: []const []const u8, cols: u16, rows: u16, scrollback: usize) !i64 {
    // Everything the child needs is built before the fork.
    const cargv = try alloc.alloc([*c]u8, argv.len + 1);
    for (argv, 0..) |a, i| cargv[i] = (try alloc.dupeSentinel(u8, a, 0)).ptr;
    cargv[argv.len] = null;

    var ws: c.struct_winsize = .{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    var fd: c_int = -1;
    const pid = c.forkpty(&fd, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setenv("TERM", "xterm-256color", 1);
        _ = c.execvp(cargv[0], @ptrCast(cargv.ptr));
        c._exit(127);
    }

    const term = try alloc.create(Term);
    term.* = .{ .t = undefined, .fmt = undefined, .fd = fd, .pid = pid, .lock = undefined, .cols = cols, .rows = rows };
    _ = c.pthread_mutex_init(&term.lock, null);
    if (c.ghostty_terminal_new(null, &term.t, cols, rows) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
    // libghostty keeps 10,000 bytes of history by default, a few hundred
    // rows. Lift the byte limit, so --scrollback's line count is the limit.
    var no_byte_limit: usize = std.math.maxInt(usize);
    _ = c.ghostty_terminal_set(term.t, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, @ptrCast(&no_byte_limit));
    var max_lines: usize = scrollback;
    _ = c.ghostty_terminal_set(term.t, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, @ptrCast(&max_lines));
    _ = c.ghostty_terminal_set(term.t, c.GHOSTTY_TERMINAL_OPT_USERDATA, @ptrCast(term));
    _ = c.ghostty_terminal_set(term.t, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(@constCast(&onWritePty)));
    if (c.ghostty_formatter_terminal_new(null, &term.fmt, term.t) != c.GHOSTTY_SUCCESS) return error.FormatterFailed;
    if (c.ghostty_key_encoder_new(null, &term.enc) != c.GHOSTTY_SUCCESS) return error.EncoderFailed;
    if (c.ghostty_mouse_encoder_new(null, &term.menc) != c.GHOSTTY_SUCCESS) return error.EncoderFailed;
    var emit: c.GhosttyFormatterFormat = c.GHOSTTY_FORMATTER_FORMAT_HTML;
    _ = c.ghostty_formatter_set(term.fmt, c.GHOSTTY_FORMATTER_OPT_EMIT, &emit);
    var extras: c.GhosttyFormatterExtras = c.GHOSTTY_FORMATTER_EXTRAS_NONE;
    _ = c.ghostty_formatter_set(term.fmt, c.GHOSTTY_FORMATTER_OPT_EXTRAS, &extras);

    _ = c.pthread_mutex_lock(&terms_lock);
    defer _ = c.pthread_mutex_unlock(&terms_lock);
    for (&terms, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = term;
            const th = try std.Thread.spawn(.{}, reader, .{term});
            th.detach();
            return @intCast(i + 1);
        }
    }
    return error.TooManyTerminals;
}

/// Rows `top` up to `top + height` of the screen, scrollback included, as
/// HTML. Caller frees.
const Cursor = struct { x: i64 = 0, y: i64 = 0, visible: bool = false, mouse: bool = false };

/// Whether a mode is on. Caller holds the lock.
fn modeOn(term: *Term, mode: c.GhosttyMode) bool {
    var m: c.GhosttyTerminalModeConfig = .{ .mode = mode, .value = false };
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_MODE, &m);
    return m.value;
}

fn windowHtml(term: *Term, top_in: i64, height_in: i64, out_top: *i64, out_total: *i64, cursor: *Cursor) ![]u8 {
    _ = c.pthread_mutex_lock(&term.lock);
    defer _ = c.pthread_mutex_unlock(&term.lock);
    var total: usize = 0;
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total);
    var cx: u16 = 0;
    var cy: u16 = 0;
    var cvis: bool = true;
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &cvis);
    // The cursor's row counts from the top of the active area, the last
    // `rows` rows; here it is a row of the whole screen, like `top`.
    // The program has asked for mouse reports: the page captures the mouse.
    const mouse = modeOn(term, c.GHOSTTY_MODE_MOUSE_EVENT_X10) or modeOn(term, c.GHOSTTY_MODE_MOUSE_EVENT_NORMAL) or
        modeOn(term, c.GHOSTTY_MODE_MOUSE_EVENT_BUTTON) or modeOn(term, c.GHOSTTY_MODE_MOUSE_EVENT_ANY);
    cursor.* = .{ .x = cx, .y = @as(i64, @intCast(total)) - term.rows + cy, .visible = cvis, .mouse = mouse };
    var cols: u16 = 0;
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_COLS, &cols);
    out_total.* = @intCast(total);
    if (total == 0 or height_in <= 0) {
        out_top.* = 0;
        return try alloc.dupe(u8, "");
    }
    const t_total: i64 = @intCast(total);
    const top = std.math.clamp(top_in, 0, t_total - 1);
    const last = @min(top + height_in, t_total) - 1;
    out_top.* = top;

    var sel: c.GhosttySelection = .{};
    var p: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_SCREEN };
    p.value.coordinate = .{ .x = 0, .y = @intCast(top) };
    if (c.ghostty_terminal_grid_ref(term.t, p, &sel.start) != c.GHOSTTY_SUCCESS) return error.GridRef;
    p.value.coordinate = .{ .x = if (cols > 0) cols - 1 else 0, .y = @intCast(last) };
    if (c.ghostty_terminal_grid_ref(term.t, p, &sel.end) != c.GHOSTTY_SUCCESS) return error.GridRef;
    _ = c.ghostty_formatter_set(term.fmt, c.GHOSTTY_FORMATTER_OPT_SELECTION, &sel);

    var buf: [*c]u8 = null;
    var len: usize = 0;
    if (c.ghostty_formatter_format_alloc(term.fmt, null, &buf, &len) != c.GHOSTTY_SUCCESS) return error.Format;
    defer c.ghostty_free(null, buf, len);
    return try alloc.dupe(u8, buf[0..len]);
}

/// A browser KeyboardEvent.code, such as "ArrowUp", "KeyA" or "Digit1", as
/// libghostty names it: "ARROW_UP", "A", "DIGIT_1".
fn keyFromCode(code: []const u8) c.GhosttyKey {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var src = code;
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key")) src = code[3..];
    for (src, 0..) |ch, i| {
        if (n + 2 > buf.len) return c.GHOSTTY_KEY_UNIDENTIFIED;
        const prev: u8 = if (i > 0) src[i - 1] else 0;
        const upper = std.ascii.isUpper(ch);
        const digit = std.ascii.isDigit(ch);
        if (i > 0 and ((upper and (std.ascii.isLower(prev) or std.ascii.isDigit(prev))) or (digit and std.ascii.isLower(prev)))) {
            buf[n] = '_';
            n += 1;
        }
        buf[n] = std.ascii.toUpper(ch);
        n += 1;
    }
    for (keys.all) |k| if (std.mem.eql(u8, k.name, buf[0..n])) return k.key;
    return c.GHOSTTY_KEY_UNIDENTIFIED;
}

/// A key as the program asked to be sent keys: application cursor keys,
/// the kitty protocol, and so on, read from the terminal at each press.
/// `mods` is the browser's: 1 shift, 2 alt, 4 ctrl, 8 meta. Caller frees.
fn encodeKey(term: *Term, code: []const u8, text: []const u8, mods: i64) ![]u8 {
    const key = keyFromCode(code);
    var gm: c.GhosttyMods = 0;
    if (mods & 1 != 0) gm |= c.GHOSTTY_MODS_SHIFT;
    if (mods & 2 != 0) gm |= c.GHOSTTY_MODS_ALT;
    if (mods & 4 != 0) gm |= c.GHOSTTY_MODS_CTRL;
    if (mods & 8 != 0) gm |= c.GHOSTTY_MODS_SUPER;

    var ev: c.GhosttyKeyEvent = null;
    if (c.ghostty_key_event_new(null, &ev) != c.GHOSTTY_SUCCESS) return error.KeyEvent;
    defer c.ghostty_key_event_free(ev);
    _ = c.ghostty_key_event_set_action(ev, c.GHOSTTY_KEY_ACTION_PRESS);
    _ = c.ghostty_key_event_set_key(ev, key);
    _ = c.ghostty_key_event_set_mods(ev, gm);
    // The character the key makes without shift: what ctrl and alt combine with.
    var unshifted: u32 = 0;
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key")) unshifted = std.ascii.toLower(code[3]);
    if (code.len == 6 and std.mem.startsWith(u8, code, "Digit")) unshifted = code[5];
    if (unshifted == 0 and text.len == 1 and mods & 1 == 0) unshifted = text[0];
    if (unshifted != 0) _ = c.ghostty_key_event_set_unshifted_codepoint(ev, unshifted);
    if (text.len > 0) _ = c.ghostty_key_event_set_utf8(ev, .{ .ptr = text.ptr, .len = text.len });

    var buf: [128]u8 = undefined;
    var written: usize = 0;
    {
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        _ = c.ghostty_key_encoder_set_from_terminal(term.enc, term.t);
        // The browser reports Option as alt, and means it as alt: the page
        // already let Option make its own characters (a composed glyph
        // arrives as --text with no alt bit). Re-set at each press, since
        // reading the terminal's modes may reset it.
        var opt: c.GhosttyOptionAsAlt = c.GHOSTTY_OPTION_AS_ALT_TRUE;
        _ = c.ghostty_key_encoder_set(term.enc, c.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &opt);
        if (c.ghostty_key_encoder_encode(term.enc, ev, &buf, buf.len, &written) != c.GHOSTTY_SUCCESS) return error.KeyEncode;
    }
    // A key libghostty has nothing to encode for, but which carries text
    // (a character on a layout it does not know), goes as that text.
    if (written == 0 and text.len > 0 and mods & (4 | 8) == 0) return try alloc.dupe(u8, text);
    return try alloc.dupe(u8, buf[0..written]);
}

/// A mouse event at a cell of the active area (x, y from its top left), as
/// the program asked for mouse events: which ones, in which format. Nothing
/// when it asked for none. `button`: left, middle, right, wheelup,
/// wheeldown, wheelleft, wheelright; none for a move. Caller frees.
fn encodeMouse(term: *Term, kind: []const u8, button: []const u8, x: i64, y: i64, mods: i64) ![]u8 {
    var ev: c.GhosttyMouseEvent = null;
    if (c.ghostty_mouse_event_new(null, &ev) != c.GHOSTTY_SUCCESS) return error.MouseEvent;
    defer c.ghostty_mouse_event_free(ev);
    const action: c.GhosttyMouseAction = if (std.mem.eql(u8, kind, "press")) c.GHOSTTY_MOUSE_ACTION_PRESS else if (std.mem.eql(u8, kind, "release")) c.GHOSTTY_MOUSE_ACTION_RELEASE else c.GHOSTTY_MOUSE_ACTION_MOTION;
    _ = c.ghostty_mouse_event_set_action(ev, action);
    const names = [_][]const u8{ "left", "middle", "right", "wheelup", "wheeldown", "wheelleft", "wheelright" };
    const buttons = [_]c.GhosttyMouseButton{ c.GHOSTTY_MOUSE_BUTTON_LEFT, c.GHOSTTY_MOUSE_BUTTON_MIDDLE, c.GHOSTTY_MOUSE_BUTTON_RIGHT, c.GHOSTTY_MOUSE_BUTTON_FOUR, c.GHOSTTY_MOUSE_BUTTON_FIVE, c.GHOSTTY_MOUSE_BUTTON_SIX, c.GHOSTTY_MOUSE_BUTTON_SEVEN };
    for (names, buttons) |n, b| if (std.mem.eql(u8, n, button)) {
        _ = c.ghostty_mouse_event_set_button(ev, b);
    };
    var gm: c.GhosttyMods = 0;
    if (mods & 1 != 0) gm |= c.GHOSTTY_MODS_SHIFT;
    if (mods & 2 != 0) gm |= c.GHOSTTY_MODS_ALT;
    if (mods & 4 != 0) gm |= c.GHOSTTY_MODS_CTRL;
    if (mods & 8 != 0) gm |= c.GHOSTTY_MODS_SUPER;
    _ = c.ghostty_mouse_event_set_mods(ev, gm);
    // Cells as pixels one unit square: the middle of cell (x, y).
    _ = c.ghostty_mouse_event_set_position(ev, .{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 });

    var buf: [128]u8 = undefined;
    var written: usize = 0;
    {
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        _ = c.ghostty_mouse_encoder_set_from_terminal(term.menc, term.t);
        var size: c.GhosttyMouseEncoderSize = .{ .size = @sizeOf(c.GhosttyMouseEncoderSize), .screen_width = term.cols, .screen_height = term.rows, .cell_width = 1, .cell_height = 1 };
        _ = c.ghostty_mouse_encoder_set(term.menc, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        if (c.ghostty_mouse_encoder_encode(term.menc, ev, &buf, buf.len, &written) != c.GHOSTTY_SUCCESS) return error.MouseEncode;
    }
    return try alloc.dupe(u8, buf[0..written]);
}

/// Pasted text, bracketed when the program turned bracketed paste on, and
/// stripped of control bytes either way. Caller frees.
fn encodePaste(term: *Term, text: []const u8) ![]u8 {
    var mode: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_BRACKETED_PASTE, .value = false };
    {
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_MODE, &mode);
    }
    const data = try alloc.dupe(u8, text);
    defer alloc.free(data);
    var needed: usize = 0;
    _ = c.ghostty_paste_encode(data.ptr, data.len, mode.value, null, 0, &needed);
    const out = try alloc.alloc(u8, needed);
    var written: usize = 0;
    if (c.ghostty_paste_encode(data.ptr, data.len, mode.value, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) {
        alloc.free(out);
        return error.PasteEncode;
    }
    return out[0..written];
}

/// New size for the terminal and the program: libghostty reflows, and the
/// pty tells the program, which redraws.
fn resizeTerm(term: *Term, cols: u16, rows: u16) void {
    {
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        _ = c.ghostty_terminal_resize(term.t, cols, rows, 0, 0);
        term.cols = cols;
        term.rows = rows;
    }
    var ws: c.struct_winsize = .{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    // TIOCSWINSZ is a macro translate-c cannot carry.
    const tiocswinsz: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else 0x5414;
    _ = c.ioctl(term.fd, tiocswinsz, &ws);
}

/// The terminal's colours as the `<style>` block the HTML's
/// `var(--vt-palette-N)` refer to. Caller frees.
fn paletteCss(term: *Term) ![]u8 {
    _ = c.pthread_mutex_lock(&term.lock);
    defer _ = c.pthread_mutex_unlock(&term.lock);
    var f: c.GhosttyFormatter = null;
    if (c.ghostty_formatter_terminal_new(null, &f, term.t) != c.GHOSTTY_SUCCESS) return error.FormatterFailed;
    defer c.ghostty_formatter_free(f);
    var emit: c.GhosttyFormatterFormat = c.GHOSTTY_FORMATTER_FORMAT_HTML;
    _ = c.ghostty_formatter_set(f, c.GHOSTTY_FORMATTER_OPT_EMIT, &emit);
    var extras: c.GhosttyFormatterExtras = c.GHOSTTY_FORMATTER_EXTRA_PALETTE;
    _ = c.ghostty_formatter_set(f, c.GHOSTTY_FORMATTER_OPT_EXTRAS, &extras);
    var buf: [*c]u8 = null;
    var len: usize = 0;
    if (c.ghostty_formatter_format_alloc(f, null, &buf, &len) != c.GHOSTTY_SUCCESS) return error.Format;
    defer c.ghostty_free(null, buf, len);
    const html = buf[0..len];
    const end = std.mem.indexOf(u8, html, "</style>") orelse return try alloc.dupe(u8, "");
    return try alloc.dupe(u8, html[0 .. end + "</style>".len]);
}

// ---------------------------------------------------------------- calls

const V = std.json.Value;

fn field(v: V, k: []const u8) ?V {
    if (v != .object) return null;
    return v.object.get(k);
}

/// The inner value of a nu Value of one type, `{"Int": {"val": 3, ...}}`.
fn nuVal(v: V, ty: []const u8) ?V {
    const inner = field(v, ty) orelse return null;
    return field(inner, "val");
}

fn nuInt(v: V) ?i64 {
    const x = nuVal(v, "Int") orelse return null;
    return if (x == .integer) x.integer else null;
}

fn nuStr(v: V) ?[]const u8 {
    const x = nuVal(v, "String") orelse return null;
    return if (x == .string) x.string else null;
}

fn named(call: V, name: []const u8) ?V {
    const list = field(call, "named") orelse return null;
    if (list != .array) return null;
    for (list.array.items) |pair| {
        if (pair != .array or pair.array.items.len < 2) continue;
        const key = pair.array.items[0];
        const k = field(key, "item") orelse key;
        if (k == .string and std.mem.eql(u8, k.string, name)) {
            const val = pair.array.items[1];
            return if (val == .null) null else val;
        }
    }
    return null;
}

fn positional(call: V, i: usize) ?V {
    const list = field(call, "positional") orelse return null;
    if (list != .array or i >= list.array.items.len) return null;
    return list.array.items[i];
}

fn headSpan(call: V) Span {
    const h = field(call, "head") orelse return .{ .start = 0, .end = 0 };
    const s = field(h, "start") orelse V{ .integer = 0 };
    const e = field(h, "end") orelse V{ .integer = 0 };
    return .{ .start = if (s == .integer) s.integer else 0, .end = if (e == .integer) e.integer else 0 };
}

/// The handle piped in: `$t | ghostty window ...`.
fn inputHandle(input: V) ?i64 {
    const val = field(input, "Value") orelse return null;
    if (val != .array or val.array.items.len < 1) return null;
    return nuInt(val.array.items[0]);
}

fn run(id: i64, r: V) void {
    const name_v = field(r, "name") orelse return;
    const name = if (name_v == .string) name_v.string else return;
    const call = field(r, "call") orelse return;
    const input = field(r, "input") orelse V{ .null = {} };
    const s = headSpan(call);

    if (std.mem.eql(u8, name, "ghostty spawn")) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        const list = (if (positional(call, 0)) |p| field(p, "List") else null) orelse return respondError(id, "give the command as a list, such as [bash -l]", s);
        const vals = field(list, "vals") orelse return respondError(id, "give the command as a list, such as [bash -l]", s);
        if (vals != .array) return respondError(id, "give the command as a list, such as [bash -l]", s);
        for (vals.array.items) |p| {
            const a = nuStr(p) orelse return respondError(id, "every part of the command must be a string", s);
            argv.append(alloc, a) catch @panic("oom");
        }
        if (argv.items.len == 0) return respondError(id, "name a program to run", s);
        const cols: u16 = @intCast(std.math.clamp(if (named(call, "cols")) |v| nuInt(v) orelse 100 else 100, 2, 1000));
        const rows: u16 = @intCast(std.math.clamp(if (named(call, "rows")) |v| nuInt(v) orelse 30 else 30, 2, 500));
        const sb: usize = @intCast(std.math.clamp(if (named(call, "scrollback")) |v| nuInt(v) orelse 10000 else 10000, 0, 10_000_000));
        const h = spawnTerm(argv.items, cols, rows, sb) catch |e| return respondError(id, @errorName(e), s);
        var j: J = .{};
        defer j.deinit();
        intV(&j, h, s);
        return respondValue(id, j.buf.items);
    }

    const h = inputHandle(input) orelse return respondError(id, "pipe in a handle from ghostty spawn", s);
    const term = getTerm(h) orelse return respondError(id, "no such terminal", s);

    if (std.mem.eql(u8, name, "ghostty input")) {
        const text = (if (positional(call, 0)) |p| nuStr(p) else null) orelse return respondError(id, "give the text to type", s);
        writeAll(term.fd, text);
        return respondValue(id, "{\"Nothing\":{\"span\":{\"start\":0,\"end\":0}}}");
    }

    if (std.mem.eql(u8, name, "ghostty key")) {
        const code = (if (positional(call, 0)) |p| nuStr(p) else null) orelse return respondError(id, "give the key's KeyboardEvent.code, such as ArrowUp or KeyA", s);
        const text = if (named(call, "text")) |v| nuStr(v) orelse "" else "";
        const mods: i64 = if (named(call, "mods")) |v| nuInt(v) orelse 0 else 0;
        const bytes = encodeKey(term, code, text, mods) catch |e| return respondError(id, @errorName(e), s);
        defer alloc.free(bytes);
        writeAll(term.fd, bytes);
        return respondValue(id, "{\"Nothing\":{\"span\":{\"start\":0,\"end\":0}}}");
    }

    if (std.mem.eql(u8, name, "ghostty paste")) {
        const text = (if (positional(call, 0)) |p| nuStr(p) else null) orelse return respondError(id, "give the text to paste", s);
        const bytes = encodePaste(term, text) catch |e| return respondError(id, @errorName(e), s);
        defer alloc.free(bytes);
        writeAll(term.fd, bytes);
        return respondValue(id, "{\"Nothing\":{\"span\":{\"start\":0,\"end\":0}}}");
    }

    if (std.mem.eql(u8, name, "ghostty resize")) {
        const cols = (if (positional(call, 0)) |p| nuInt(p) else null) orelse return respondError(id, "give the columns", s);
        const rows = (if (positional(call, 1)) |p| nuInt(p) else null) orelse return respondError(id, "give the rows", s);
        resizeTerm(term, @intCast(std.math.clamp(cols, 2, 1000)), @intCast(std.math.clamp(rows, 2, 500)));
        return respondValue(id, "{\"Nothing\":{\"span\":{\"start\":0,\"end\":0}}}");
    }

    if (std.mem.eql(u8, name, "ghostty mouse")) {
        const kind = (if (positional(call, 0)) |p| nuStr(p) else null) orelse return respondError(id, "give press, release or move", s);
        const button = if (named(call, "button")) |v| nuStr(v) orelse "" else "";
        const x: i64 = if (named(call, "x")) |v| nuInt(v) orelse 0 else 0;
        const y: i64 = if (named(call, "y")) |v| nuInt(v) orelse 0 else 0;
        const mods: i64 = if (named(call, "mods")) |v| nuInt(v) orelse 0 else 0;
        const bytes = encodeMouse(term, kind, button, x, y, mods) catch |e| return respondError(id, @errorName(e), s);
        defer alloc.free(bytes);
        writeAll(term.fd, bytes);
        return respondValue(id, "{\"Nothing\":{\"span\":{\"start\":0,\"end\":0}}}");
    }

    if (std.mem.eql(u8, name, "ghostty focus")) {
        const on = (if (positional(call, 0)) |p| nuVal(p, "Bool") else null) orelse return respondError(id, "give true or false", s);
        if (on != .bool) return respondError(id, "give true or false", s);
        var report = false;
        {
            _ = c.pthread_mutex_lock(&term.lock);
            defer _ = c.pthread_mutex_unlock(&term.lock);
            report = modeOn(term, c.GHOSTTY_MODE_FOCUS_EVENT);
        }
        // Only a program that turned focus reports on (?1004h) is told.
        if (report) {
            var buf: [16]u8 = undefined;
            var written: usize = 0;
            const ev: c.GhosttyFocusEvent = if (on.bool) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST;
            if (c.ghostty_focus_encode(ev, &buf, buf.len, &written) == c.GHOSTTY_SUCCESS) writeAll(term.fd, buf[0..written]);
        }
        return respondValue(id, "{\"Nothing\":{\"span\":{\"start\":0,\"end\":0}}}");
    }

    if (std.mem.eql(u8, name, "ghostty palette")) {
        const css = paletteCss(term) catch |e| return respondError(id, @errorName(e), s);
        defer alloc.free(css);
        var j: J = .{};
        defer j.deinit();
        strV(&j, css, s);
        return respondValue(id, j.buf.items);
    }

    if (std.mem.eql(u8, name, "ghostty info")) {
        _ = c.pthread_mutex_lock(&term.lock);
        var total: usize = 0;
        _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total);
        const seq = term.seq;
        const alive = term.alive;
        _ = c.pthread_mutex_unlock(&term.lock);
        var j: J = .{};
        defer j.deinit();
        j.raw("{\"Record\":{\"val\":{\"total\":");
        intV(&j, @intCast(total), s);
        j.raw(",\"rows\":");
        intV(&j, term.rows, s);
        j.raw(",\"cols\":");
        intV(&j, term.cols, s);
        j.raw(",\"seq\":");
        intV(&j, seq, s);
        j.raw(",\"alive\":");
        boolV(&j, alive, s);
        j.raw("},\"span\":");
        spanJ(&j, s);
        j.raw("}}");
        return respondValue(id, j.buf.items);
    }

    if (std.mem.eql(u8, name, "ghostty window")) {
        const top = (if (positional(call, 0)) |p| nuInt(p) else null) orelse return respondError(id, "give the top row", s);
        const height = (if (positional(call, 1)) |p| nuInt(p) else null) orelse return respondError(id, "give the height", s);
        var out_top: i64 = 0;
        var total: i64 = 0;
        var cursor: Cursor = .{};
        const html = windowHtml(term, top, height, &out_top, &total, &cursor) catch |e| return respondError(id, @errorName(e), s);
        defer alloc.free(html);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(html);
        var tb: [16]u8 = undefined;
        std.mem.writeInt(i64, tb[0..8], out_top, .little);
        std.mem.writeInt(i64, tb[8..16], total, .little);
        hasher.update(&tb);
        std.mem.writeInt(i64, tb[0..8], cursor.x, .little);
        std.mem.writeInt(i64, tb[8..16], cursor.y, .little);
        hasher.update(&tb);
        hasher.update(if (cursor.mouse) "m" else "-");
        const fp = std.fmt.allocPrint(alloc, "{x:0>16}", .{hasher.final()}) catch @panic("oom");
        defer alloc.free(fp);
        var j: J = .{};
        defer j.deinit();
        const prev = if (named(call, "fp")) |v| nuStr(v) else null;
        if (prev != null and std.mem.eql(u8, prev.?, fp)) {
            j.raw("{\"Record\":{\"val\":{\"unchanged\":");
            boolV(&j, true, s);
            j.raw("},\"span\":");
            spanJ(&j, s);
            j.raw("}}");
            return respondValue(id, j.buf.items);
        }
        j.raw("{\"Record\":{\"val\":{\"fp\":");
        strV(&j, fp, s);
        j.raw(",\"top\":");
        intV(&j, out_top, s);
        j.raw(",\"total\":");
        intV(&j, total, s);
        j.raw(",\"rows\":");
        intV(&j, term.rows, s);
        j.raw(",\"cols\":");
        intV(&j, term.cols, s);
        j.raw(",\"cursor\":{\"Record\":{\"val\":{\"x\":");
        intV(&j, cursor.x, s);
        j.raw(",\"y\":");
        intV(&j, cursor.y, s);
        j.raw(",\"visible\":");
        boolV(&j, cursor.visible, s);
        j.raw("},\"span\":");
        spanJ(&j, s);
        j.raw("}}");
        j.raw(",\"mouse\":");
        boolV(&j, cursor.mouse, s);
        j.raw(",\"html\":");
        strV(&j, html, s);
        j.raw("},\"span\":");
        spanJ(&j, s);
        j.raw("}}");
        return respondValue(id, j.buf.items);
    }

    if (std.mem.eql(u8, name, "ghostty changes")) {
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        if (!term.alive) return respondError(id, "the program has exited", s);
        for (&term.subs, 0..) |*slot, i| {
            if (slot.* != 0) continue;
            const sid = @atomicRmw(i64, &next_stream, .Add, 1, .seq_cst);
            slot.* = sid;
            term.sub_span[i] = s;
            var j: J = .{};
            defer j.deinit();
            j.fmt("{{\"CallResponse\":[{d},{{\"PipelineData\":{{\"ListStream\":{{\"id\":{d},\"span\":", .{ id, sid });
            spanJ(&j, s);
            j.raw(",\"metadata\":null}}}]}");
            send(j.buf.items);
            return;
        }
        return respondError(id, "too many open change streams on this terminal", s);
    }

    respondError(id, "unknown command", s);
}

/// The engine stopped reading a stream: forget it.
fn dropStream(sid: i64) void {
    for (terms) |maybe| {
        const term = maybe orelse continue;
        _ = c.pthread_mutex_lock(&term.lock);
        defer _ = c.pthread_mutex_unlock(&term.lock);
        for (&term.subs) |*slot| {
            if (slot.* == sid) {
                slot.* = 0;
                var j: J = .{};
                defer j.deinit();
                j.fmt("{{\"End\":{d}}}", .{sid});
                send(j.buf.items);
            }
        }
    }
}

const signatures =
    \\{"Signature":[
    \\{"sig":{"name":"ghostty spawn","description":"Run a program in a terminal kept by libghostty. Returns a handle.","extra_description":"","search_terms":["terminal","pty"],
    \\ "required_positional":[{"name":"command","desc":"the program and its arguments, such as [bash -l]","shape":{"List":"String"}}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"},
    \\  {"long":"cols","short":null,"arg":"Int","required":false,"desc":"columns, default 100"},
    \\  {"long":"rows","short":null,"arg":"Int","required":false,"desc":"rows, default 30"},
    \\  {"long":"scrollback","short":null,"arg":"Int","required":false,"desc":"lines of scrollback kept, default 10000"}],
    \\ "input_output_types":[["Nothing","Int"],["Any","Int"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty input","description":"Type into a terminal.","extra_description":"","search_terms":[],
    \\ "required_positional":[{"name":"text","desc":"the bytes to send, such as \"ls\\r\"","shape":"String"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int","Nothing"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty window","description":"Rows of the terminal, scrollback included, as HTML.","extra_description":"Row 0 is the oldest line kept. With --fp, returns {unchanged: true} when the window is as it was.","search_terms":[],
    \\ "required_positional":[{"name":"top","desc":"first row","shape":"Int"},{"name":"height","desc":"number of rows","shape":"Int"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"},
    \\  {"long":"fp","short":null,"arg":"String","required":false,"desc":"the fp of the window you have"}],
    \\ "input_output_types":[["Int",{"Record":[]}]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty changes","description":"A stream with one record each time the program writes, until it exits.","extra_description":"","search_terms":[],
    \\ "required_positional":[],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int",{"List":{"Record":[]}}]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty key","description":"Press a key, named as a browser's KeyboardEvent.code. libghostty encodes it the way the program asked keys to be sent.","extra_description":"--mods is the browser's: 1 shift, 2 alt, 4 ctrl, 8 meta. --text is the KeyboardEvent.key the key made, when it made a character.","search_terms":[],
    \\ "required_positional":[{"name":"code","desc":"such as ArrowUp, KeyA, Enter","shape":"String"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"},
    \\  {"long":"text","short":null,"arg":"String","required":false,"desc":"the character the key made"},
    \\  {"long":"mods","short":null,"arg":"Int","required":false,"desc":"1 shift, 2 alt, 4 ctrl, 8 meta"}],
    \\ "input_output_types":[["Int","Nothing"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty paste","description":"Paste text, bracketed when the program asked for bracketed paste.","extra_description":"","search_terms":[],
    \\ "required_positional":[{"name":"text","desc":"the text","shape":"String"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int","Nothing"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty resize","description":"Give the terminal a new size; the program is told.","extra_description":"","search_terms":[],
    \\ "required_positional":[{"name":"cols","desc":"columns","shape":"Int"},{"name":"rows","desc":"rows","shape":"Int"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int","Nothing"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty mouse","description":"A mouse event at a cell of the active area, reported the way the program asked for mouse events, or not at all.","extra_description":"","search_terms":[],
    \\ "required_positional":[{"name":"kind","desc":"press, release or move","shape":"String"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"},
    \\  {"long":"button","short":null,"arg":"String","required":false,"desc":"left, middle, right, wheelup, wheeldown, wheelleft, wheelright"},
    \\  {"long":"x","short":null,"arg":"Int","required":false,"desc":"column, from 0"},
    \\  {"long":"y","short":null,"arg":"Int","required":false,"desc":"row of the active area, from 0"},
    \\  {"long":"mods","short":null,"arg":"Int","required":false,"desc":"1 shift, 2 alt, 4 ctrl, 8 meta"}],
    \\ "input_output_types":[["Int","Nothing"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty focus","description":"The page gained or lost focus; reported only when the program asked for focus reports.","extra_description":"","search_terms":[],
    \\ "required_positional":[{"name":"on","desc":"true when focused","shape":"Boolean"}],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int","Nothing"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty palette","description":"The terminal's colours, as the style block its HTML refers to.","extra_description":"","search_terms":[],
    \\ "required_positional":[],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int","String"]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]},
    \\{"sig":{"name":"ghostty info","description":"A terminal's size, row count, write count and whether its program runs.","extra_description":"","search_terms":[],
    \\ "required_positional":[],"optional_positional":[],"rest_positional":null,
    \\ "named":[{"long":"help","short":"h","arg":null,"required":false,"desc":"Display the help message for this command"}],
    \\ "input_output_types":[["Int",{"Record":[]}]],"allow_variants_without_examples":true,"is_filter":false,"creates_scope":false,"allows_unknown_args":false,"category":"Experimental"},"examples":[]}
    \\]}
;

fn handle(line: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const msg = std.json.parseFromSliceLeaky(V, arena.allocator(), line, .{}) catch return;
    if (msg == .string and std.mem.eql(u8, msg.string, "Goodbye")) c.exit(0);
    if (field(msg, "Drop")) |d| {
        if (d == .integer) dropStream(d.integer);
        return;
    }
    const call = field(msg, "Call") orelse return;
    if (call != .array or call.array.items.len < 2) return;
    const idv = call.array.items[0];
    if (idv != .integer) return;
    const id = idv.integer;
    const body = call.array.items[1];
    if (body == .string and std.mem.eql(u8, body.string, "Metadata")) {
        var j: J = .{};
        defer j.deinit();
        j.fmt("{{\"CallResponse\":[{d},{{\"Metadata\":{{\"version\":\"{s}\"}}}}]}}", .{ id, plugin_version });
        return send(j.buf.items);
    }
    if (body == .string and std.mem.eql(u8, body.string, "Signature")) {
        var j: J = .{};
        defer j.deinit();
        j.fmt("{{\"CallResponse\":[{d},", .{id});
        j.raw(signatures);
        j.raw("]}");
        return send(j.buf.items);
    }
    if (field(body, "Run")) |r| return run(id, r);
    respondError(id, "unsupported call", .{ .start = 0, .end = 0 });
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

/// Answer the engine's Hello, the first message it sends.
fn hello(line: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var version: []const u8 = nu_minors[0] ++ "0";
    if (std.json.parseFromSliceLeaky(V, arena.allocator(), line, .{})) |msg| {
        if (field(msg, "Hello")) |h| if (field(h, "version")) |v| if (v == .string) {
            for (nu_minors) |m| if (std.mem.startsWith(u8, v.string, m)) {
                version = v.string;
            };
        };
    } else |_| {}
    var j: J = .{};
    defer j.deinit();
    j.raw("{\"Hello\":{\"protocol\":\"nu-plugin\",\"version\":");
    j.str(version);
    j.raw(",\"features\":[]}}");
    send(j.buf.items);
    // The terminals live in this process, so nushell must not stop it when idle.
    send("{\"Option\":{\"GcDisabled\":true}}");
}

pub fn main() void {
    _ = c.pthread_mutex_init(&out_lock, null);
    _ = c.pthread_mutex_init(&terms_lock, null);
    // A program that exits mid-write must not kill the plugin: with a handler
    // in place, the write fails with EPIPE instead. (SIG_IGN is a cast macro
    // translate-c cannot carry.)
    _ = c.signal(c.SIGPIPE, &ignoreSignal);

    writeAll(1, "\x04json");

    var pending: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    var said_hello = false;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) break;
        pending.appendSlice(alloc, buf[0..@intCast(n)]) catch @panic("oom");
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            if (!said_hello) {
                hello(pending.items[0..nl]);
                said_hello = true;
            } else handle(pending.items[0..nl]);
            const rest = pending.items.len - nl - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[nl + 1 ..]);
            pending.shrinkRetainingCapacity(rest);
        }
    }
}
