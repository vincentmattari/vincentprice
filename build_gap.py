"""A·B 등급인데 재고 단가와 센터가 단가가 크게 벌어지는 부품을 뽑는다.

    python build_gap.py   ->  AB등급_재고_센터가_단가괴리.html

왜 보는가
    A·B 는 입고 이력으로 매입단가가 '확정' 된 등급이다. 그래서 다른 기준으로
    바꿀 이유가 없다고 본다. 그런데 그 확정 단가가 센터가와 수십~수천 배
    벌어지는 건이 있다. 대부분 FIFO 원가가 1원·10원 같은 명목 금액인 경우로,
    확정이라는 이름표를 달고 재고 평가액을 조용히 낮춘다.

    반대로 재고 단가가 센터가보다 비싼 건도 있다. 이건 과거에 비싸게 샀거나
    센터가가 낮게 등록된 경우다.

입력은 build_maeip.py 가 남긴 data_maeip.json 이다.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data_maeip.json"
BASE_TEMPLATE = ROOT / "template_bases.html"
SOURCE_PAGE = "재고_센터가_매입처_기준_매입단가_재산정.html"
OUT_PAGE = "AB등급_재고_센터가_단가괴리.html"

# (라벨, 판정, 설명)
BUCKETS = [
    ("센터가가 10배 이상", lambda x: x >= 10,
     "재고 단가가 1원·10원 같은 명목 금액일 가능성이 높다. 확정 등급이지만 "
     "실제 취득원가로 보기 어렵다."),
    ("센터가가 3~10배", lambda x: 3 <= x < 10,
     "오래전에 싸게 샀거나, 센터가가 과하게 높은 경우다. 건별 확인이 필요하다."),
    ("센터가가 1.5~3배", lambda x: 1.5 <= x < 3,
     "흔한 폭이다. 매입 시점과 지금 정가의 차이로 설명되는 구간."),
    ("재고가 1.5배 이상 비쌈", lambda x: x <= 1 / 1.5,
     "과거에 비싸게 샀거나 센터가가 낮게 등록된 경우다."),
]

COLS = ["지점", "품번", "부품명", "메이커", "등급", "현재고수량",
        "단가_재고", "단가_센터가", "배수",
        "평가액_재고", "평가액_센터가", "차액",
        "최근매입원가", "최근매입일", "근거"]
NUMCOLS = {"현재고수량", "단가_재고", "단가_센터가", "평가액_재고", "평가액_센터가", "차액"}


def bucket_of(ratio):
    for label, test, _ in BUCKETS:
        if test(ratio):
            return label
    return None


def build():
    data = json.loads(DATA.read_text(encoding="utf-8"))
    재고 = [r for r in data["items"] if r["현재고수량"] > 0]
    ab = [r for r in 재고 if r["등급"] in ("A", "B")]
    both = [r for r in ab if r["단가_재고"] and r["단가_센터가"]]

    rows = []
    for r in both:
        ratio = r["단가_센터가"] / r["단가_재고"]
        b = bucket_of(ratio)
        if b is None:                      # 차이가 크지 않은 건은 싣지 않는다
            continue
        rec = {c: r.get(c) for c in COLS if c in r}
        rec["배수"] = round(ratio, 2)
        rec["차액"] = (r["평가액_센터가"] or 0) - (r["평가액_재고"] or 0)
        rec["_b"] = b
        rows.append(rec)
    rows.sort(key=lambda x: -abs(x["차액"]))

    web = {
        "cols": COLS, "rows": rows,
        "ab": len(ab), "both": len(both), "hit": len(rows),
        "buckets": [
            {"label": lab, "desc": desc,
             "n": sum(1 for x in rows if x["_b"] == lab),
             "gap": sum(x["차액"] for x in rows if x["_b"] == lab)}
            for lab, _, desc in BUCKETS
        ],
        "sum_stock": sum(x["평가액_재고"] or 0 for x in rows),
        "sum_center": sum(x["평가액_센터가"] or 0 for x in rows),
        "source": SOURCE_PAGE,
    }

    css = re.search(r"<style>(.*?)</style>",
                    BASE_TEMPLATE.read_text(encoding="utf-8"), re.S).group(1)
    html = (PAGE.replace("__CSS__", css)
                .replace("__SOURCE__", SOURCE_PAGE)
                .replace("/*__DATA__*/null",
                         json.dumps(web, ensure_ascii=False, separators=(",", ":"))))
    (ROOT / OUT_PAGE).write_text(html, encoding="utf-8")
    return web


PAGE = """<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>A·B 등급 재고 단가와 센터가 괴리</title>
<style>__CSS__
.rsn{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:12px}
.rsn .tile{cursor:pointer;border-left:3px solid var(--accent)}
.rsn .tile[aria-pressed="true"]{outline:2px solid var(--accent);outline-offset:-2px}
.rsn .d{font-size:12px;color:var(--ink-2);margin-top:6px;line-height:1.5}
td.mul{font-weight:640}
td.mul.up{color:var(--g-d)} td.mul.down{color:var(--g-b)}
td.gap.pos{color:var(--g-d)} td.gap.neg{color:var(--g-b)}
.tiny{color:var(--ink-3);font-size:11.5px}
</style>
</head>
<body>
<div class="wrap">
<h1>A·B 등급 재고 단가와 센터가 괴리</h1>
<p class="sub">A·B 는 입고 이력으로 매입단가가 <strong>확정</strong>된 등급이라 다른 기준으로 바꿀 이유가 없다고 봅니다.
그런데 그 확정 단가가 센터가와 크게 벌어지는 건이 있습니다. 특히 <strong>재고 단가가 1원·10원 같은 명목 금액</strong>인 경우,
확정이라는 이름표를 단 채 재고 평가액을 낮춥니다.<br>
<a class="mlink" href="__SOURCE__">← 재고_센터가_매입처_기준_매입단가_비교</a></p>

