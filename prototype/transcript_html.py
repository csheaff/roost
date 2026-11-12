#!/usr/bin/env python3
"""Turn a Claude Code session log (JSONL) into one HTML page to read.

A throwaway prototype: each turn is your prompt and the agent's last reply,
with the steps between folded into one line and the turn's screenshots as
thumbnails. Standard library only; the Markdown reader is small and covers
what agents usually write.

    transcript_html.py SESSION.jsonl OUT.html
"""

import html
import json
import re
import sys

NOISE = re.compile(r"<(system-reminder|ide_[a-z_]+|local-command-[a-z]+|command-[a-z]+|"
                   r"task-notification|user-prompt-submit-hook)[^>]*>.*?</\1>", re.S)


def esc(text):
    return html.escape(text, quote=True)


# Markdown -------------------------------------------------------------

def inline(text):
    """TEXT's inline Markdown as HTML: code, links, bold, italics."""
    spans = []

    def keep(match):
        spans.append("<code>%s</code>" % esc(match.group(1)))
        return "\x00%d\x00" % (len(spans) - 1)

    part = esc(re.sub(r"`([^`\n]+)`", keep, text))
    part = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)",
                  lambda m: '<a href="%s">%s</a>' % (m.group(2), m.group(1))
                  if re.match(r"https?://", m.group(2)) else "<span class=path>%s</span>" % m.group(1),
                  part)
    part = re.sub(r"(?<![\"=\w/])(https?://[^\s<)]+)", r'<a href="\1">\1</a>', part)
    part = re.sub(r"\*\*([^*\n]+)\*\*", r"<strong>\1</strong>", part)
    part = re.sub(r"(?<![\w*])\*([^*\s][^*\n]*)\*(?!\w)", r"<em>\1</em>", part)
    part = re.sub(r"(?<![\w_])_([^_\s][^_\n]*)_(?!\w)", r"<em>\1</em>", part)
    return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], part)


def cells(line):
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


LIST = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")


