# -*- coding: utf-8 -*-
"""
산출방법론.md -> 산출방법론.html
================================
문서에서 실제로 쓰는 문법만 처리하는 소형 렌더러다.
지원: 제목(#~###), 문단, 코드블록(```), 표, 목록(-), 인용(>), 수평선(---),
      인라인 **굵게** · `코드`
"""
import html as H
import re

INLINE = [
    (re.compile(r"\*\*(.+?)\*\*"), r"<strong>\1</strong>"),
    (re.compile(r"`(.+?)`"), r"<code>\1</code>"),
]


def inline(s):
    s = H.escape(s)
    for pat, rep in INLINE:
        s = pat.sub(rep, s)
    return s


def render(md):
    lines = md.split("\n")
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]

        # 코드블록
        if ln.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].startswith("```"):
                buf.append(H.escape(lines[i]))
                i += 1
            i += 1
            out.append('<pre class="eq">' + "\n".join(buf) + "</pre>")
            continue

        # 수평선
        if ln.strip() == "---":
            out.append("<hr>")
            i += 1
            continue

        # 제목
        m = re.match(r"^(#{1,3})\s+(.*)$", ln)
        if m:
            lv = len(m.group(1))
            out.append(f"<h{lv}>{inline(m.group(2))}</h{lv}>")
            i += 1
            continue

        # 표 — 헤더 / 구분선 / 본문
        if ln.lstrip().startswith("|") and i + 1 < len(lines) and \
                re.match(r"^\s*\|[\s:\-|]+\|\s*$", lines[i + 1]):
            def cells(r):
                return [c.strip() for c in r.strip().strip("|").split("|")]
            head = cells(ln)
            i += 2
            body = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                body.append(cells(lines[i]))
                i += 1
            t = ["<div class='tblwrap'><table><thead><tr>"]
            t += [f"<th>{inline(c)}</th>" for c in head]
            t.append("</tr></thead><tbody>")
            for r in body:
                t.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            t.append("</tbody></table></div>")
            out.append("".join(t))
            continue

        # 인용
        if ln.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].startswith(">"):
                buf.append(lines[i].lstrip("> ").rstrip())
                i += 1
            out.append('<blockquote class="warn">' + inline(" ".join(buf)) + "</blockquote>")
            continue

        # 목록 — 이어지는 들여쓴 줄은 같은 항목으로 합친다
        if re.match(r"^[-*]\s+", ln):
            items = []
            while i < len(lines) and (re.match(r"^[-*]\s+", lines[i])
                                      or (items and lines[i].startswith("  ") and lines[i].strip())):
                if re.match(r"^[-*]\s+", lines[i]):
                    items.append(re.sub(r"^[-*]\s+", "", lines[i]).strip())
                else:
                    items[-1] += " " + lines[i].strip()
                i += 1
            out.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>")
            continue

        # 빈 줄
        if not ln.strip():
            i += 1
            continue

        # 문단 — 빈 줄까지 이어붙인다
        buf = []
        while i < len(lines) and lines[i].strip() and not re.match(
                r"^(#{1,3}\s|```|>|[-*]\s|\s*\|)", lines[i]) and lines[i].strip() != "---":
            buf.append(lines[i].strip())
            i += 1
        if buf:
            out.append("<p>" + inline(" ".join(buf)) + "</p>")
    return "\n".join(out)
