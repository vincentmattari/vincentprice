# -*- coding: utf-8 -*-
"""
산출 전제 검증 스크립트
=======================
build_price.py 가 세운 두 가지 전제가 원본 데이터에서 실제로 성립하는지 확인한다.
결과가 모두 OK 여야 산출값을 신뢰할 수 있다.
"""
import openpyxl, sys, io, glob, statistics as st

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
PATTERN = "*_발주_입고_횟수_*.xlsx"     # 원자료는 저장소에 포함하지 않으므로 패턴으로 찾는다
_found = sorted(glob.glob(PATTERN))
if not _found:
    sys.exit(f"원본 엑셀을 찾을 수 없습니다. 이 폴더에 {PATTERN} 파일을 두세요.")
SRC = _found[-1]

_ws = openpyxl.load_workbook(SRC, data_only=True).worksheets[0]
_hdr = [str(c.value).strip() if c.value is not None else "" for c in _ws[1]]
_need = ["부품 품번", "발주", "입고", "CNT", "발주평균가", "입고평균가",
         "전체평균가", "전체최소가", "전체최대가"]
_missing = [k for k in _need if k not in _hdr]
if _missing:
    sys.exit(f"필수 컬럼 누락: {_missing}\n  발견된 헤더: {_hdr}")
_ix = [_hdr.index(k) for k in _need]     # 헤더 이름으로 찾아 컬럼 순서 변화에 견딘다
rows = [tuple(r[i] for i in _ix) for r in _ws.iter_rows(min_row=2, values_only=True)]
print(f"원본: {SRC}\n행수: {len(rows)}\n")
ok = True


def check(label, cond, detail=""):
    global ok
    ok &= cond
    print(("  [OK]   " if cond else "  [실패] ") + label + ("  " + detail if detail else ""))


print("=" * 74)
print("전제 1 — 발주평균가·입고평균가는 '단가'가 아니라 CNT로 나눈 '기여분'이다")
print("=" * 74)
n_sum = sum(1 for r in rows if abs((r[4] + r[5]) - r[6]) <= 1)
check("발주평균가 + 입고평균가 == 전체평균가", n_sum == len(rows), f"{n_sum}/{len(rows)}행")
n_cnt = sum(1 for r in rows if r[1] + r[2] == r[3])
check("발주건수 + 입고건수 == CNT", n_cnt == len(rows), f"{n_cnt}/{len(rows)}행")
print("\n  → 복원식:  발주단가 = 발주평균가 × CNT ÷ 발주건수")
r = next(x for x in rows if x[0] == "MQALKRNP0810078")
u_po, u_rc = r[4] * r[3] / r[1], r[5] * r[3] / r[2]
back = (u_po * r[1] + u_rc * r[2]) / r[3]
print(f"     예) {r[0]}: 발주단가 {u_po:,.0f} · 입고단가 {u_rc:,.0f}")
check("복원 단가를 건수 가중평균하면 전체평균가로 되돌아온다",
      abs(back - r[6]) <= 1, f"{back:,.1f} vs {r[6]:,}")

print("\n" + "=" * 74)
print("전제 2 — 가격 0원은 '무료'가 아니라 '미기재'다")
print("=" * 74)
c2z = [x for x in rows if x[3] == 2 and x[7] == 0 and x[8] > 0]
n_half = sum(1 for x in c2z if abs(x[6] - x[8] / 2) <= 1)
check("CNT=2 & 최소가=0 인 부품에서  전체평균가 == 전체최대가 ÷ 2",
      n_half == len(c2z), f"{n_half}/{len(c2z)}행")
print("     (2건 중 1건이 0원 → 평균이 정확히 절반으로 희석된다는 직접 증거)")
for x in sorted(c2z, key=lambda r: -r[8])[:3]:          # 금액이 큰 순으로 대표 사례
    side = "발주" if x[4] > 0 else "입고"               # 가격이 기재된 쪽
    other = "입고" if side == "발주" else "발주"
    print(f"     예) {x[0]:<16} {side}1건@{x[8]:,}원 + {other}1건@0원"
          f"  →  평균가 {x[6]:,}원 = 최대가 {x[8]:,} ÷ 2")

c1 = [x for x in rows if x[3] == 1]
z1 = [x for x in c1 if x[8] == 0]
p0 = len(z1) / len(c1)
print(f"\n  단일거래(CNT=1) 부품 {len(c1)}개 중 가격 0원 {len(z1)}개  →  전사 미기재율 p₀ = {p0:.3f}")
check("미기재율 사전값 0.45가 실측치보다 크되 과하지 않다", p0 < 0.45 <= p0 + 0.10,
      f"실측 {p0:.3f} / 사용 0.45")

print("\n  CNT 구간별 미기재 규모 — 구간 전반에서 안정적이어야 사전값을 쓸 수 있다")
for lo, hi in [(2, 2), (3, 4), (5, 9), (10, 49), (50, 10**9)]:
    g = [x for x in rows if lo <= x[3] <= hi and x[8] > 0]
    if g:
        med = st.median([1 - x[6] / x[8] for x in g])
        print(f"     CNT {lo}-{hi if hi < 10**9 else '+':<3}: n={len(g):4d}   추정 미기재 비중 중앙값 {med:.3f}")

print("\n" + "=" * 74)
print("산출 불가 대상")
print("=" * 74)
f = [x for x in rows if x[8] == 0]
print(f"  전체최대가 = 0 인 부품 {len(f)}개 ({100*len(f)/len(rows):.1f}%)"
      f" — 모든 거래에 가격이 없어 이 파일만으로는 산출 불가")

print("\n" + "=" * 74)
print("종합: " + ("모든 전제 성립 — 산출값 신뢰 가능" if ok else "전제 위반 — 산출 로직 재검토 필요"))
print("=" * 74)
sys.exit(0 if ok else 1)
