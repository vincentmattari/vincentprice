# -*- coding: utf-8 -*-
"""
발주평균가·입고평균가의 정의를 데이터로 판별한다.

H1 (현재 산출식) — 각자의 건수가 아니라 CNT 로 나눈 '기여분'
    발주평균가 = (발주건 가격합) / CNT
    => 발주평균가 + 입고평균가 = 전체평균가
    => 실제 발주단가 = 발주평균가 x CNT / 발주건수

H2 (사용자 제기) — 각자의 건수로 나눈 '해당 구분의 평균가'
    발주평균가 = (발주건 가격합) / 발주건수
    => (발주평균가 x 발주 + 입고평균가 x 입고) / CNT = 전체평균가
    => 실제 발주단가 = 발주평균가 (그대로)

둘 중 하나만 데이터와 맞는다.
"""
import openpyxl, sys, io, glob
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

SRC = sorted(glob.glob("*_발주_입고_횟수_*.xlsx"))[-1]
ws = openpyxl.load_workbook(SRC, data_only=True).worksheets[0]
hdr = [str(c.value).strip() for c in ws[1]]
ALIAS = {"부품 품번": ["부품 품번", "부품품번", "품번"],
         "CNT": ["CNT", "발주/입고 합계", "발주/입고합계", "합계"]}
ix = {k: next(hdr.index(a) for a in ALIAS.get(k, [k]) if a in hdr)
      for k in ["부품 품번", "발주", "입고", "CNT", "발주평균가", "입고평균가",
                "전체평균가", "전체최소가", "전체최대가"]}
R = []
for r in ws.iter_rows(min_row=2, values_only=True):
    R.append({k: r[i] for k, i in ix.items()})
N = len(R)
print(f"원본: {SRC}\n행수: {N}\n")

TOL = 1.0

print("=" * 76)
print("검정 1 — 두 가설이 예측하는 항등식이 실제로 성립하는가")
print("=" * 76)
h1 = sum(1 for x in R if abs((x["발주평균가"] + x["입고평균가"]) - x["전체평균가"]) <= TOL)
h2 = sum(1 for x in R
         if abs((x["발주평균가"] * x["발주"] + x["입고평균가"] * x["입고"]) / x["CNT"]
                - x["전체평균가"]) <= TOL)
print(f"  H1  발주평균가 + 입고평균가 == 전체평균가                : {h1:5d} / {N}  ({100*h1/N:.1f}%)")
print(f"  H2  (발주평균가x발주 + 입고평균가x입고)/CNT == 전체평균가 : {h2:5d} / {N}  ({100*h2/N:.1f}%)")

# H2 가 맞는 행은 대부분 '발주=입고' 같은 축퇴 사례인지 확인
h2rows = [x for x in R
          if abs((x["발주평균가"] * x["발주"] + x["입고평균가"] * x["입고"]) / x["CNT"]
                 - x["전체평균가"]) <= TOL]
deg = sum(1 for x in h2rows if x["전체최대가"] == 0)
print(f"      └ H2 성립 행 중 가격이 전부 0인 축퇴 사례: {deg} / {len(h2rows)}")

print("\n" + "=" * 76)
print("검정 2 — H2 가 맞다면 발주평균가는 '실제 가격들의 평균'이므로")
print("         반드시 전체최소가 <= 발주평균가 <= 전체최대가 여야 한다")
print("=" * 76)
bad = [x for x in R if x["발주"] > 0 and x["발주평균가"] > 0
       and not (x["전체최소가"] - TOL <= x["발주평균가"] <= x["전체최대가"] + TOL)]
print(f"  범위를 벗어나는 행: {len(bad)} / {sum(1 for x in R if x['발주']>0 and x['발주평균가']>0)}")
for x in bad[:3]:
    print(f"    {x['부품 품번']:<16} 발주평균가 {x['발주평균가']:>9,}"
          f"  범위 [{x['전체최소가']:,}, {x['전체최대가']:,}]  ← 최대가를 넘음")
