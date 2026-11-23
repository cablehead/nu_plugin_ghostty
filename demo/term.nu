# A terminal in a page, with a keyboard: the <ghostty-term> element in
# static/, on the plugin. The page holds only the rows in view.
#
#   http-nu --datastar-rocket --plugin ./nu_plugin_ghostty 127.0.0.1:3012 demo/term.nu
#
# GHX_CMD is what runs; by default 3,000 coloured lines, then a shell.

use http-nu/datastar *

const STATIC = path self ../static

let cmd = ($env.GHX_CMD? | default 'for i in $(seq 1 3000); do printf "\033[3%dmline %d\033[0m of the scrollback\n" $((i % 7 + 1)) $i; done; PS1="ghostty$ " exec bash --norc --noprofile -i')
let t = (ghostty spawn [bash -c $cmd] --cols 100 --rows 30)

def page [palette: string] {
  let imports = {imports: {datastar: $DATASTAR_ROCKET_JS_PATH}} | to json -r
  $"<!doctype html>
<html><head><meta charset=utf-8><title>ghostty-term</title>
($palette)
<link rel=stylesheet href=\"/static/ghostty-term.css\">
<script type=importmap>($imports)</script>
<script type=module src=\"($DATASTAR_ROCKET_JS_PATH)\"></script>
<script type=module src=\"/static/ghostty-term.js\"></script>
<style>
html, body { margin: 0; height: 100%; background: #1d1f21; }
body { display: flex; flex-direction: column; }
ghostty-term { flex: 1; margin: 12px; min-height: 0; }
</style>
</head><body>
<ghostty-term src=\"/term\"></ghostty-term>
</body></html>"
}

def json-resp [] { to json -r | metadata set { merge {'http.response': {headers: {content-type: "application/json"}}} } }

{|req|
  let body = $in
  match $req.path {
    "/" => { page ($t | ghostty palette) }
    "/term/live" => {
      $t | ghostty changes | each {|c| {event: "tick", data: ($c | to json -r)} } | to sse
    }
    "/term/win" => {
      let q = $req.query
      $t | ghostty window ($q.top? | default 0 | into int) ($q.h? | default 30 | into int) --fp ($q.fp? | default "") | json-resp
    }
    "/term/input" => {
      $body | into string | lines | where {|l| $l != "" } | each {|l|
        let f = ($l | from json)
        match $f.t {
          "key" => { $t | ghostty key $f.code --text ($f.key? | default "") --mods ($f.mods? | default 0) }
          "text" => { $t | ghostty input $f.s }
          "paste" => { $t | ghostty paste $f.s }
          "resize" => { $t | ghostty resize $f.cols $f.rows }
          _ => null
        }
      } | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    }
    _ => {
      if ($req.path | str starts-with "/static/") {
        let f = ($STATIC | path join ($req.path | path basename))
        if ($f | path exists) {
          let ct = if ($f | str ends-with ".js") { "text/javascript" } else if ($f | str ends-with ".css") { "text/css" } else { "application/octet-stream" }
          open --raw $f | metadata set { merge {'http.response': {headers: {content-type: $ct}}} }
        } else { "not found" | metadata set { merge {'http.response': {status: 404}} } }
      } else { "not found" | metadata set { merge {'http.response': {status: 404}} } }
    }
  }
}
