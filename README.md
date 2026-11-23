# nu_plugin_ghostty

A nushell plugin that runs a program in a terminal kept by
[libghostty-vt](https://github.com/ghostty-org/ghostty), and answers for any
rows of it as HTML, scrollback included. A page holds only the rows in view and
asks for the rows at its scroll position, the way largediff-go-brr asks for a
window of a diff.

```nu
let t = ghostty spawn [bash -l] --cols 100 --rows 30
$t | ghostty input "ls\r"
$t | ghostty window 1200 30            # {fp, top, total, rows, cols, links, html}
$t | ghostty window 1200 30 --fp $fp   # {unchanged: true} when it is
$t | ghostty changes                   # a stream, one {seq, alive} each time the program writes, a last one with its exit code
$t | ghostty key ArrowUp --mods 4      # a browser key, encoded as the program asked
$t | ghostty paste "two\nlines"        # bracketed when the program asked
$t | ghostty resize 120 40
$t | ghostty mouse press --button left --x 4 --y 2   # reported when the program asked
$t | ghostty focus true                # reported when the program asked
$t | ghostty palette                   # the <style> block the HTML's colours refer to
$t | ghostty info                      # {total, rows, cols, seq, alive}, and code once it has ended
$t | ghostty close                     # end its program and free it; its handle is never reused
ghostty changes --all                  # every terminal on one stream, later ones too, each tick with its `term`
```

`static/ghostty-term.js` is `<ghostty-term src="/term">`, a Datastar Rocket
element modelled on ptyZZZ's `<pty-term>`: keys, composed text and paste go to
`{src}/input`, it fits the terminal to its box, and it follows the live output
until you scroll away. It holds the rows in view plus a screenful either side
and asks `{src}/win` for the rows at its scroll position. Only the last `rows`
rows of a terminal can change, so while you are scrolled back into history it
asks for nothing; the `{src}/live` ticks only lengthen the scrollbar. Its
scroll area is squeezed as largediff-go-brr's `/anchor/` is: at most `cap`
pixels (12,000,000 by default), the rows it holds at their real height and the
gaps around them squeezed. Mouse and focus reports reach the program only when
it asked for them, and Shift keeps native selection.

Web addresses in the rows are links. `ghostty window` finds them in the
terminal's text, joining the rows a long address wraps across, as WezTerm and
ptyZZZ do, and matching with Ghostty's own scheme rule (`src/config/url.zig`),
so a bracketed part such as `Rust_(video_game)` stays in and a sentence's full
stop stays out. Each is `{row, from, to, url}`: a row of the window, and a
range of that row's text, one for each row the address spans. Only http, https
and mailto become links, the ones the program sent with OSC 8 included, and
they open in a new tab.

`demo/panes.nu` is many terminals on one page, after ptyZZZ's `examples/panes`: columns of panes you open, split and close while the page is up, and every open page follows. One connection carries them all: `/sse` follows `ghostty changes --all` and names each tick's pane, and the page hands it to that pane's `<ghostty-term pane="...">`. The layout and each pane's terminal handle are kept in the store, so a restart spawns every pane again.

```sh
http-nu --datastar-rocket --store ./store --plugin ./nu_plugin_ghostty 127.0.0.1:3015 demo/panes.nu
```

`demo/term.nu` serves one terminal with it:

```sh
http-nu --datastar-rocket --plugin ./nu_plugin_ghostty 127.0.0.1:3012 demo/term.nu
```

Row 0 is the oldest line kept. `--scrollback` sets how many lines are kept,
10,000 by default.

`demo/serve.nu` is a page for http-nu that scrolls through 3,000 coloured lines:

```sh
http-nu --datastar --plugin ./nu_plugin_ghostty 127.0.0.1:3011 demo/serve.nu
```

Build with `./build.sh`; `./gen-keys.sh` regenerates `keys.zig` for a new libghostty-vt. It needs Zig 0.17.1 and the libghostty-vt 1.0.1
XCFramework, so it builds on macOS only for now. The plugin answers nushell
0.116 and 0.117.
