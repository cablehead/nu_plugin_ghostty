#!/bin/sh
# Builds nu_plugin_ghostty on macOS with Zig 0.17.1 and libghostty-vt 1.0.1.
#
#   VT=<dir>/ghostty-vt.xcframework/macos-arm64_x86_64 ZIG=<dir>/zig ./build.sh
#
# The XCFramework is ghostty-vt-1.0.1.xcframework.zip from
# https://release.files.ghostty.org/libghostty-vt/1.0.1/
set -eu
cd "$(dirname "$0")"
ZIG=${ZIG:-zig}
VT=${VT:?set VT to the XCFramework macos-arm64_x86_64 directory}
# Zig 0.17 has no @cImport: the C headers become c.zig here.
"$ZIG" translate-c -lc -I "$VT/Headers" cdeps.h > c.zig
"$ZIG" build-exe main.zig -lc "$VT/libghostty-vt.a" -O ReleaseSafe -femit-bin=nu_plugin_ghostty
