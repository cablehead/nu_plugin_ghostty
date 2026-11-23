# A terminal in a page, scrolled like largediff: the page holds only the rows in
# view, and asks for the rows at its scroll position.
#
#   http-nu --datastar --plugin <dir>/nu_plugin_ghostty :3011 serve.nu
#
# /live is one long-lived SSE that says only "the screen moved" (a seq). The page
# answers each tick, and each scroll, with GET /win, carrying its top row and the
# fp of the window it holds; /win sends back that window's rows, or nothing.

use http-nu/datastar *

const ROW = 18     # px per row; the CSS below sets the same line-height
const HEIGHT = 30  # rows in view

let cmd = ($env.GHX_CMD? | default 'for i in $(seq 1 3000); do printf "\033[3%dmline %d\033[0m of the scrollback\n" $((i % 7 + 1)) $i; done; exec bash --norc --noprofile')
let t = (ghostty spawn [bash -c $cmd] --cols 100 --rows $HEIGHT)

def page [palette: string] {
  let signals = {top: 0, fp: "", total: 0, seq: 0, follow: true} | to json -r
  $"<!doctype html>
<html><head><meta charset=utf-8><title>ghostty window</title>
($palette)
<style>
body { margin: 0; background: #1d1f21; color: #c5c8c6; font: 14px/($ROW)px ui-monospace, monospace; }
#scroller { height: ($HEIGHT * $ROW)px; overflow-y: auto; position: relative; margin: 16px; }
#win { position: absolute; left: 0; right: 0; }
#win > div { line-height: ($ROW)px; }
#bar { margin: 0 16px; color: #969896; }
</style>
<script type=module src=\"($DATASTAR_JS_PATH)\"></script>
</head>
<body data-signals='($signals)' data-init=\"@get\('/live', {openWhenHidden: true, requestCancellation: 'none'}\)\">
<div id=bar>rows <span data-text=\"$top\"></span> to <span data-text=\"$top + ($HEIGHT)\"></span> of <span data-text=\"$total\"></span>, <span data-text=\"$follow ? 'following' : 'scrolled back'\"></span></div>
<div id=scroller data-ref:scroller
  data-on:scroll__throttle.32ms.trailing=\"$top = Math.floor\(el.scrollTop / ($ROW)\); $follow = el.scrollTop + el.clientHeight >= el.scrollHeight - ($ROW); @get\('/win'\)\"
  data-effect=\"$seq; @get\('/win'\)\">
<div id=spacer data-style:height=\"\($total * ($ROW)\) + 'px'\"></div>
<div id=win></div>
</div>
</body></html>"
}

{|req|
  match $req.path {
    "/" => { page ($t | ghostty palette) }
    "/live" => {
      $t | ghostty changes | each {|c| {seq: $c.seq} | to datastar-patch-signals } | to sse
    }
    "/win" => {
      let s = ("" | from datastar-signals $req)
      let info = ($t | ghostty info)
      # following: the window is the last screenful, wherever the page thinks it is
      let top = if ($s.follow? | default true) { [($info.total - $HEIGHT) 0] | math max } else { $s.top? | default 0 }
      let w = ($t | ghostty window $top $HEIGHT --fp ($s.fp? | default ""))
      if ($w.unchanged? | default false) {
        [] | to sse
      } else {
        let events = [
          ($"<div id=win style=\"top: ($w.top * $ROW)px\">($w.html)</div>" | to datastar-patch-elements)
          ({fp: $w.fp, total: $w.total} | to datastar-patch-signals)
        ]
        # following: keep the page's scroll at the bottom as rows arrive
        let follow = if ($s.follow? | default true) {
          [($"document.getElementById\('scroller'\).scrollTop = ($top * $ROW)" | to datastar-execute-script)]
        } else { [] }
        $events | append $follow | to sse
      }
    }
    _ => { "not found" | metadata set { merge {'http.response': {status: 404}} } }
  }
}
