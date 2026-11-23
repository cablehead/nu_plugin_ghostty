# Terminals that come and go, on one stream: the <ghostty-term> element in
# static/, many of them, after ptyZZZ's examples/panes. Columns of panes you
# can open, split and close while the page is up; every open page follows.
#
#   http-nu --datastar-rocket --store ./store --plugin ./nu_plugin_ghostty 127.0.0.1:3015 demo/panes.nu
#
# The layout lives in the store, with each pane's terminal handle beside it.
# The terminals live in the plugin, so a restart spawns every pane again.
# Each pane runs nu if it is on PATH, else the default shell ($SHELL);
# GHX_PANE_CMD overrides both.
#
# One connection carries every terminal: /sse follows `ghostty changes --all`,
# which hears terminals spawned after it opened too, and names each tick's
# pane. The page hands each tick to its pane's element. A tick from a pane the
# page doesn't show, or the last tick of a pane it does, means the layout
# moved: the page fetches /strip again. So a pane opened or closed in one
# window appears or goes in every other.
#
# Keys and the Cmd+K panel are ptyZZZ's panes (examples/panes/static/panes.js):
# navigate mode by default, h/l between columns, j/k between panes, n a new
# column, s split, f zoom, Enter types into the pane, Cmd+Enter (Ctrl+Enter
# off macOS) back to navigate. Cmd+K shows the panel after a moment, with
# every action and its key; close is only there, Cmd+K x. The strip slides
# the selected column into view.

use http-nu/datastar *
use http-nu/html *

const STATIC = path self ../static
const PAGE_JS = path self panes.js
const PAGE_CSS = path self panes.css
# What each pane runs: GHX_PANE_CMD if set, else nu if it is on PATH, else
# the login shell ($SHELL), else /bin/sh.
let pane_cmd = if ($env.GHX_PANE_CMD? | is-not-empty) { $env.GHX_PANE_CMD | split row " " } else if (which nu | is-not-empty) { [nu] } else { [($env.SHELL? | default "/bin/sh")] }

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

# The jump-to-the-bottom arrow, shown on a pane while it isn't following.
const ARROW_ICON = "lucide:arrow-down"
let ARROW = ICONIFY $ARROW_ICON {width: "18" height: "18"} | get __html

def pane-html [pid: string] {
  $"<div class=\"pane\" id=\"pane-($pid)\" data-pane=\"($pid)\"><div class=\"label\"><span class=\"name\">($pid)</span><span class=\"status\"><span class=\"tag zoomtag\">[zoom]</span></span></div><div class=\"body\"><ghostty-term src=\"/t/($pid)\" pane=\"($pid)\"></ghostty-term><button type=\"button\" class=\"follow\" title=\"Jump to the bottom and follow the output\" aria-label=\"Jump to the bottom\">($ARROW)</button></div></div>"
}

def strip-html [] {
  let cols = layout | get columns | each {|c|
    $"<div class=\"column\" id=\"col-($c.id)\">($c.panes | each {|p| pane-html $p } | str join '')</div>"
  } | str join ""
  $"<div id=\"strip\">($cols)</div>"
}

# The page: ptyZZZ's panes page (templates/page.html, panel.html,
# static/panes.css), with <ghostty-term> in place of <pty-term> and a plain
# EventSource for the one stream.
def page [palette: string] {
  let imports = {imports: {datastar: $DATASTAR_ROCKET_JS_PATH}} | to json -r
  let row = {|key, act, label| $"<button type=\"button\" class=\"picker-row\" data-key=\"($key)\" data-act=\"($act)\"><span>($label)</span><span class=\"row-keys\"><kbd>($key)</kbd></span></button>" }
  let panel = [
    (do $row n new-column "New column") (do $row s split "Split column") (do $row f zoom "Zoom pane")
    (do $row h col-prev "Prev column") (do $row l col-next "Next column") (do $row k pane-prev "Prev pane")
    (do $row j pane-next "Next pane") (do $row x close "Close")
  ] | str join ""
  $"<!doctype html>
<html><head><meta charset=utf-8><title>ghostty-term panes</title>
($palette)
<link rel=stylesheet href=\"/static/ghostty-term.css\">
(SCRIPT-ICONIFY | get __html)
<link rel=stylesheet href=\"/panes.css\">
<script type=importmap>($imports)</script>
<script type=module src=\"($DATASTAR_ROCKET_JS_PATH)\"></script>
<script type=module src=\"/static/ghostty-term.js\"></script>
</head><body>
(strip-html)
<div id=\"empty\" hidden>mod+K n to open a pane</div>
<div id=\"status\"><button type=\"button\" id=\"mode-badge\">navigate</button><span id=\"link\">--</span><span class=\"hint\">mod+K</span></div>
<div id=\"actions-backdrop\" class=\"actions-backdrop\" hidden><div class=\"actions-panel\" id=\"actions-panel\"><div class=\"picker-heading\">Pane</div>($panel)</div></div>
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
    ["panes.css"] => { open --raw $PAGE_CSS | metadata set { merge {'http.response': {headers: {content-type: "text/css"}}} } }
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
