#!/bin/sh
# Regenerates keys.zig from libghostty's key header, for a new libghostty-vt.
#   VT=<dir>/ghostty-vt.xcframework/macos-arm64_x86_64 ./gen-keys.sh
set -eu
cd "$(dirname "$0")"
H="$VT/Headers/ghostty/vt/key/event.h"
{
  echo "// The browser's KeyboardEvent.code names, as libghostty's GHOSTTY_KEY_* values."
  echo "// Generated from ghostty/vt/key/event.h by gen-keys.sh."
  echo 'const c = @import("c.zig");'
  echo 'pub const Key = struct { name: []const u8, key: c.GhosttyKey };'
  echo 'pub const all = [_]Key{'
  grep -o "GHOSTTY_KEY_[A-Z0-9_]*" "$H" | sort -u | grep -v -E "ACTION|MAX_VALUE|UNIDENTIFIED$" \
    | sed 's/GHOSTTY_KEY_\(.*\)/    .{ .name = "\1", .key = c.GHOSTTY_KEY_\1 },/'
  echo '};'
} > keys.zig
