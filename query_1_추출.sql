/* ============================================================================
   [2단계] 본 추출 쿼리 — 적정 판매가 산출용
   ============================================================================
   기존 쿼리 대비 달라진 점

   1) ELSE 0 제거
      AVG(CASE WHEN srType='R' THEN srPrice ELSE 0 END) 는 해당하지 않는 행을 0으로
      채워 '전체건수'로 나눈다. 그래서 값이 단가가 아니라 기여분이 되고,
      R평균가 + S평균가 = 전체평균가 라는 관계가 생겼다.
      ELSE 를 빼면 NULL 이 되고 AVG 는 NULL 을 무시하므로 해당 구분만의 진짜 평균이 나온다.

   2) 0원(미기재) 분리  ★ 가장 중요
      srPrice = 0 은 '무료'가 아니라 '가격 미기재'다. 전체의 약 45%가 여기 해당해
      평균을 구조적으로 끌어내리고 있었다. 0을 뺀 '유효' 값이 실제 원가다.
      이 컬럼이 있으면 추정(미기재율 사전값·구간·신뢰등급)이 더 이상 필요 없다.

   3) 수량 가중 평균단가 추가  ★
      srPrice 가 1개당 단가이고 수량이 따로 있으므로, 올바른 원가는 단순평균이 아니라
      금액합 ÷ 수량합 이다 (이동평균원가). 1개 들여온 건과 100개 들여온 건을
      같은 무게로 평균내면 안 된다.

   4) INT 절사 방지
      srPrice 가 INT 라 AVG(int) 가 정수를 반환하며 소수점을 버린다 (76행에서 1원 오차).
      DECIMAL 로 캐스팅해 해결한다.

   5) regYmd 기반 최근성 · 수량 기반 재고 추가
      최근 매입단가가 판매가 산정에 가장 유용하다. 재고 유무로 대상을 좁힐 수 있다.

   ----------------------------------------------------------------------------
   ※ 컬럼명을 R_/S_ 로 중립 표기했다.
     srType R 이 발주인지 출고인지 확정 전이기 때문이다(진단쿼리 3번 참조).
     R 이 출고로 확인되면 R_ 값은 원가가 아니라 '실제 판매가' 로 읽어야 한다.
   ============================================================================ */

DECLARE @기준일 DATE;
SELECT @기준일 = MAX(TRY_CONVERT(DATE, CONVERT(VARCHAR(8), regYmd, 112)))
FROM epmsPartStockStoreRelease (NOLOCK);

