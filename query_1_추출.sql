/* ============================================================================
   [2단계] 본 추출 쿼리 — 적정 판매가 산출용
   ============================================================================
   확인된 스키마
     srType 'R' = 발주 : 수량은 releaseEa, storeEa = 0
     srType 'S' = 입고 : 수량은 storeEa,   releaseEa = 0
     srPrice = 1개당 단가 (합계금액 아님), 자료형 INT

   설계 요지
   ---------
   1) stockNo 단위로 '한 건의 매입'을 확정한다              ★ 핵심
      R(발주)과 S(입고)는 같은 매입의 두 단계다. 둘을 그냥 평균내면 같은 거래를
      두 번 세게 된다. stockNo 로 묶어 건당 원가를 하나로 정한다.
        확정원가 = 입고단가가 있으면 입고단가, 없으면(0/미기재) 발주단가
      실제로 지불한 값은 입고단가이므로 그쪽을 우선한다.

   2) 0원은 '무료'가 아니라 '미기재'다
      NULLIF(단가,0) 으로 걸러낸다. 전체의 약 45%가 0원이라 그대로 평균내면
      원가가 구조적으로 과소평가된다. 이 처리 하나로 종전의 추정
      (미기재율 45% 사전값·[하한,상한] 구간·신뢰등급) 이 전부 불필요해진다.

   3) ELSE 0 제거
      AVG(CASE WHEN ... THEN 단가 ELSE 0 END) 는 해당없는 행을 0으로 채워
      전체건수로 나눈다. ELSE 를 빼면 NULL 이 되어 AVG 가 무시한다.

   4) 수량 가중 평균원가 (이동평균원가)
      단가와 수량이 따로 있으므로 올바른 원가는 금액합 ÷ 수량합이다.
      1개 매입과 100개 매입을 같은 무게로 평균내면 안 된다.

   5) INT 절사 방지 — DECIMAL 캐스팅

   ※ 재고 주의
     이 테이블에는 출고(판매/불출) 기록이 없다. 따라서 현재고를 계산할 수 없다.
     아래 [미출고기준_누적입고수량] 은 '입고된 총량'일 뿐 재고가 아니다.
     실제 재고는 출고 테이블이나 epmsPartStock 의 재고 컬럼이 필요하다.
   ============================================================================ */

DECLARE @기준일 DATE;
SELECT @기준일 = MAX(TRY_CONVERT(DATE, CONVERT(VARCHAR(8), regYmd, 112)))
FROM epmsPartStockStoreRelease (NOLOCK);

