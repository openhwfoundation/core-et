#!/usr/bin/env python3
"""Convert a WaveJSON timing diagram (.json5) into an editable draw.io file.

Shared by every chapter, so it lives in tools/ rather than beside any one chapter's
diagrams. Run it from docs/uarch_spec:
    python3 tools/wave2dio.py images/ch03/src/td-l0-hit.json5
Writes diagram.drawio next to each input. Export the PNG the document uses with:
    drawio -x -f png -s 2 -b 10 -o images/ch03/td-l0-hit.png images/ch03/src/td-l0-hit.drawio

Supported WaveJSON subset (enough for micro-architecture documents):
  wave characters   p (clock), 0, 1, ., x, | (variable-delay break), data symbols = 2 3 4 5
  lane keys         name, wave, data, node
  top-level keys    signal (with {} spacers), edge ("A~>B label", "A-|>B label"),
                    group ([{name, from, to}], lane names, draws a labelled bracket)
Everything else is ignored.
"""
import html, json5, re, sys

CW = 60    # cycle width in points
LH = 26    # lane height
LG = 16    # gap between lanes
NW = 190   # name column width
SL = 6     # slope width of an edge
X0 = NW + 20
COL = {'2': '#ffffff', '3': '#ffffb4', '4': '#ffe0b9', '5': '#b9e0ff', '=': '#ffffff'}


class W:
    def __init__(s):
        s.c = []
        s.n = 1

    def id(s):
        s.n += 1
        return f"w{s.n}"

    def v(s, x, y, w, h, val, st):
        s.c.append(f'<mxCell id="{s.id()}" value="{html.escape(val)}" style="{st}" vertex="1" '
                   f'parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    def line(s, pts, st="endArrow=none;html=1;rounded=0;strokeWidth=1.5;", val=""):
        (x1, y1), (x2, y2) = pts[0], pts[-1]
        mid = ''.join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in pts[1:-1])
        arr = f'<Array as="points">{mid}</Array>' if mid else ''
        s.c.append(f'<mxCell id="{s.id()}" value="{html.escape(val)}" style="{st}" edge="1" parent="1">'
                   f'<mxGeometry relative="1" as="geometry"><mxPoint x="{x1}" y="{y1}" as="sourcePoint"/>'
                   f'<mxPoint x="{x2}" y="{y2}" as="targetPoint"/>{arr}</mxGeometry></mxCell>')


def runs(wave):
    out = []
    for i, ch in enumerate(wave):
        if ch == '.' and out:
            out[-1][2] += 1
            continue
        out.append([ch, i, 1])
    return out