;WITH tx AS (
    SELECT
         EPS.partNo
        ,EPS.maker
        ,EPSR.srType
        ,EPSR.srPrice                                                   AS 단가
        ,TRY_CONVERT(DATE, CONVERT(VARCHAR(8), EPSR.regYmd, 112))       AS dt
        ,ISNULL(EPSR.storeEa,   0)                                      AS 입고수량
        ,ISNULL(EPSR.releaseEa, 0)                                      AS 출고수량
    FROM epmsPartStock (NOLOCK) AS EPS
    INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR
            ON EPS.stockNo = EPSR.stockNo
),
/* 유효(0원 제외) 단가의 중앙값 — 로트별 편차에 평균보다 견고하다 */
med AS (
    SELECT partNo, maker
          ,MAX(m_all) AS 유효중앙값
          ,MAX(m_s)   AS S_유효중앙값
    FROM (
        SELECT partNo, maker
              ,PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY 단가)
                   OVER (PARTITION BY partNo, maker) AS m_all
              ,PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN srType='S' THEN 단가 END)
                   OVER (PARTITION BY partNo, maker) AS m_s
        FROM tx
        WHERE 단가 > 0
    ) x
    GROUP BY partNo, maker
)
SELECT
     t.partNo                                                       AS [부품 품번]
    ,ISNULL(EPM.partKorName, '')                                    AS [부품명]
    ,t.maker                                                        AS [메이커]

    /* ---------- 건수 ---------- */
    ,SUM(CASE WHEN t.srType='R' THEN 1 ELSE 0 END)                  AS [R_건수]
    ,SUM(CASE WHEN t.srType='S' THEN 1 ELSE 0 END)                  AS [S_건수]
    ,COUNT(*)                                                       AS [전체건수]
    ,SUM(CASE WHEN t.단가 > 0 THEN 1 ELSE 0 END)                     AS [유가건수]
    ,SUM(CASE WHEN ISNULL(t.단가,0) <= 0 THEN 1 ELSE 0 END)          AS [미기재건수]

    /* ---------- 0원 제외한 '유효' 단가 (★ 실제 원가) ---------- */
    ,AVG(CAST(CASE WHEN t.단가 > 0 THEN t.단가 END AS DECIMAL(18,2)))                    AS [유효평균단가]
    ,AVG(CAST(CASE WHEN t.srType='S' AND t.단가 > 0 THEN t.단가 END AS DECIMAL(18,2)))   AS [S_유효평균단가]
    ,AVG(CAST(CASE WHEN t.srType='R' AND t.단가 > 0 THEN t.단가 END AS DECIMAL(18,2)))   AS [R_유효평균단가]
    ,MIN(CASE WHEN t.단가 > 0 THEN t.단가 END)                        AS [유효최소단가]
    ,MAX(t.단가)                                                     AS [유효최대단가]
    ,m.유효중앙값                                                    AS [유효중앙단가]
    ,m.S_유효중앙값                                                  AS [S_유효중앙단가]

    /* ---------- 수량 가중 평균단가 (★ 이동평균원가) ----------
       금액합 ÷ 수량합. 0원 건은 금액·수량 모두에서 제외해야 왜곡이 없다. */
    ,SUM(CASE WHEN t.srType='S' AND t.단가 > 0
              THEN CAST(t.단가 AS DECIMAL(18,2)) * t.입고수량 END)     AS [S_유효금액합]
    ,SUM(CASE WHEN t.srType='S' AND t.단가 > 0 THEN t.입고수량 END)    AS [S_유효수량합]
    ,SUM(CASE WHEN t.srType='S' AND t.단가 > 0
              THEN CAST(t.단가 AS DECIMAL(18,2)) * t.입고수량 END)
        / NULLIF(SUM(CASE WHEN t.srType='S' AND t.단가 > 0 THEN t.입고수량 END), 0)
                                                                    AS [S_가중평균단가]
    ,SUM(CASE WHEN t.srType='R' AND t.단가 > 0
              THEN CAST(t.단가 AS DECIMAL(18,2)) * t.출고수량 END)
        / NULLIF(SUM(CASE WHEN t.srType='R' AND t.단가 > 0 THEN t.출고수량 END), 0)
                                                                    AS [R_가중평균단가]

    /* ---------- 최근성 (regYmd) ---------- */
    ,MIN(t.dt)                                                      AS [최초등록일]
    ,MAX(t.dt)                                                      AS [최종등록일]
    ,MAX(CASE WHEN t.srType='S' AND t.단가 > 0 THEN t.dt END)        AS [최종매입일]
    ,LS.최근단가                                                     AS [S_최근단가]
    ,LS.최근일                                                       AS [S_최근단가일]
    ,LR.최근단가                                                     AS [R_최근단가]
    ,LR.최근일                                                       AS [R_최근단가일]
    ,AVG(CAST(CASE WHEN t.srType='S' AND t.단가 > 0 AND t.dt >= DATEADD(MONTH,-12,@기준일)
                   THEN t.단가 END AS DECIMAL(18,2)))                AS [S_최근12개월_평균단가]
    ,SUM(CASE WHEN t.srType='S' AND t.단가 > 0 AND t.dt >= DATEADD(MONTH,-12,@기준일)
              THEN 1 ELSE 0 END)                                    AS [S_최근12개월_건수]
    ,AVG(CAST(CASE WHEN t.srType='S' AND t.단가 > 0 AND t.dt >= DATEADD(MONTH,-24,@기준일)
                   THEN t.단가 END AS DECIMAL(18,2)))                AS [S_최근24개월_평균단가]

    /* ---------- 재고 ---------- */
    ,SUM(CAST(t.입고수량 AS BIGINT))                                 AS [입고수량합]
    ,SUM(CAST(t.출고수량 AS BIGINT))                                 AS [출고수량합]
    ,SUM(CAST(t.입고수량 AS BIGINT)) - SUM(CAST(t.출고수량 AS BIGINT)) AS [현재고]
    ,CASE WHEN SUM(CAST(t.입고수량 AS BIGINT)) - SUM(CAST(t.출고수량 AS BIGINT)) > 0
          THEN 'Y' ELSE 'N' END                                     AS [재고보유]

    /* ---------- 기존 컬럼 (이전 산출물과 대조용) ---------- */
    ,AVG(CAST(CASE WHEN t.srType='R' THEN t.단가 ELSE 0 END AS DECIMAL(18,2))) AS [구_발주평균가]
    ,AVG(CAST(CASE WHEN t.srType='S' THEN t.단가 ELSE 0 END AS DECIMAL(18,2))) AS [구_입고평균가]
    ,AVG(CAST(t.단가 AS DECIMAL(18,2)))                              AS [구_전체평균가]
    ,MIN(t.단가)                                                     AS [구_전체최소가]

FROM tx AS t
LEFT JOIN med AS m ON m.partNo = t.partNo AND m.maker = t.maker
OUTER APPLY (
    SELECT TOP 1 partKorName
    FROM epmsPartMst (NOLOCK) AS EPM
    WHERE EPM.partNo = t.partNo
    ORDER BY EPM.partId DESC
) AS EPM
/* 가장 최근에 가격이 기재된 거래의 단가 — 판매가 산정에 가장 유용하다 */
OUTER APPLY (
    SELECT TOP 1 t2.단가 AS 최근단가, t2.dt AS 최근일
    FROM tx AS t2
    WHERE t2.partNo = t.partNo AND t2.maker = t.maker
      AND t2.srType = 'S' AND t2.단가 > 0
    ORDER BY t2.dt DESC
) AS LS
OUTER APPLY (
    SELECT TOP 1 t2.단가 AS 최근단가, t2.dt AS 최근일
    FROM tx AS t2
    WHERE t2.partNo = t.partNo AND t2.maker = t.maker
      AND t2.srType = 'R' AND t2.단가 > 0
    ORDER BY t2.dt DESC
) AS LR
GROUP BY
     t.partNo, t.maker, EPM.partKorName
    ,m.유효중앙값, m.S_유효중앙값
    ,LS.최근단가, LS.최근일, LR.최근단가, LR.최근일
ORDER BY COUNT(*) DESC;