;WITH tx AS (
    SELECT
         EPS.stockNo
        ,EPS.partNo
        ,EPS.maker
        ,EPSR.srType
        ,NULLIF(EPSR.srPrice, 0)                                        AS 단가   /* 0 = 미기재 */
        ,EPSR.srPrice                                                   AS 원단가
        ,TRY_CONVERT(DATE, CONVERT(VARCHAR(8), EPSR.regYmd, 112))       AS dt
        ,ISNULL(EPSR.storeEa,   0)                                      AS 입고수량
        ,ISNULL(EPSR.releaseEa, 0)                                      AS 발주수량
    FROM epmsPartStock (NOLOCK) AS EPS
    INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR
            ON EPS.stockNo = EPSR.stockNo
),
/* ---- stockNo = 한 건의 매입. 발주/입고를 하나로 합쳐 원가를 확정한다 ---- */
lot AS (
    SELECT
         stockNo, partNo, maker
        ,MAX(CASE WHEN srType='S' THEN 단가 END)              AS 입고단가
        ,MAX(CASE WHEN srType='R' THEN 단가 END)              AS 발주단가
        /* 실지불액인 입고단가 우선, 없으면 발주단가로 보완 */
        ,COALESCE(MAX(CASE WHEN srType='S' THEN 단가 END)
                 ,MAX(CASE WHEN srType='R' THEN 단가 END))    AS 확정원가
        ,SUM(CASE WHEN srType='S' THEN 입고수량 ELSE 0 END)    AS 입고수량
        ,SUM(CASE WHEN srType='R' THEN 발주수량 ELSE 0 END)    AS 발주수량
        ,MAX(CASE WHEN srType='S' THEN dt END)                AS 입고일
        ,MIN(CASE WHEN srType='R' THEN dt END)                AS 발주일
        ,MAX(dt)                                              AS 최종일
        ,COUNT(*)                                             AS 행수
    FROM tx
    GROUP BY stockNo, partNo, maker
),
med AS (
    SELECT partNo, maker, MAX(m) AS 확정원가_중앙값
    FROM (
        SELECT partNo, maker
              ,PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY 확정원가)
                   OVER (PARTITION BY partNo, maker) AS m
        FROM lot WHERE 확정원가 > 0
    ) x GROUP BY partNo, maker
)
SELECT
     l.partNo                                                       AS [부품 품번]
    ,ISNULL(EPM.partKorName, '')                                    AS [부품명]
    ,l.maker                                                        AS [메이커]

    /* ---------- 매입 건수 ---------- */
    ,COUNT(*)                                                       AS [매입건수]
    ,SUM(CASE WHEN l.확정원가 > 0 THEN 1 ELSE 0 END)                 AS [원가확정건수]
    ,SUM(CASE WHEN l.확정원가 IS NULL THEN 1 ELSE 0 END)             AS [원가미상건수]
    ,SUM(CASE WHEN l.입고단가 IS NOT NULL THEN 1 ELSE 0 END)         AS [입고단가있음]
    ,SUM(CASE WHEN l.입고단가 IS NULL AND l.발주단가 IS NOT NULL
              THEN 1 ELSE 0 END)                                    AS [발주단가로보완]

    /* ---------- ★ 원가 (0원 제외, 매입건 단위로 중복 없이) ---------- */
    ,AVG(CAST(l.확정원가 AS DECIMAL(18,2)))                          AS [평균원가]
    ,m.확정원가_중앙값                                               AS [중앙값원가]
    ,MIN(l.확정원가)                                                 AS [최소원가]
    ,MAX(l.확정원가)                                                 AS [최대원가]
    /* 수량 가중 = 이동평균원가. 입고수량이 있는 건만 대상 */
    ,SUM(CAST(l.확정원가 AS DECIMAL(18,2)) * NULLIF(l.입고수량,0))
        / NULLIF(SUM(CASE WHEN l.확정원가 > 0 THEN NULLIF(l.입고수량,0) END), 0)
                                                                    AS [가중평균원가]

    /* ---------- 최근성 — 판매가 산정에 가장 유용 ---------- */
    ,MAX(l.입고일)                                                   AS [최종입고일]
    ,LT.최근원가                                                     AS [최근원가]
    ,LT.최근일                                                       AS [최근원가일]
    ,AVG(CAST(CASE WHEN l.최종일 >= DATEADD(MONTH,-12,@기준일)
                   THEN l.확정원가 END AS DECIMAL(18,2)))            AS [최근12개월_평균원가]
    ,SUM(CASE WHEN l.최종일 >= DATEADD(MONTH,-12,@기준일)
                   AND l.확정원가 > 0 THEN 1 ELSE 0 END)             AS [최근12개월_건수]
    ,AVG(CAST(CASE WHEN l.최종일 >= DATEADD(MONTH,-24,@기준일)
                   THEN l.확정원가 END AS DECIMAL(18,2)))            AS [최근24개월_평균원가]

    /* ---------- 수량 ---------- */
    ,SUM(CAST(l.입고수량 AS BIGINT))                                 AS [누적입고수량]
    ,SUM(CAST(l.발주수량 AS BIGINT))                                 AS [누적발주수량]
    /* 재고 아님 주의 — 출고 기록이 이 테이블에 없다 */

    /* ---------- 기존 산출물 대조용 ---------- */
    ,AVG(CAST(l.입고단가 AS DECIMAL(18,2)))                          AS [입고단가_평균]
    ,AVG(CAST(l.발주단가 AS DECIMAL(18,2)))                          AS [발주단가_평균]

FROM lot AS l
LEFT JOIN med AS m ON m.partNo = l.partNo AND m.maker = l.maker
OUTER APPLY (
    SELECT TOP 1 partKorName FROM epmsPartMst (NOLOCK) AS EPM
    WHERE EPM.partNo = l.partNo ORDER BY EPM.partId DESC
) AS EPM
OUTER APPLY (
    SELECT TOP 1 l2.확정원가 AS 최근원가, l2.최종일 AS 최근일
    FROM lot AS l2
    WHERE l2.partNo = l.partNo AND l2.maker = l.maker AND l2.확정원가 > 0
    ORDER BY l2.최종일 DESC
) AS LT
GROUP BY l.partNo, l.maker, EPM.partKorName, m.확정원가_중앙값, LT.최근원가, LT.최근일
ORDER BY COUNT(*) DESC;
