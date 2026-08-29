#!/usr/bin/env python3
"""Render the whitepaper markdown → HTML (self-contained) → PDF (headless Chrome). No dependencies."""
import html
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CSS = """
@page{size:A4;margin:22mm 20mm}
body{font:11.5pt/1.55 Georgia,"Times New Roman",serif;color:#111;max-width:760px;margin:0 auto;padding:40px 24px}
h1{font-size:24pt;line-height:1.2;margin:0 0 6px}h2{font-size:14.5pt;margin:26px 0 8px}h3{font-size:12pt;margin:18px 0 6px}
p{margin:0 0 10px;text-align:justify}em{color:#333}
table{border-collapse:collapse;margin:10px 0 14px;font-size:10.5pt;width:100%}th,td{border-bottom:1px solid #ccc;padding:4px 8px;vertical-align:top}th{text-align:left;background:#f3f1ec}td.r,th.r{text-align:right}
code{font:10pt ui-monospace,Menlo,Consolas,monospace;background:#f3f1ec;padding:1px 4px;border-radius:3px}
pre{font:9.8pt/1.45 ui-monospace,Menlo,Consolas,monospace;background:#f6f5f1;border:1px solid #e3e0d8;padding:10px 12px;border-radius:6px;overflow-x:auto;white-space:pre-wrap}
pre code{background:none;padding:0}
.math{text-align:center;font-style:italic;margin:12px 0;font-size:12pt}
.frac{display:inline-block;vertical-align:middle;text-align:center;margin:0 3px}.frac .num{display:block;border-bottom:1px solid #111;padding:0 4px}.frac .den{display:block;padding:0 4px}
hr{border:0;border-top:1px solid #ccc;margin:24px 0}
ol{padding-left:22px}li{margin:3px 0}
.meta{color:#555;font-style:italic;margin-bottom:18px}
.abstract{margin:14px 0 18px;padding:0 14px;border-left:3px solid #f7931a}
.disclaimer{font-size:10pt;color:#555}
@media print{body{padding:0}}
"""


def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"(?<!\*)\*(?![*\s])(.+?)(?<![*\s])\*(?!\*)", r"<em>\1</em>", s)
    s = re.sub(r"\$(?!\d)([^$]+?)\$", lambda m: "<em>" + mathify(m.group(1)) + "</em>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def mathify(t):
    t = t.replace("{,}", ",").replace("\\,", " ").replace("\\qquad", " &nbsp;&nbsp;&nbsp;&nbsp; ").replace("\\approx", "≈").replace("\\cdot", " · ")
    t = t.replace("\\prod_k", "∏<sub>k</sub>")
    t = re.sub(r"\\text\{([^}]*)\}", r"\1", t)
    t = re.sub(r"\^\{([^{}]*)\}", r"<sup>\1</sup>", t)
    t = re.sub(r"\^([A-Za-z0-9])", r"<sup>\1</sup>", t)
    t = re.sub(r"_\{([^{}]*)\}", r"<sub>\1</sub>", t)
    t = re.sub(r"_([A-Za-z0-9])", r"<sub>\1</sub>", t)
    t = re.sub(r"\\frac\{([^{}]*)\}\{([^{}]*)\}", r'<span class="frac"><span class="num">\1</span><span class="den">\2</span></span>', t)
    t = t.replace("\\", "")
    return t


def table(lines):
    rows = [[c.strip() for c in l.strip().strip("|").split("|")] for l in lines]
    align = rows[1]
    right = [a.endswith(":") and not a.startswith(":") for a in align]
    out = ["<table><thead><tr>"]
    out += [f'<th class="{"r" if right[i] else ""}">{inline(c)}</th>' for i, c in enumerate(rows[0])]
    out.append("</tr></thead><tbody>")
    for r in rows[2:]:
        out.append("<tr>" + "".join(f'<td class="{"r" if i < len(right) and right[i] else ""}">{inline(c)}</td>' for i, c in enumerate(r)) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def render(md):
    lines = md.split("\n")
    out, i, para = [], 0, []

    def flush():
        nonlocal para
        if para:
            txt = " ".join(para).strip()
            cls = ' class="abstract"' if txt.startswith("**Abstract.**") else (' class="disclaimer"' if txt.startswith("*This document") else "")
            out.append(f"<p{cls}>{inline(txt)}</p>")
            para = []

    while i < len(lines):
        l = lines[i]
        if l.startswith("```"):
            flush(); j = i + 1; buf = []
            while j < len(lines) and not lines[j].startswith("```"):
                buf.append(lines[j]); j += 1
            out.append("<pre><code>" + html.escape("\n".join(buf)) + "</code></pre>"); i = j + 1; continue
        if l.startswith("$$"):
            flush(); out.append(f'<div class="math">{mathify(l.strip("$ "))}</div>'); i += 1; continue
        if l.startswith("|"):
            flush(); j = i
            while j < len(lines) and lines[j].startswith("|"):
                j += 1
            out.append(table(lines[i:j])); i = j; continue
        m = re.match(r"^(#{1,3}) (.*)", l)
        if m:
            flush(); out.append(f"<h{len(m.group(1))}>{inline(m.group(2))}</h{len(m.group(1))}>"); i += 1; continue
        if l.strip() == "---":
            flush(); out.append("<hr>"); i += 1; continue
        m = re.match(r"^(\d+)\. (.*)", l)
        if m:
            flush(); items = []
            while i < len(lines) and re.match(r"^\d+\. ", lines[i]):
                items.append(re.sub(r"^\d+\. ", "", lines[i])); i += 1
            out.append("<ol>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ol>"); continue
        if l.startswith("- "):
            flush(); items = []
            while i < len(lines) and lines[i].startswith("- "):
                items.append(lines[i][2:]); i += 1
            out.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>"); continue
        if re.match(r"^\*[^*].*\*$", l.strip()) and i < 6:  # author/date lines
            flush(); out.append(f'<div class="meta">{inline(l.strip())}</div>'); i += 1; continue
        if l.strip() == "":
            flush(); i += 1; continue
        para.append(l); i += 1
    flush()
    return "\n".join(out)


def _scrub_pdf(pdf):
    import re
    b = open(pdf, "rb").read()
    def pad(m):
        inner = m.group(2); repl = b"Second Bitcoin"
        return m.group(1) + repl[:len(inner)] + b" " * max(0, len(inner) - len(repl)) + b")"
    b = re.sub(rb"(/Creator \()([^)]*)(\))", pad, b)
    b = re.sub(rb"(/Producer \()([^)]*)(\))", pad, b)
    open(pdf, "wb").write(b)


def build(name, title, lang):
    md = open(os.path.join(HERE, f"{name}.md"), encoding="utf-8").read()
    body = render(md)
    doc = f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><title>{html.escape(title)}</title><style>{CSS}</style></head><body>{body}</body></html>'
    hp = os.path.join(HERE, f"{name}.html")
    open(hp, "w", encoding="utf-8").write(doc)
    pdf = os.path.join(HERE, f"{name}.pdf")
    if os.path.exists(CHROME):
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", f"--print-to-pdf={pdf}", "file://" + hp],
                       check=False, capture_output=True, timeout=120)
        if os.path.exists(pdf):
            _scrub_pdf(pdf)
    print(name, "→", hp, "(+pdf)" if os.path.exists(pdf) else "(no pdf)")


if __name__ == "__main__":
    build("second_bitcoin_en", "Second Bitcoin: A Second Chance at a Fair Distribution", "en")
