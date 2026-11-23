# Terminals that come and go, on one stream: the <ghostty-term> element in
# static/, many of them, after ptyZZZ's examples/panes. Columns of panes you
# can open, split and close while the page is up; every open page follows.
#
#   http-nu --datastar-rocket --store ./store --plugin ./nu_plugin_ghostty 127.0.0.1:3015 demo/panes.nu
#
# The layout lives in the store, with each pane's terminal handle beside it.
# The terminals live in the plugin, so a restart spawns every pane again.
# GHX_PANE_CMD is what each pane runs (default: nu).
#
# One connection carries every terminal: /sse follows `ghostty changes --all`,
# which hears terminals spawned after it opened too, and names each tick's
# pane. The page hands each tick to its pane's element. A tick from a pane the
# page doesn't show, or the last tick of a pane it does, means the layout
# moved: the page fetches /strip again. So a pane opened or closed in one
# window appears or goes in every other.
#
# Keys, as ptyZZZ's panes: navigate mode by default, h/l between columns, j/k
# between panes, n a new column, s split, Enter types into the pane. Cmd+Enter
# (Ctrl+Enter off macOS) goes back to navigate. Cmd+K then x closes a pane.

use http-nu/datastar *

const STATIC = path self ../static
const PAGE_JS = path self panes.js
let pane_cmd = ($env.GHX_PANE_CMD? | default "nu" | split row " ")

def layout [] {
  let f = .last "panes.layout"
  if $f == null { {columns: []} } else { $f.meta }
}

def save-layout [l: record] {
  null | .append "panes.layout" --ttl last:1 --meta $l | ignore
}

def next-n [] {
  let f = .last "panes.seq"
  let n = (if $f == null { 0 } else { $f.meta.n }) + 1
  null | .append "panes.seq" --ttl last:1 --meta {n: $n} | ignore
  $n
}

# A pane's terminal: spawned, and its handle kept beside the layout.
def spawn-pane [pid: string] {
  let h = (ghostty spawn $pane_cmd --cols 100 --rows 30)
  null | .append $"pane-($pid).term" --ttl last:1 --meta {h: $h} | ignore
  $h
}

def handle-of [pid: string] {
  let f = .last $"pane-($pid).term"
  if $f == null { null } else { $f.meta.h }
}

# Which pane each terminal handle is, for the panes in the layout.
def pane-map [] {
  layout | get columns | each {|c| $c.panes } | flatten
  | reduce --fold {} {|pid, acc| let h = (handle-of $pid); if $h == null { $acc } else { $acc | insert ($h | into string) $pid } }
}

def all-panes [l: record] { $l.columns | each {|c| $c.panes } | flatten }

# At start: one pane if there are none, else every pane spawned again, as
# the plugin's terminals did not survive the restart.
def ensure-panes [] {
  let l = layout
  if ($l.columns | is-empty) {
    let n = (next-n)
    spawn-pane $"p($n)" | ignore
    save-layout {columns: [{id: $"c($n)", panes: [$"p($n)"]}]}
  } else {
    all-panes $l | each {|pid| spawn-pane $pid } | ignore
  }
}

ensure-panes

def pane-html [pid: string] {
  $"<div class=\"pane\" id=\"pane-($pid)\" data-pane=\"($pid)\"><div class=\"label\"><span class=\"name\">($pid)</span></div><ghostty-term src=\"/t/($pid)\" pane=\"($pid)\"></ghostty-term></div>"
}

def strip-html [] {
  let cols = layout | get columns | each {|c|
    $"<div class=\"column\" id=\"col-($c.id)\">($c.panes | each {|p| pane-html $p } | str join '')</div>"
  } | str join ""
  $"<div id=\"strip\">($cols)</div>"
}

