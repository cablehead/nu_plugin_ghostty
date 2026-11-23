// nu_plugin_ghostty: a terminal kept in libghostty-vt, asked for rows like
// largediff asks for a window of a diff.
//
//   let t = ghostty spawn [bash -l] --cols 100 --rows 30
//   $t | ghostty input "ls\r"
//   $t | ghostty window 0 30 --fp $fp     # {fp, top, total, rows, cols, html} or {unchanged: true}
//   $t | ghostty changes                  # one record each time the program writes
//   $t | ghostty palette                  # the <style> block the HTML's colours refer to
//   $t | ghostty info
//
// Speaks nushell's plugin protocol, JSON encoding, over stdin and stdout.
// A handle is an int. A reader thread per terminal feeds the program's
// output into libghostty under that terminal's lock; every call reads under
// the same lock.

const std = @import("std");
const c = @import("c.zig");

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
        {
            _ = c.pthread_mutex_lock(&term.lock);
            defer _ = c.pthread_mutex_unlock(&term.lock);
            c.ghostty_terminal_vt_write(term.t, &buf, @intCast(n));
            term.seq += 1;
            seq = term.seq;
            subs = term.subs;
        }
        for (subs, 0..) |sid, i| {
            if (sid == 0) continue;
            var j: J = .{};
            defer j.deinit();
            const s = term.sub_span[i];
            j.fmt("{{\"Data\":[{d},{{\"List\":{{\"Record\":{{\"val\":{{\"seq\":", .{sid});
            intV(&j, seq, s);
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
fn windowHtml(term: *Term, top_in: i64, height_in: i64, out_top: *i64, out_total: *i64) ![]u8 {
    _ = c.pthread_mutex_lock(&term.lock);
    defer _ = c.pthread_mutex_unlock(&term.lock);
    var total: usize = 0;
    _ = c.ghostty_terminal_get(term.t, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total);
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
        const html = windowHtml(term, top, height, &out_top, &total) catch |e| return respondError(id, @errorName(e), s);
        defer alloc.free(html);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(html);
        var tb: [16]u8 = undefined;
        std.mem.writeInt(i64, tb[0..8], out_top, .little);
        std.mem.writeInt(i64, tb[8..16], total, .little);
        hasher.update(&tb);
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
