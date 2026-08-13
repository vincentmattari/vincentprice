/* ============================================================================
   [2단계] 본 추출 쿼리 — 적정 판매가 산출용
   ============================================================================
   용어 통일
     발주 = 출고 (재고에서 나감).  srType 'R', 수량 releaseEa
     입고            (재고로 들어옴). srType 'S', 수량 storeEa
     srPrice = 1개당 단가 (INT)
     epmsPartStockStoreRelease = 발주(출고)/입고 내역
     epmsPartStock             = 재고부품 기본정보

   핵심 구조
   ---------
   입고 단가 = 매입원가        <- 원가 계산은 여기서만
   발주 단가 = 판매가          <- 실제로 받아온 가격. 원가와 절대 섞지 않는다
   stockNo   = 재고 로트       <- 로트별 잔여수량으로 선입선출 원가를 구한다

   ★ 원래 문제였던 '선입선출 미관리'를 정면으로 푼다
     로트별 잔여수량 = 입고수량 - 출고수량
     보유재고원가   = SUM(잔여수량 x 로트입고단가) / SUM(잔여수량)
     전체 기간 평균이 아니라 '지금 들고 있는 재고'의 원가다.

   ★ 0원은 '무료'가 아니라 '미기재'다
     NULLIF(srPrice,0) 으로 제외한다. 전체의 약 45%가 0원이라 그대로 평균내면
     원가가 구조적으로 과소평가된다.
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
        ,NULLIF(EPSR.srPrice, 0)                                    AS 단가      /* 0 = 미기재 */
        ,TRY_CONVERT(DATE, CONVERT(VARCHAR(8), EPSR.regYmd, 112))   AS dt
        ,ISNULL(EPSR.storeEa,   0)                                  AS 입고수량
        ,ISNULL(EPSR.releaseEa, 0)                                  AS 출고수량
    FROM epmsPartStock (NOLOCK) AS EPS
    INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR
            ON EPS.stockNo = EPSR.stockNo
),
/* ---- stockNo = 재고 로트. 로트별 잔여수량과 매입원가 ---- */
lot AS (
    SELECT
         stockNo, partNo, maker
        ,SUM(입고수량)                                   AS 로트입고수량
        ,SUM(출고수량)                                   AS 로트출고수량
        ,SUM(입고수량) - SUM(출고수량)                    AS 잔여수량
        ,MAX(CASE WHEN srType='S' THEN 단가 END)         AS 로트원가      /* 입고단가 = 매입원가 */
        ,MIN(CASE WHEN srType='S' THEN dt END)           AS 입고일
        ,MAX(CASE WHEN srType='R' THEN dt END)           AS 최종출고일
    FROM tx
    GROUP BY stockNo, partNo, maker
),
/* ---- 발주(출고) = 판매 실적. 원가와 분리해서 집계 ---- */
sale AS (
    SELECT
         partNo, maker
        ,COUNT(*)                                                       AS 출고건수
        ,SUM(CASE WHEN 단가 IS NOT NULL THEN 1 ELSE 0 END)               AS 판매가기재건수
        ,AVG(CAST(단가 AS DECIMAL(18,2)))                                AS 평균판매가
        ,SUM(CAST(단가 AS DECIMAL(18,2)) * NULLIF(출고수량,0))
            / NULLIF(SUM(CASE WHEN 단가 IS NOT NULL THEN NULLIF(출고수량,0) END),0) AS 가중평균판매가
        ,MIN(단가)                                                       AS 최소판매가
        ,MAX(단가)                                                       AS 최대판매가
        ,SUM(CAST(출고수량 AS BIGINT))                                    AS 총출고수량
        ,SUM(CASE WHEN dt >= DATEADD(MONTH,-12,@기준일)
                  THEN CAST(출고수량 AS BIGINT) ELSE 0 END)               AS 최근12개월_출고수량
        ,AVG(CAST(CASE WHEN dt >= DATEADD(MONTH,-12,@기준일) THEN 단가 END AS DECIMAL(18,2)))
                                                                        AS 최근12개월_평균판매가
    FROM tx
    WHERE srType = 'R'
    GROUP BY partNo, maker
),
/* ---- 매입(입고) = 원가 ---- */
buy AS (
    SELECT
         partNo, maker
        ,COUNT(*)                                                       AS 입고건수
        ,SUM(CASE WHEN 단가 IS NOT NULL THEN 1 ELSE 0 END)               AS 원가기재건수
        ,AVG(CAST(단가 AS DECIMAL(18,2)))                                AS 평균원가
        ,SUM(CAST(단가 AS DECIMAL(18,2)) * NULLIF(입고수량,0))
            / NULLIF(SUM(CASE WHEN 단가 IS NOT NULL THEN NULLIF(입고수량,0) END),0) AS 가중평균원가
        ,MIN(단가)                                                       AS 최소원가
        ,MAX(단가)                                                       AS 최대원가
        ,SUM(CAST(입고수량 AS BIGINT))                                    AS 총입고수량
        ,AVG(CAST(CASE WHEN dt >= DATEADD(MONTH,-12,@기준일) THEN 단가 END AS DECIMAL(18,2)))
                                                                        AS 최근12개월_평균원가
    FROM tx
    WHERE srType = 'S'
    GROUP BY partNo, maker
)
SELECT
     l.partNo                                                       AS [부품 품번]
    ,ISNULL(EPM.partKorName, '')                                    AS [부품명]
    ,l.maker                                                        AS [메이커]

    /* ---------- ★ 재고 ---------- */
    ,SUM(CAST(l.로트입고수량 AS BIGINT))                             AS [총입고수량]
    ,SUM(CAST(l.로트출고수량 AS BIGINT))                             AS [총출고수량]
    ,SUM(CAST(l.잔여수량     AS BIGINT))                             AS [현재고수량]
    ,CASE WHEN SUM(CAST(l.잔여수량 AS BIGINT)) > 0 THEN 'Y' ELSE 'N' END AS [재고보유]
    ,COUNT(*)                                                       AS [로트수]
    ,SUM(CASE WHEN l.잔여수량 > 0 THEN 1 ELSE 0 END)                 AS [잔여로트수]

    /* ---------- ★ 선입선출 — 지금 보유한 재고의 원가 ---------- */
    ,SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
              THEN CAST(l.로트원가 AS DECIMAL(18,2)) * l.잔여수량 END)   AS [보유재고_평가액]
    ,SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
              THEN l.잔여수량 END)                                       AS [보유재고_원가확인수량]
    ,SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
              THEN CAST(l.로트원가 AS DECIMAL(18,2)) * l.잔여수량 END)
        / NULLIF(SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
                          THEN l.잔여수량 END), 0)                       AS [보유재고_단위원가]
    ,MAX(CASE WHEN l.잔여수량 > 0 THEN l.입고일 END)                     AS [보유재고_최종입고일]

    /* ---------- 매입 원가 (입고 기준) ---------- */
    ,MAX(b.입고건수)                                                AS [입고건수]
    ,MAX(b.원가기재건수)                                            AS [원가기재건수]
    ,MAX(b.입고건수) - MAX(b.원가기재건수)                           AS [원가미기재건수]
    ,MAX(b.평균원가)                                                AS [평균원가]
    ,MAX(b.가중평균원가)                                            AS [가중평균원가]
    ,MAX(b.최소원가)                                                AS [최소원가]
    ,MAX(b.최대원가)                                                AS [최대원가]
    ,MAX(b.최근12개월_평균원가)                                      AS [최근12개월_평균원가]
    ,LB.최근원가                                                    AS [최근매입원가]
    ,LB.최근일                                                      AS [최근매입일]

    /* ---------- 판매 실적 (발주/출고 기준) ---------- */
    ,MAX(s.출고건수)                                                AS [출고건수]
    ,MAX(s.판매가기재건수)                                          AS [판매가기재건수]
    ,MAX(s.평균판매가)                                              AS [평균판매가]
    ,MAX(s.가중평균판매가)                                          AS [가중평균판매가]
    ,MAX(s.최소판매가)                                              AS [최소판매가]
    ,MAX(s.최대판매가)                                              AS [최대판매가]
    ,MAX(s.최근12개월_평균판매가)                                    AS [최근12개월_평균판매가]
    ,MAX(s.최근12개월_출고수량)                                      AS [최근12개월_출고수량]
    ,LS.최근판매가                                                  AS [최근판매가]
    ,LS.최근일                                                      AS [최근판매일]

    /* ---------- ★ 실현 마진 — 그동안 실제로 붙여온 마진율 ---------- */
    ,MAX(s.가중평균판매가) / NULLIF(MAX(b.가중평균원가), 0)           AS [실현마진배수]
    ,CAST(100.0 * (MAX(s.가중평균판매가) / NULLIF(MAX(b.가중평균원가),0) - 1)
          AS DECIMAL(10,1))                                        AS [실현마진율_퍼센트]