<div class="tiles" id="top"></div>

<div class="card">
  <h2>차이 구간 (눌러서 아래 표를 거릅니다)</h2>
  <div class="rsn" id="rsn"></div>
</div>

<div class="card">
  <h2>부품 목록</h2>
  <div class="ctrls stick">
    <div class="fld"><label for="q">품번 · 부품명 검색</label>
      <input type="search" id="q" placeholder="품번 또는 부품명 일부" autocomplete="off"></div>
    <div class="fld"><label for="br">지점</label><select id="br"></select></div>
    <div class="fld"><label for="mk">메이커</label><select id="mk"></select></div>
    <div class="fld"><label for="gr">등급</label><select id="gr">
      <option value="">전체</option><option>A</option><option>B</option></select></div>
    <div class="fld"><label for="sr">정렬</label><select id="sr">
      <option value="gap">차액 큰 순</option>
      <option value="mul">배수 큰 순</option>
      <option value="qty">재고 수량 순</option></select></div>
    <div class="fld"><label>&nbsp;</label><button class="btn" id="csv">CSV 내려받기</button></div>
  </div>
  <div class="tblwrap"><table class="sum"><thead id="th"></thead><tbody id="tbody"></tbody></table></div>
  <p class="foot" id="foot"></p>
</div>
</div>
<script>
const D=/*__DATA__*/null;
const nf=n=>(n==null?"—":Number(n).toLocaleString("ko-KR"));
const esc=s=>String(s==null?"":s).replace(/[&<>]/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[m]));
const NUM=new Set(["현재고수량","단가_재고","단가_센터가","평가액_재고","평가액_센터가","차액"]);
let pick="";

document.getElementById("top").innerHTML=[
  ["차이가 큰 부품", nf(D.hit)+"개", "A·B "+nf(D.ab)+"개 중"],
  ["재고 기준 평가액", nf(D.sum_stock)+"원", "이 부품들만"],
  ["센터가 기준 평가액", nf(D.sum_center)+"원", "이 부품들만"],
  ["차액", nf(D.sum_center-D.sum_stock)+"원", "센터가 − 재고"],
].map(([k,v,n])=>`<div class="tile"><div class="k">${k}</div><div class="v">${v}</div><div class="n">${n}</div></div>`).join("");

document.getElementById("rsn").innerHTML=D.buckets.filter(b=>b.n).map((b,i)=>
  `<div class="tile" role="button" tabindex="0" aria-pressed="false" data-l="${esc(b.label)}">
     <div class="k">${esc(b.label)}</div><div class="v">${nf(b.n)}개</div>
     <div class="n">차액 ${nf(b.gap)}원</div><div class="d">${esc(b.desc)}</div></div>`).join("");
document.getElementById("rsn").addEventListener("click",e=>{
  const t=e.target.closest(".tile"); if(!t) return;
  pick = (pick===t.dataset.l) ? "" : t.dataset.l;
  [...document.querySelectorAll("#rsn .tile")].forEach(x=>
    x.setAttribute("aria-pressed", x.dataset.l===pick));
  draw();
});

