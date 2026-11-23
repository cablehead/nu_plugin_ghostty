# nu_plugin_ghostty

A nushell plugin that runs a program in a terminal kept by
[libghostty-vt](https://github.com/ghostty-org/ghostty), and answers for any
rows of it as HTML, scrollback included. A page holds only the rows in view and
asks for the rows at its scroll position, the way largediff-go-brr asks for a
window of a diff.

```nu
let t = ghostty spawn [bash -l] --cols 100 --rows 30
$t | ghostty input "ls\r"
$t | ghostty window 1200 30            # {fp, top, total, rows, cols, html}
$t | ghostty window 1200 30 --fp $fp   # {unchanged: true} when it is
$t | ghostty changes                   # a stream, one {seq} each time the program writes
$t | ghostty palette                   # the <style> block the HTML's colours refer to
$t | ghostty info                      # {total, rows, cols, seq, alive}
```

Row 0 is the oldest line kept. `--scrollback` sets how many lines are kept,
10,000 by default.

`demo/serve.nu` is a page for http-nu that scrolls through 3,000 coloured lines:

```sh
http-nu --datastar --plugin ./nu_plugin_ghostty 127.0.0.1:3011 demo/serve.nu
```

Build with `./build.sh`; it needs Zig 0.17.1 and the libghostty-vt 1.0.1
XCFramework, so it builds on macOS only for now. The plugin answers nushell
0.116 and 0.117.