def page [palette: string] {
  let imports = {imports: {datastar: $DATASTAR_ROCKET_JS_PATH}} | to json -r
  $"<!doctype html>
<html><head><meta charset=utf-8><title>ghostty-term panes</title>
($palette)
<link rel=stylesheet href=\"/static/ghostty-term.css\">
<script type=importmap>($imports)</script>
<script type=module src=\"($DATASTAR_ROCKET_JS_PATH)\"></script>
<script type=module src=\"/static/ghostty-term.js\"></script>
<style>
html, body { margin: 0; height: 100%; background: #1d1f21; color: #c5c8c6; font: 13px system-ui, sans-serif; }
body { display: flex; flex-direction: column; }
#bar { display: flex; gap: 12px; align-items: center; padding: 6px 12px; color: #8a8f98; }
#bar .mode { color: #c5c8c6; }
#strip { flex: 1; min-height: 0; display: flex; gap: 8px; padding: 0 8px 8px; overflow-x: auto; }
.column { flex: 1 0 min\(100ch, 100%\); display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.pane { flex: 1; min-height: 0; display: flex; flex-direction: column; border: 2px solid #2c2f33; border-radius: 6px; }
.pane.selected { border-color: #5f819d; }
body.focus .pane.selected { border-color: #8abeb7; }
.pane .label { padding: 2px 8px; color: #8a8f98; }
.pane ghostty-term { flex: 1; min-height: 0; margin: 4px 8px 8px; }
.pane ghostty-term:focus-within { outline: none; }
#panel { position: fixed; bottom: 12px; right: 12px; padding: 8px 12px; background: #2c2f33; border-radius: 6px; }
</style>
</head><body>
<div id=\"bar\"><span class=\"mode\">navigate</span><span>h/l j/k move · n new column · s split · Enter type · Cmd+Enter back · Cmd+K x close</span></div>
(strip-html)
<div id=\"panel\" hidden>x close this pane</div>
<script type=module src=\"/panes.js\"></script>
</body></html>"
}

def json-resp [] { to json -r | metadata set { merge {'http.response': {headers: {content-type: "application/json"}}} } }
def status [code: int] { metadata set { merge {'http.response': {status: $code}} } }

{|req|
  let body = $in
  let parts = $req.path | split row "/" | where {|p| $p != "" }
  match $parts {
    [] => { page ((all-panes (layout) | get 0 | handle-of $in) | ghostty palette) }
    ["strip"] => { strip-html }
    ["panes.js"] => { open --raw $PAGE_JS | metadata set { merge {'http.response': {headers: {content-type: "text/javascript"}}} } }
    ["sse"] => {
      # Every terminal's ticks, each named for its pane. A handle the map
      # doesn't know (a pane opened since) reloads it from the store.
      ghostty changes --all
      | generate {|t, m = {}|
        let key = $t.term | into string
        let m = if $key in $m { $m } else { pane-map }
        let pid = $m | get -o $key
        if $pid == null { {next: $m} } else {
          {out: {event: "tick", data: ($t | reject term | insert pane $pid | to json -r)}, next: $m}
        }
      }
      | to sse
    }
    ["pane" "new-column"] => {
      let l = layout
      let n = (next-n)
      let col = {id: $"c($n)", panes: [$"p($n)"]}
      let at = $l.columns | enumerate | where {|c| $req.query.after? in $c.item.panes } | get -o 0.index
      let cols = if $at == null { $l.columns | append $col } else { ($l.columns | take ($at + 1)) | append $col | append ($l.columns | skip ($at + 1)) }
      # The layout first, then the terminal: its first tick finds the pane.
      save-layout {columns: $cols}
      spawn-pane $"p($n)" | ignore
      {pane: $"p($n)"} | json-resp
    }
    ["pane" "split"] => {
      let l = layout
      let n = (next-n)
      let pid = $"p($n)"
      let cols = $l.columns | each {|c|
        if ($req.query.pane? in $c.panes) {
          let i = $c.panes | enumerate | where item == $req.query.pane | get 0.index
          $c | update panes (($c.panes | take ($i + 1)) | append $pid | append ($c.panes | skip ($i + 1)))
        } else { $c }
      }
      save-layout {columns: $cols}
      spawn-pane $pid | ignore
      {pane: $pid} | json-resp
    }
    ["pane" "close"] => {
      let pid = $req.query.pane? | default ""
      let l = layout
      let cols = $l.columns | each {|c| $c | update panes ($c.panes | where {|p| $p != $pid }) } | where {|c| $c.panes | is-not-empty }
      save-layout {columns: $cols}
      let h = (handle-of $pid)
      # The layout first: the terminal's last tick then tells every page
      # the pane has gone.
      if $h != null { try { $h | ghostty close } }
      null | .append $"pane-($pid).term" --ttl last:1 --meta {h: null} | ignore
      {closed: $pid} | json-resp
    }
    ["t" $pid "win"] => {
      let h = (handle-of $pid)
      if $h == null { "no such pane" | status 404 } else {
        let q = $req.query
        $h | ghostty window ($q.top? | default 0 | into int) ($q.h? | default 30 | into int) --fp ($q.fp? | default "") | json-resp
      }
    }
    ["t" $pid "input"] => {
      let h = (handle-of $pid)
      if $h == null { "no such pane" | status 404 } else {
        $body | into string | lines | where {|l| $l != "" } | each {|l|
          let f = ($l | from json)
          match $f.t {
            "key" => { $h | ghostty key $f.code --text ($f.key? | default "") --mods ($f.mods? | default 0) }
            "text" => { $h | ghostty input $f.s }
            "paste" => { $h | ghostty paste $f.s }
            "resize" => { $h | ghostty resize $f.cols $f.rows }
            "mouse" => { $h | ghostty mouse $f.kind --button ($f.button? | default "") --x $f.x --y $f.y --mods ($f.mods? | default 0) }
            "focus" => { $h | ghostty focus $f.on }
            _ => null
          }
        } | ignore
        "" | status 204
      }
    }
    _ => {
      if ($req.path | str starts-with "/static/") {
        # /static/<file> and /static/fonts/<file>, nothing above static/
        let rel = $req.path | str replace '/static/' '' | path split | where {|p| $p != ".." }
        let f = ($STATIC | path join ...$rel)
        if ($f | path exists) {
          let ct = if ($f | str ends-with ".js") { "text/javascript" } else if ($f | str ends-with ".css") { "text/css" } else if ($f | str ends-with ".woff2") { "font/woff2" } else { "application/octet-stream" }
          open --raw $f | metadata set { merge {'http.response': {headers: {content-type: $ct}}} }
        } else { "not found" | status 404 }
      } else { "not found" | status 404 }
    }
  }
}