function fill(id,vals){
  const s=document.getElementById(id);
  s.innerHTML='<option value="">전체</option>'+
    [...new Set(vals)].filter(Boolean).sort((a,b)=>String(a).localeCompare(String(b),"ko"))
      .map(v=>`<option>${esc(v)}</option>`).join("");
}
fill("br",D.rows.map(r=>r["지점"]));
fill("mk",D.rows.map(r=>r["메이커"]));

document.getElementById("th").innerHTML="<tr>"+
  D.cols.map(c=>`<th class="${NUM.has(c)||c==="배수"?"":"l"}">${esc(c.replace("_"," "))}</th>`).join("")+
  '<th class="l">구간</th></tr>';

function view(){
  const q=document.getElementById("q").value.trim().toLowerCase();
  const br=document.getElementById("br").value, mk=document.getElementById("mk").value;
  const gr=document.getElementById("gr").value, sr=document.getElementById("sr").value;
  let out=D.rows.filter(r=>{
    if(pick && r._b!==pick) return false;
    if(br && r["지점"]!==br) return false;
    if(mk && r["메이커"]!==mk) return false;
    if(gr && r["등급"]!==gr) return false;
    if(q && !((r["품번"]||"").toLowerCase().includes(q)
           || (r["부품명"]||"").toLowerCase().includes(q))) return false;
    return true;
  });
  if(sr==="mul") out=out.slice().sort((a,b)=>b["배수"]-a["배수"]);
  else if(sr==="qty") out=out.slice().sort((a,b)=>b["현재고수량"]-a["현재고수량"]);
  else out=out.slice().sort((a,b)=>Math.abs(b["차액"])-Math.abs(a["차액"]));
  return out;
}

function draw(){
  const rows=view();
  document.getElementById("tbody").innerHTML=rows.map(r=>"<tr>"+
    D.cols.map(c=>{
      const v=r[c];
      if(c==="배수") return `<td class="mul ${v>=1?"up":"down"}">${v>=1?"×"+v:"÷"+(1/v).toFixed(2)}</td>`;
      if(c==="차액") return `<td class="gap ${v>=0?"pos":"neg"}">${nf(v)}</td>`;
      if(NUM.has(c)) return `<td>${v==null?'<span class="muted">—</span>':nf(v)}</td>`;
      if(c==="품번") return `<td class="l pn">${esc(v)}</td>`;
      if(c==="부품명") return `<td class="l nm">${esc(v)}</td>`;
      if(c==="근거") return `<td class="l tiny">${esc(v)}</td>`;
      return `<td class="l">${v==null?'<span class="muted">—</span>':esc(v)}</td>`;
    }).join("")+`<td class="l">${esc(r._b)}</td></tr>`).join("");
  const gap=rows.reduce((a,r)=>a+r["차액"],0);
  document.getElementById("foot").textContent=
    `${nf(rows.length)}개 표시 / 전체 ${nf(D.hit)}개 · 이 목록의 차액 합계 ${nf(gap)}원`
    +(pick?` · 구간: ${pick}`:"");
}
["q","br","mk","gr","sr"].forEach(id=>{
  const el=document.getElementById(id);
  el.addEventListener(id==="q"?"input":"change",draw);
});
document.getElementById("csv").addEventListener("click",()=>{
  const head=D.cols.concat(["구간"]);
  const qq=v=>'"'+String(v==null?"":v).replace(/"/g,'""')+'"';
  const csv="\\uFEFF"+[head.map(qq).join(",")].concat(
    view().map(r=>D.cols.map(c=>qq(r[c])).concat([qq(r._b)]).join(","))).join("\\r\\n");
  const a=document.createElement("a");
  a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv"}));
  a.download="AB등급_재고_센터가_단가괴리.csv"; a.click();
});
draw();
</script>
</body></html>
"""


def main():
    w = build()
    print(f"A·B 등급 {w['ab']:,}개 · 두 단가 모두 있는 것 {w['both']:,}개")
    print(f"차이가 큰 부품 {w['hit']:,}개\n")
    for b in w["buckets"]:
        if b["n"]:
            print(f"  {b['label']:<22}{b['n']:>5,}개   차액 {b['gap']:>16,}원")
    print(f"\n  재고 기준 {w['sum_stock']:,}원 -> 센터가 기준 {w['sum_center']:,}원 "
          f"({w['sum_center'] - w['sum_stock']:+,}원)")
    print(f"\n  생성: {OUT_PAGE}")


if __name__ == "__main__":
    main()