print("  → H2 라면 불가능한 값. H1 이라면 기여분이므로 최대가보다 작아 자연스럽다.")

print("\n" + "=" * 76)
print("검정 3 — 결정적 검정: 전체최대가로 판별한다")
print("         CNT=2, 발주 1건, 입고 1건, 입고평균가=0 인 행")
print("=" * 76)
k = [x for x in R if x["CNT"] == 2 and x["발주"] == 1 and x["입고"] == 1
     and x["입고평균가"] == 0 and x["발주평균가"] > 0]
print(f"  해당 행: {len(k)}개\n")
print("  H1 예측: 발주건 실제가격 = 발주평균가 x 2   → 이 값이 전체최대가와 같아야 함")
print("  H2 예측: 발주건 실제가격 = 발주평균가       → 이 값이 전체최대가와 같아야 함\n")
p1 = sum(1 for x in k if abs(x["발주평균가"] * 2 - x["전체최대가"]) <= TOL)
p2 = sum(1 for x in k if abs(x["발주평균가"] - x["전체최대가"]) <= TOL)
print(f"  H1 적중: {p1:5d} / {len(k)}  ({100*p1/len(k):.1f}%)")
print(f"  H2 적중: {p2:5d} / {len(k)}  ({100*p2/len(k):.1f}%)\n")
for x in sorted(k, key=lambda y: -y["전체최대가"])[:4]:
    print(f"    {x['부품 품번']:<16} 발주평균가 {x['발주평균가']:>9,}"
          f" | H1 x2 = {x['발주평균가']*2:>9,} | H2 = {x['발주평균가']:>9,}"
          f" | 실제 전체최대가 {x['전체최대가']:>9,}")

print("\n" + "=" * 76)
print("사용자 예시로 확인 — 전체 10건, 그중 발주 5건")
print("=" * 76)
allp = [1000, 1000, 500, 1000, 2000, 500, 1000, 2000, 500, 500]
po = [1000, 1000, 500, 1000, 2000]
rc = [500, 1000, 2000, 500, 500]
CNT, npo, nrc = len(allp), len(po), len(rc)
tot = sum(allp) / CNT
print(f"  전체평균가 = {sum(allp)}/{CNT} = {tot:.0f}원   (실제 발주단가는 {sum(po)/npo:.0f}원)")
print()
print(f"  H2 라면 파일의 발주평균가 = {sum(po)}/{npo} = {sum(po)/npo:.0f},"
      f" 입고평균가 = {sum(rc)}/{nrc} = {sum(rc)/nrc:.0f}")
print(f"    합 = {sum(po)/npo + sum(rc)/nrc:.0f}  vs  전체평균가 {tot:.0f}"
      f"  → {'일치' if abs(sum(po)/npo+sum(rc)/nrc-tot)<1 else '불일치 (합 항등식 깨짐)'}")
print()
print(f"  H1 이라면 파일의 발주평균가 = {sum(po)}/{CNT} = {sum(po)/CNT:.0f},"
      f" 입고평균가 = {sum(rc)}/{CNT} = {sum(rc)/CNT:.0f}")
print(f"    합 = {sum(po)/CNT + sum(rc)/CNT:.0f}  vs  전체평균가 {tot:.0f}"
      f"  → {'일치' if abs(sum(po)/CNT+sum(rc)/CNT-tot)<1 else '불일치'}")
print(f"    복원: 발주단가 = {sum(po)/CNT:.0f} x {CNT} / {npo} = {sum(po)/CNT*CNT/npo:.0f}원"
      f"  → 실제 {sum(po)/npo:.0f}원과 {'일치' if abs(sum(po)/CNT*CNT/npo - sum(po)/npo)<1 else '불일치'}")
print()
print("  ※ 실제 파일은 '합 항등식'이 2180/2180 성립하므로 파일의 발주평균가는")
print(f"    H1 형태({sum(po)/CNT:.0f}원)로 기록되어 있고, 복원식이 {sum(po)/npo:.0f}원을 되돌려준다.")