def markdown(text):
    """TEXT's Markdown as HTML: headings, lists, fences, tables, quotes."""
    lines = text.replace("\r\n", "\n").split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        fence = re.match(r"^\s*(```+|~~~+)\s*([\w+-]*)", line)
        if fence:
            body, i = [], i + 1
            while i < len(lines) and not lines[i].strip().startswith(fence.group(1)):
                body.append(lines[i])
                i += 1
            i += 1
            out.append('<pre><code>%s</code></pre>' % esc("\n".join(body)))
        elif not line.strip():
            i += 1
        elif re.match(r"^#{1,6}\s", line):
            level = len(line) - len(line.lstrip("#"))
            out.append("<h%d>%s</h%d>" % (level + 1, inline(line[level:].strip()), level + 1))
            i += 1
        elif re.match(r"^\s*([-*_])\s*(\1\s*){2,}$", line):
            out.append("<hr>")
            i += 1
        elif "|" in line and i + 1 < len(lines) and re.match(r"^\s*\|?[\s:|-]*-[\s:|-]*$", lines[i + 1]):
            head, rows, i = cells(line), [], i + 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                rows.append(cells(lines[i]))
                i += 1
            out.append("<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>" % (
                "".join("<th>%s</th>" % inline(c) for c in head),
                "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % inline(c) for c in row) for row in rows)))
        elif line.lstrip().startswith(">"):
            body = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                body.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append("<blockquote>%s</blockquote>" % markdown("\n".join(body)))
        elif LIST.match(line):
            i = bullets(lines, i, out)
        else:
            body = []
            while (i < len(lines) and lines[i].strip() and not LIST.match(lines[i])
                   and not re.match(r"^\s*(```|~~~|#{1,6}\s|>)", lines[i])):
                body.append(lines[i].strip())
                i += 1
            out.append("<p>%s</p>" % inline(" ".join(body)))
    return "\n".join(out)


def bullets(lines, i, out):
    """Read the list starting at LINES[I] into OUT; return the line after it."""
    first = LIST.match(lines[i])
    indent, tag = len(first.group(1)), "ol" if first.group(2)[0].isdigit() else "ul"
    out.append("<%s>" % tag)
    while i < len(lines):
        item = LIST.match(lines[i])
        if not item or len(item.group(1)) < indent:
            break
        if len(item.group(1)) > indent:
            i = bullets(lines, i, out)
            continue
        text, i = [item.group(3)], i + 1
        while (i < len(lines) and lines[i].strip() and not LIST.match(lines[i])
               and not re.match(r"^\s*(```|~~~)", lines[i])):
            text.append(lines[i].strip())
            i += 1
        out.append("<li>%s" % inline(" ".join(text)))
        while i < len(lines) and not lines[i].strip():
            i += 1
        deeper = LIST.match(lines[i]) if i < len(lines) else None
        if deeper and len(deeper.group(1)) > indent:
            i = bullets(lines, i, out)
        out.append("</li>")
    out.append("</%s>" % tag)
    return i


# The session log -------------------------------------------------------

def tool_line(block):
    """One line saying what a tool call did."""
    data = block.get("input") or {}
    name = block.get("name", "tool")
    for key in ("description", "file_path", "command", "pattern", "query", "url", "prompt", "skill"):
        if isinstance(data.get(key), str) and data[key].strip():
            detail = data[key].strip().split("\n")[0]
            return name, detail[:140] + ("…" if len(detail) > 140 else "")
    return name, ""


def turns(path):
    """The session at PATH as turns: dicts of prompt, steps, images, reply."""
    found, turn = [], None
    with open(path, errors="replace") as lines:
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") not in ("user", "assistant") or entry.get("isSidechain") or entry.get("isMeta"):
                continue
            content = (entry.get("message") or {}).get("content")
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            if not isinstance(content, list):
                continue
            for block in content:
                kind = block.get("type")
                if entry["type"] == "user" and kind == "text":
                    text = NOISE.sub("", block.get("text", "")).strip()
                    if not text or entry.get("isCompactSummary"):
                        continue
                    event = re.match(r"<([a-z][a-z-]*)>", text)
                    if event:
                        turn = dict(prompt=text, steps=[], images=[], event=event.group(1))
                        found.append(turn)
                    elif turn and not turn["steps"] and not turn["images"] and not turn.get("event"):
                        turn["prompt"] += "\n\n" + text
                    else:
                        turn = dict(prompt=text, steps=[], images=[])
                        found.append(turn)
                elif turn is None:
                    continue
                elif entry["type"] == "user" and kind == "image":
                    turn.setdefault("attached", []).append(block.get("source") or {})
                elif kind == "text" and block.get("text", "").strip():
                    turn["steps"].append(("text", block["text"].strip()))
                elif kind == "tool_use" and block.get("name", "").endswith("show_widget"):
                    code = (block.get("input") or {}).get("widget_code")
                    if isinstance(code, str) and code.strip():
                        turn.setdefault("widgets", []).append(code)
                    turn["steps"].append(("tool", "Widget", (block.get("input") or {}).get("title", "")))
                elif kind == "tool_use":
                    turn["steps"].append(("tool",) + tool_line(block))
                elif kind == "tool_result" and isinstance(block.get("content"), list):
                    for part in block["content"]:
                        if part.get("type") == "image" and (part.get("source") or {}).get("type") == "base64":
                            turn["images"].append(part["source"])
    for turn in found:
        texts = [n for n, step in enumerate(turn["steps"]) if step[0] == "text"]
        turn["reply"] = turn["steps"].pop(texts[-1])[1] if texts else None
    return found


RAMPS = dict(purple="EEEDFE 534AB7 3C3489 CECBF6 AFA9EC", teal="E1F5EE 0F6E56 085041 9FE1CB 5DCAA5",
             coral="FAECE7 993C1D 712B13 F5C4B3 F0997B", pink="FBEAF0 993556 72243E F4C0D1 ED93B1",
             gray="F1EFE8 5F5E5A 444441 D3D1C7 B4B2A9", blue="E6F1FB 185FA5 0C447C B5D4F4 85B7EB",
             green="EAF3DE 3B6D11 27500A C0DD97 97C459", amber="FAEEDA 854F0B 633806 FAC775 EF9F27",
             red="FCEBEB A32D2D 791F1F F7C1C1 F09595")


def ramp_css():
    """Rules for the colour classes a widget may use, light then dark."""
    light, dark = [], []
    for name, stops in RAMPS.items():
        c50, c600, c800, c100, c200 = ("#" + stop for stop in stops.split())
        both = ".c-%s>rect,.c-%s>circle,.c-%s>ellipse,rect.c-%s,circle.c-%s,ellipse.c-%s" % ((name,) * 6)
        light.append("%s{fill:%s;stroke:%s}.c-%s .th,.c-%s .t{fill:%s}.c-%s .ts{fill:%s}"
                     % (both, c50, c600, name, name, c800, name, c600))
        dark.append("%s{fill:%s;stroke:%s}.c-%s .th,.c-%s .t{fill:%s}.c-%s .ts{fill:%s}"
                    % (both, c800, c200, name, name, c100, name, c200))
    forced = lambda rules, mode: re.sub(r"(^|[},])(\.c-|rect\.c-|circle\.c-|ellipse\.c-)",
                                        r"\1:root[data-mode=%s] \2" % mode, rules)
    return "%s\n@media (prefers-color-scheme: dark){%s}\n%s\n%s" % (
        "".join(light), "".join(dark), forced("".join(light), "light"), forced("".join(dark), "dark"))


# What a widget written for the Claude app expects of its host: the names
# of its colours, a few classes, sendPrompt and openLink. Only the names
# are the app's; the values here are stand-ins.
WIDGET_HEAD = """<!doctype html><meta charset=utf-8>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:;
 style-src 'unsafe-inline' https://fonts.googleapis.com https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com;
 font-src https://fonts.gstatic.com https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com;
 script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://esm.sh https://cdn.jsdelivr.net https://unpkg.com">
<style>
:root { color-scheme: light dark;
  --surface-0:#fbf9f5; --surface-1:#f4f1ea; --surface-2:#ffffff; --surface-3:#ffffff;
  --text-primary:#1d1b19; --text-secondary:#5f5b55; --text-muted:#8c877f;
  --text-accent:#185FA5; --text-danger:#A32D2D; --text-success:#3B6D11; --text-warning:#854F0B;
  --bg-accent:#E6F1FB; --bg-danger:#FCEBEB; --bg-success:#EAF3DE; --bg-warning:#FAEEDA;
  --border:rgba(0,0,0,.13); --border-strong:rgba(0,0,0,.24); --border-stronger:rgba(0,0,0,.4);
  --border-accent:#85B7EB; --border-danger:#F09595; --border-success:#97C459; --border-warning:#EF9F27;
  --font-sans:-apple-system,"Helvetica Neue",sans-serif; --font-voice:Charter,Georgia,serif;
  --font-mono:"SF Mono",Menlo,monospace; --radius:8px;
  --pad-sm:6px; --pad-md:10px; --pad-lg:16px; --pad-xl:24px;
  --gap-xs:4px; --gap-sm:8px; --gap-md:12px; --gap-lg:16px; --gap-xl:24px;
  --p:var(--text-primary); --s:var(--text-secondary); --t:var(--text-muted);
  --bg2:var(--surface-1); --b:var(--border); }
@media (prefers-color-scheme: dark) { :root {
  --surface-0:#1b1a1d; --surface-1:#26242b; --surface-2:#2e2c34; --surface-3:#36343d;
  --text-primary:#e6e1d8; --text-secondary:#b3aea5; --text-muted:#8f897f;
  --text-accent:#85B7EB; --text-danger:#F09595; --text-success:#97C459; --text-warning:#EF9F27;
  --bg-accent:#0C447C; --bg-danger:#791F1F; --bg-success:#27500A; --bg-warning:#633806;
  --border:rgba(255,255,255,.14); --border-strong:rgba(255,255,255,.26);
  --border-stronger:rgba(255,255,255,.42); } }
:root[data-mode=light] { color-scheme: light;
  --surface-0:#fbf9f5; --surface-1:#f4f1ea; --surface-2:#ffffff; --surface-3:#ffffff;
  --text-primary:#1d1b19; --text-secondary:#5f5b55; --text-muted:#8c877f;
  --text-accent:#185FA5; --text-danger:#A32D2D; --text-success:#3B6D11; --text-warning:#854F0B;
  --bg-accent:#E6F1FB; --bg-danger:#FCEBEB; --bg-success:#EAF3DE; --bg-warning:#FAEEDA;
  --border:rgba(0,0,0,.13); --border-strong:rgba(0,0,0,.24); --border-stronger:rgba(0,0,0,.4);
  --border-accent:#85B7EB; --border-danger:#F09595; --border-success:#97C459; --border-warning:#EF9F27; }
:root[data-mode=dark] { color-scheme: dark;
  --surface-0:#1b1a1d; --surface-1:#26242b; --surface-2:#2e2c34; --surface-3:#36343d;
  --text-primary:#e6e1d8; --text-secondary:#b3aea5; --text-muted:#8f897f;
  --text-accent:#85B7EB; --text-danger:#F09595; --text-success:#97C459; --text-warning:#EF9F27;
  --bg-accent:#0C447C; --bg-danger:#791F1F; --bg-success:#27500A; --bg-warning:#633806;
  --border:rgba(255,255,255,.14); --border-strong:rgba(255,255,255,.26);
  --border-stronger:rgba(255,255,255,.42); }
html, body { margin:0; background:transparent; }
body { color:var(--text-primary); font:16px/1.7 var(--font-sans); overflow:hidden; padding:12px 16px; }
h1,h2,h3 { font-weight:500; margin:.6em 0 .3em; } h1{font-size:22px} h2{font-size:18px} h3{font-size:16px}
.sr-only { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); }
button { font:14px var(--font-sans); color:var(--text-primary); background:transparent;
  border:.5px solid var(--border-strong); border-radius:var(--radius); padding:6px 12px; cursor:pointer; }
button:hover { background:var(--surface-1); } button:active { transform:scale(.98); }
input[type=text], input[type=number], select, textarea { font:14px var(--font-sans); height:36px;
  color:var(--text-primary); background:var(--surface-2); border:.5px solid var(--border-strong);
  border-radius:var(--radius); padding:0 10px; box-sizing:border-box; }
textarea { height:auto; padding:8px 10px; }
svg text { font-family:var(--font-sans); }
.t { font-size:14px; fill:var(--text-primary); } .th { font-size:14px; font-weight:500; fill:var(--text-primary); }
.ts { font-size:12px; fill:var(--text-secondary); }
.box { fill:var(--surface-1); stroke:var(--border-strong); }
.node { cursor:pointer; } .node:hover { opacity:.82; }
.arr { stroke:var(--text-muted); stroke-width:1.5; fill:none; }
.leader { stroke:var(--text-muted); stroke-width:.5; stroke-dasharray:3 3; fill:none; }
%s
</style>
<script>
function roostPost(message) {
  if (parent !== window) parent.postMessage(message, '*');
  else if (message.roost !== 'height') (window.roostOutbox = window.roostOutbox || []).push(message);
}
function sendPrompt(text) { roostPost({roost: 'prompt', kind: 'prompt', text: String(text)}); }
function openLink(url) { roostPost({roost: 'link', kind: 'link', text: String(url)}); }
function roostFit() { roostPost({roost: 'height', height: Math.ceil(document.body.getBoundingClientRect().height)}); }
addEventListener('load', function () { roostFit(); new ResizeObserver(roostFit).observe(document.body); });
document.addEventListener('click', function (e) {
  var a = e.target.closest && e.target.closest('a[href]');
  if (a) { e.preventDefault(); openLink(a.href); } });
</script>
""" % ramp_css()


def widget(code):
    """CODE, a widget an agent wrote, as a frame that runs it shut off from the page."""
    return '<iframe class=widget sandbox="allow-scripts" srcdoc="%s"></iframe>' % esc(WIDGET_HEAD + code)


def picture(source):
    return '<img class=thumb src="data:%s;base64,%s">' % (
        esc(source.get("media_type", "image/png")), source.get("data", ""))


STYLE = """
:root { color-scheme: light dark; --ink:#1d1b19; --paper:#fbf9f5; --quiet:#7a746c; --rule:#e4dfd6;
        --box:#f1ede5; --you:#efe9dd; --link:#2b5c8a; }
@media (prefers-color-scheme: dark) {
  :root { --ink:#e6e1d8; --paper:#1b1a1d; --quiet:#8f897f; --rule:#34323a; --box:#26242b;
          --you:#2b2933; --link:#9cc3e8; } }
html { background: var(--paper); }
body { color: var(--ink); font: 17px/1.55 Charter, "Iowan Old Style", Georgia, serif;
       max-width: 41em; margin: 0 auto; padding: 2em 1.5em 6em; }
p, li { text-align: justify; hyphens: auto; -webkit-hyphens: auto; }
p { margin: .7em 0; }
h2, h3, h4, h5 { font-size: 1em; margin: 1.4em 0 .3em; }
h2 { font-size: 1.15em; }
a { color: var(--link); }
code, pre { font: .82em/1.45 "SF Mono", Menlo, monospace; }
code { background: var(--box); padding: .08em .3em; border-radius: 3px; }
pre { background: var(--box); padding: .8em 1em; border-radius: 6px; overflow-x: auto; }
pre code { background: none; padding: 0; font-size: 1em; }
table { border-collapse: collapse; font-size: .9em; margin: 1em 0; }
th, td { border-bottom: 1px solid var(--rule); padding: .35em .8em .35em 0; text-align: left;
         vertical-align: top; }
blockquote { border-left: 3px solid var(--rule); margin: 1em 0; padding-left: 1em; color: var(--quiet); }
hr { border: 0; border-top: 1px solid var(--rule); margin: 1.5em 0; }
.turn { margin-top: 2.6em; }
.you { background: var(--you); border-radius: 10px; padding: .5em 1em; margin-left: 4em;
       font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: .92em; }
.you p { text-align: left; hyphens: manual; }
details { margin: 1em 0; color: var(--quiet); font: .8em/1.5 -apple-system, sans-serif; }
summary { cursor: pointer; }
.event { text-align: right; }
.event pre { text-align: left; white-space: pre-wrap; }
details .said { color: var(--ink); opacity: .8; border-left: 2px solid var(--rule);
                padding-left: 1em; margin: .6em 0; font: 1.1em/1.5 Charter, Georgia, serif; }
.tool { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tool b { font-weight: 600; }
.shots { display: flex; flex-wrap: wrap; gap: 8px; margin: 1em 0; }
.thumb { height: 96px; border-radius: 6px; border: 1px solid var(--rule); cursor: zoom-in; }
.thumb.big { position: fixed; inset: 0; margin: auto; height: auto; max-height: 94vh; max-width: 96vw;
             z-index: 2; cursor: zoom-out; box-shadow: 0 0 0 100vmax rgba(0,0,0,.7); }
.widget { display: block; width: 100%; height: 120px; border: 1px solid var(--rule); border-radius: 12px;
          margin: 1em 0; background: transparent; }
#sent { position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%); max-width: 34em;
        background: var(--ink); color: var(--paper); padding: .5em 1em; border-radius: 8px;
        font: .8em -apple-system, sans-serif; opacity: 0; transition: opacity .2s; pointer-events: none; }
#sent.on { opacity: .95; }
.working { color: var(--quiet); font-style: italic; }
.path { font: .82em "SF Mono", Menlo, monospace; }
"""

SCRIPT = """
document.addEventListener('click', function (e) {
  var big = document.querySelector('.thumb.big');
  if (big) big.classList.remove('big');
  else if (e.target.classList.contains('thumb')) e.target.classList.add('big');
});
window.roostOutbox = [];
window.addEventListener('message', function (e) {
  var data = e.data || {}, frames = document.querySelectorAll('iframe.widget');
  for (var i = 0; i < frames.length; i++) {
    if (frames[i].contentWindow !== e.source) continue;
    if (data.roost === 'height') frames[i].style.height = Math.max(40, data.height) + 'px';
    else if (data.roost === 'prompt' || data.roost === 'link') {
      window.roostOutbox.push({kind: data.roost, text: data.text});
      var note = document.getElementById('sent');
      note.textContent = (data.roost === 'prompt' ? 'Prompt: ' : 'Link: ') + data.text;
      note.classList.add('on');
      setTimeout(function () { note.classList.remove('on'); }, 2500);
    }
  }
});
window.scrollTo(0, document.body.scrollHeight);
var last = document.querySelector('.turn:last-child');
if (last) last.scrollIntoView();
"""


def page(found, title):
    out = ["<!doctype html><html lang=en><meta charset=utf-8><title>%s</title><style>%s</style><body>"
           % (esc(title), STYLE)]
    for turn in found:
        if turn.get("event"):
            out.append("<section class=turn><details class=event><summary>Sent by the app: %s</summary>"
                       "<pre>%s</pre></details>" % (esc(turn["event"].replace("-", " ")), esc(turn["prompt"])))
        else:
            out.append("<section class=turn><div class=you>%s%s</div>" % (
                markdown(turn["prompt"]), "".join(picture(s) for s in turn.get("attached", []))))
        if turn["steps"]:
            tools = sum(1 for step in turn["steps"] if step[0] == "tool")
            notes = len(turn["steps"]) - tools
            label = ", ".join(part for part in (
                "%d tool call%s" % (tools, "" if tools == 1 else "s") if tools else "",
                "%d note%s" % (notes, "" if notes == 1 else "s") if notes else "") if part)
            out.append("<details><summary>%s</summary>" % label)
            for step in turn["steps"]:
                if step[0] == "text":
                    out.append("<div class=said>%s</div>" % markdown(step[1]))
                else:
                    out.append("<div class=tool><b>%s</b> %s</div>" % (esc(step[1]), esc(step[2])))
            out.append("</details>")
        if turn["images"]:
            out.append("<div class=shots>%s</div>" % "".join(picture(s) for s in turn["images"]))
        out.extend(widget(code) for code in turn.get("widgets", []))
        out.append("<div class=reply>%s</div></section>" % (
            markdown(turn["reply"]) if turn["reply"] else "<p class=working>No reply yet.</p>"))
    out.append("<div id=sent></div><script>%s</script></body></html>" % SCRIPT)
    return "\n".join(out)


LIVE = """
var roostHead = %s;
function roostShow(id, page) {
  var frame = document.getElementById('w' + id), bottom = innerHeight + scrollY >= document.body.scrollHeight - 40;
  if (!frame) {
    var section = document.createElement('section');
    section.className = 'turn';
    section.innerHTML = '<div class=caption></div><iframe class=widget sandbox="allow-scripts"></iframe>';
    frame = section.lastChild;
    frame.id = 'w' + id;
    document.getElementById('pages').appendChild(section);
    document.getElementById('empty').style.display = 'none';
    bottom = true;
  }
  frame.previousSibling.textContent = (page.title || '').replace(/_/g, ' ') + (page.final ? '' : ' …');
  frame.srcdoc = roostHead + page.html;
  if (bottom) frame.parentNode.scrollIntoView();
}
"""


def live_page():
    """A page with no conversation, which `roostShow' fills as pages arrive."""
    return ("<!doctype html><html lang=en><meta charset=utf-8><title>Shown</title><style>%s"
            ".caption { color: var(--quiet); font: .8em -apple-system, sans-serif; }</style><body>"
            "<p id=empty class=working>Nothing shown yet.</p><div id=pages></div><div id=sent></div>"
            "<script>%s%s</script></body></html>"
            % (STYLE, SCRIPT, LIVE % json.dumps(WIDGET_HEAD).replace("</", "<\\/")))


def dump(found, folder):
    """Write the turns FOUND to FOLDER for Emacs to draw: turns.json, with
    each screenshot and each widget's page in a file of its own beside it."""
    import base64
    import os
    os.makedirs(folder, exist_ok=True)
    count = [0]

    def save(source):
        count[0] += 1
        kind = source.get("media_type", "image/png").split("/")[-1].replace("jpeg", "jpg")
        name = os.path.join(folder, "image-%d.%s" % (count[0], kind))
        with open(name, "wb") as file:
            file.write(base64.b64decode(source.get("data", "")))
        return name

    def frame(code):
        count[0] += 1
        name = os.path.join(folder, "widget-%d.html" % count[0])
        with open(name, "w") as file:
            file.write(WIDGET_HEAD + code)
        return name

    out = []
    for turn in found:
        titles = [step[2] for step in turn["steps"] if step[0] == "tool" and step[1] == "Widget"]
        out.append(dict(
            prompt=turn["prompt"], event=turn.get("event"), reply=turn["reply"],
            steps=[list(step) for step in turn["steps"]],
            images=[save(source) for source in turn["images"]],
            attached=[save(source) for source in turn.get("attached", []) if source.get("type") == "base64"],
            widgets=[dict(title=titles[n] if n < len(titles) else "", file=frame(code))
                     for n, code in enumerate(turn.get("widgets", []))]))
    with open(os.path.join(folder, "turns.json"), "w") as file:
        json.dump(out, file)


if __name__ == "__main__":
    if sys.argv[1] == "--json":
        dump(turns(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == "--live":
        with open(sys.argv[2], "w") as file:
            file.write(live_page())
    else:
        source, target = sys.argv[1], sys.argv[2]
        with open(target, "w") as file:
            file.write(page(turns(source), "Conversation"))