def convert(src, dst):
    j = json5.load(open(src))
    sig = j['signal']
    n = max(len(l.get('wave', '')) for l in sig if l)
    w = W()
    y = 30
    top = y
    lanes = []
    for l in sig:
        if not l:
            y += LG
            continue
        lanes.append((l, y))
        y += LH + LG
    bottom = y
    for g in j.get('group', []):
        ya = next(y for l, y in lanes if l.get('name') == g['from'])
        yb = next(y for l, y in lanes if l.get('name') == g['to']) + LH
        w.v(-10, ya - 7, X0 + n * CW + 20, yb - ya + 14, "",
            "rounded=1;arcSize=3;html=1;fillColor=none;strokeColor=#c3d2e8;dashed=1;strokeWidth=1.5;")
        w.v(-36, ya, 18, yb - ya, "",
            "shape=curlyBracket;whiteSpace=wrap;html=1;rounded=1;strokeColor=#1f4e9c;strokeWidth=1.5;")
        h = yb - ya
        w.v(-62 - h / 2, (ya + yb) / 2 - 11, h, 22, g['name'],
            "text;html=1;align=center;verticalAlign=middle;fontSize=14;fontStyle=1;"
            "fontColor=#1f4e9c;rotation=-90;")
    for i in range(n + 1):
        x = X0 + i * CW
        w.v(x - 15, 5, 30, 20, str(i), "text;html=1;align=center;fontSize=11;fontColor=#999999;")
        w.line([(x, top), (x, bottom - LG)], "endArrow=none;html=1;dashed=1;strokeColor=#cccccc;")
    nodes = {}
    for l, y0 in lanes:
        wave = l['wave']
        data = l.get('data', [])
        data = data.split() if isinstance(data, str) else list(data)
        w.v(0, y0, NW, LH, l.get('name', ''),
            "text;html=1;align=right;verticalAlign=middle;fontSize=13;fontColor=#1f4e9c;")
        hi, lo = y0 + 2, y0 + LH - 2
        for k, ch in enumerate(l.get('node', '')):
            if ch != '.':
                nodes[ch.upper()] = (X0 + k * CW, (hi + lo) / 2)
        if wave[0] == 'p':                      # clock
            pts = []
            for i in range(n):
                x = X0 + i * CW
                pts += [(x, lo), (x, hi), (x + CW / 2, hi), (x + CW / 2, lo)]
            pts.append((X0 + n * CW, lo))
            w.line(pts)
            continue
        gaps = [k for k, ch in enumerate(wave) if ch == '|']
        wave = wave.replace('|', '.')
        last = None
        for ch, i, ln in runs(wave):
            xa, xb = X0 + i * CW, X0 + (i + ln) * CW
            if ch in '01':                      # level, with sloped transition
                yy = hi if ch == '1' else lo
                if last in ('0', '1') and last != ch:
                    w.line([(xa, hi if ch == '0' else lo), (xa + SL, yy), (xb, yy)])
                else:
                    w.line([(xa, yy), (xb, yy)])
            elif ch == 'x':                     # unknown
                w.v(xa, hi, xb - xa, lo - hi, "",
                    "rounded=0;html=1;fillColor=#e6e6e6;strokeColor=#666666;fillStyle=hatch;")
            else:                               # data
                lab = data.pop(0) if data else ''
                w.v(xa, hi, xb - xa, lo - hi, lab,
                    "shape=hexagon;perimeter=hexagonPerimeter2;size=6;fixedSize=1;html=1;fontSize=12;"
                    f"fillColor={COL.get(ch, '#ffffff')};strokeColor=#000000;")
            last = ch
        for k in gaps:                      # variable-delay break
            x = X0 + k * CW + CW / 2
            w.v(x - 7, hi - 4, 14, lo - hi + 8, "",
                "rounded=0;html=1;fillColor=#ffffff;strokeColor=none;")
            for dx in (-3, 3):
                w.line([(x + dx - 3, lo + 4), (x + dx + 3, hi - 4)],
                       "endArrow=none;html=1;strokeWidth=1.2;")
    for e in j.get('edge', []):
        m = re.match(r"([A-Z])(~>|-\|>)([A-Z])\s*(.*)", e)
        if not m or m.group(1) not in nodes or m.group(3) not in nodes:
            continue
        a, b = nodes[m.group(1)], nodes[m.group(3)]
        if m.group(2) == '~>':
            st = ("curved=1;html=1;endArrow=block;endFill=1;strokeColor=#0041c4;fontSize=12;"
                  "labelBackgroundColor=#ffffff;")
            pts = [a, ((a[0] + b[0]) / 2, a[1]), ((a[0] + b[0]) / 2, b[1]), b]
        else:
            st = ("html=1;endArrow=block;endFill=1;strokeColor=#0041c4;fontSize=12;"
                  "labelBackgroundColor=#ffffff;")
            pts = [a, (b[0], a[1]), b]
        w.line(pts, st, m.group(4))
    open(dst, "w").write('<mxfile><diagram name="timing"><mxGraphModel><root><mxCell id="0"/>'
                         '<mxCell id="1" parent="0"/>' + ''.join(w.c) + '</root></mxGraphModel></diagram></mxfile>')


if __name__ == '__main__':
    for s in sys.argv[1:]:
        convert(s, s.replace('.json5', '.drawio'))