FROM lot AS l
LEFT JOIN buy  AS b ON b.partNo = l.partNo AND b.maker = l.maker
LEFT JOIN sale AS s ON s.partNo = l.partNo AND s.maker = l.maker
OUTER APPLY (
    SELECT TOP 1 partKorName FROM epmsPartMst (NOLOCK) AS EPM
    WHERE EPM.partNo = l.partNo ORDER BY EPM.partId DESC
) AS EPM
/* 가장 최근에 단가가 기재된 매입 */
OUTER APPLY (
    SELECT TOP 1 t.단가 AS 최근원가, t.dt AS 최근일
    FROM tx AS t
    WHERE t.partNo = l.partNo AND t.maker = l.maker
      AND t.srType = 'S' AND t.단가 IS NOT NULL
    ORDER BY t.dt DESC
) AS LB
/* 가장 최근에 단가가 기재된 판매 */
OUTER APPLY (
    SELECT TOP 1 t.단가 AS 최근판매가, t.dt AS 최근일
    FROM tx AS t
    WHERE t.partNo = l.partNo AND t.maker = l.maker
      AND t.srType = 'R' AND t.단가 IS NOT NULL
    ORDER BY t.dt DESC
) AS LS
GROUP BY l.partNo, l.maker, EPM.partKorName,
         LB.최근원가, LB.최근일, LS.최근판매가, LS.최근일
ORDER BY SUM(CAST(l.잔여수량 AS BIGINT)) DESC, COUNT(*) DESC;
