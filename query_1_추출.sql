/* ============================================================================
   [2단계] 본 추출 쿼리  —  SQL Server 2005/2008 호환
   ============================================================================
   2012+ 함수(TRY_CONVERT, PERCENTILE_CONT, IIF, CONCAT, LAG)는 쓰지 않는다.

   용어
     발주 = 출고 (재고에서 나감). srType 'R', 수량 releaseEa, 단가 = 판매가
     입고            (재고로 들어옴). srType 'S', 수량 storeEa,   단가 = 매입원가
     stockNo = 재고 로트

   0원의 두 가지 성격 (스크린샷으로 확인)
     218823100C  입고 55,000 -> 출고 0        = 판매가 미기재
     1778810600  입고 0(한성에서 무료) -> 출고 0 = 정당한 무상
     로트 안에서 입고/출고 단가를 교차로 보면 어느 쪽인지 상당 부분 갈린다.
     발생사유 컬럼을 알게 되면 '무료/무상/서비스' 문구로 확정할 수 있다.
     ▼ TODO 로 표시한 곳에 실제 컬럼명을 넣으면 정확도가 올라간다.

   수량 이상치
     N90855001 의 출고수량 -7 같은 오입력이 있다. 음수는 0으로 보정하고
     [수량이상] 플래그로 남겨 검토 대상으로 표시한다.
     재고수량의 최소값은 0 이다.
   ============================================================================ */

;WITH tx AS (
    SELECT
         EPS.stockNo
        ,EPS.partNo
        ,EPS.maker
        ,EPSR.srType
        ,NULLIF(EPSR.srPrice, 0)                                    AS 단가       /* 0 = 미기재 또는 무상 */
        ,EPSR.srPrice                                               AS 원단가
        /* 등록일. 실입출고일 컬럼을 알면 그쪽이 더 정확하다
           ▼ TODO: regYmd -> 실입출고일 컬럼명으로 교체 검토 */
        ,CASE WHEN ISDATE(EPSR.regYmd) = 1
              THEN CONVERT(DATETIME, EPSR.regYmd) END               AS dt
        /* 음수 수량은 오입력이므로 0 으로 보정, 원본은 따로 보존 */
        ,CASE WHEN ISNULL(EPSR.storeEa,0)   < 0 THEN 0 ELSE ISNULL(EPSR.storeEa,0)   END AS 입고수량
        ,CASE WHEN ISNULL(EPSR.releaseEa,0) < 0 THEN 0 ELSE ISNULL(EPSR.releaseEa,0) END AS 출고수량
        ,CASE WHEN ISNULL(EPSR.storeEa,0) < 0 OR ISNULL(EPSR.releaseEa,0) < 0
              THEN 1 ELSE 0 END                                     AS 수량이상
        /* ▼ TODO: 발생사유 컬럼을 알면 아래를 살려서 무상 여부를 확정
        ,CASE WHEN EPSR.[발생사유] LIKE '%무료%' OR EPSR.[발생사유] LIKE '%무상%'
                OR EPSR.[발생사유] LIKE '%서비스%' THEN 1 ELSE 0 END AS 무상표기
        */
    FROM epmsPartStock (NOLOCK) AS EPS
    INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR
            ON EPS.stockNo = EPSR.stockNo
),
/* ---- stockNo = 재고 로트 ---- */
lot AS (
    SELECT
         stockNo, partNo, maker
        ,SUM(입고수량)                                       AS 로트입고수량
        ,SUM(출고수량)                                       AS 로트출고수량
        ,SUM(입고수량) - SUM(출고수량)                        AS 잔여수량_원본
        ,MAX(CASE WHEN srType='S' THEN 단가 END)             AS 로트원가      /* 입고단가 */
        ,MAX(CASE WHEN srType='R' THEN 단가 END)             AS 로트최대판매가
        ,SUM(CASE WHEN srType='R' THEN 1 ELSE 0 END)         AS 로트출고건수
        ,MIN(CASE WHEN srType='S' THEN dt END)               AS 입고일
        ,MAX(dt)                                             AS 최종일
        ,MAX(수량이상)                                        AS 수량이상
    FROM tx
    GROUP BY stockNo, partNo, maker
),
/* ---- 매입(입고) = 원가.  0원 제외 ---- */
buy AS (
    SELECT
         partNo, maker
        ,COUNT(*)                                                   AS 입고건수
        ,SUM(CASE WHEN 단가 IS NOT NULL THEN 1 ELSE 0 END)           AS 원가기재건수
        ,AVG(CAST(단가 AS DECIMAL(18,2)))                            AS 평균원가
        ,MIN(단가)                                                   AS 최소원가
        ,MAX(단가)                                                   AS 최대원가
        /* 수량 가중 = 이동평균원가 */
        ,SUM(CASE WHEN 단가 IS NOT NULL
                  THEN CAST(단가 AS DECIMAL(18,2)) * 입고수량 END)
         / NULLIF(SUM(CASE WHEN 단가 IS NOT NULL THEN 입고수량 END),0) AS 가중평균원가
        ,SUM(CAST(입고수량 AS BIGINT))                               AS 총입고수량
    FROM tx
    WHERE srType = 'S'
    GROUP BY partNo, maker
),
/* ---- 발주(출고) = 판매 실적.  0원 제외 ---- */
sale AS (
    SELECT
         partNo, maker
        ,COUNT(*)                                                   AS 출고건수
        ,SUM(CASE WHEN 단가 IS NOT NULL THEN 1 ELSE 0 END)           AS 판매가기재건수
        ,AVG(CAST(단가 AS DECIMAL(18,2)))                            AS 평균판매가
        ,MIN(단가)                                                   AS 최소판매가
        ,MAX(단가)                                                   AS 최대판매가
        ,SUM(CASE WHEN 단가 IS NOT NULL
                  THEN CAST(단가 AS DECIMAL(18,2)) * 출고수량 END)
         / NULLIF(SUM(CASE WHEN 단가 IS NOT NULL THEN 출고수량 END),0) AS 가중평균판매가
        ,SUM(CAST(출고수량 AS BIGINT))                               AS 총출고수량
    FROM tx
    WHERE srType = 'R'
    GROUP BY partNo, maker
)
SELECT
     l.partNo                                                       AS [부품 품번]
    ,ISNULL(EPM.partKorName, '')                                    AS [부품명]
    ,l.maker                                                        AS [메이커]

    /* ---------- 재고 (최소 0) ---------- */
    ,SUM(CAST(l.로트입고수량 AS BIGINT))                             AS [총입고수량]
    ,SUM(CAST(l.로트출고수량 AS BIGINT))                             AS [총출고수량]
    ,CASE WHEN SUM(CAST(l.잔여수량_원본 AS BIGINT)) < 0 THEN 0
          ELSE SUM(CAST(l.잔여수량_원본 AS BIGINT)) END              AS [현재고수량]
    ,CASE WHEN SUM(CAST(l.잔여수량_원본 AS BIGINT)) > 0 THEN 'Y' ELSE 'N' END AS [재고보유]
    ,CASE WHEN SUM(CAST(l.잔여수량_원본 AS BIGINT)) < 0 THEN 'Y' ELSE 'N' END AS [재고음수_검토]
    ,MAX(l.수량이상)                                                 AS [수량이상_검토]
    ,COUNT(*)                                                       AS [로트수]
    ,SUM(CASE WHEN l.잔여수량_원본 > 0 THEN 1 ELSE 0 END)            AS [잔여로트수]

    /* ---------- ★ 선입선출 — 지금 보유한 재고의 원가 ---------- */
    ,SUM(CASE WHEN l.잔여수량_원본 > 0 AND l.로트원가 IS NOT NULL
              THEN CAST(l.로트원가 AS DECIMAL(18,2)) * l.잔여수량_원본 END) AS [보유재고_평가액]
    ,SUM(CASE WHEN l.잔여수량_원본 > 0 AND l.로트원가 IS NOT NULL
              THEN l.잔여수량_원본 END)                              AS [보유재고_원가확인수량]
    ,SUM(CASE WHEN l.잔여수량_원본 > 0 AND l.로트원가 IS NOT NULL
              THEN CAST(l.로트원가 AS DECIMAL(18,2)) * l.잔여수량_원본 END)
     / NULLIF(SUM(CASE WHEN l.잔여수량_원본 > 0 AND l.로트원가 IS NOT NULL
                       THEN l.잔여수량_원본 END), 0)                 AS [보유재고_단위원가]

    /* ---------- 0원의 성격 (로트 단위 교차 판정) ---------- */
    ,SUM(CASE WHEN l.로트원가 IS NULL AND l.로트최대판매가 IS NOT NULL
              THEN 1 ELSE 0 END)                                    AS [원가미기재_로트]   /* 팔았으니 무상 아님 */
    ,SUM(CASE WHEN l.로트원가 IS NOT NULL AND l.로트최대판매가 IS NULL
                   AND l.로트출고건수 > 0 THEN 1 ELSE 0 END)         AS [판매가미기재_로트]
    ,SUM(CASE WHEN l.로트원가 IS NULL AND l.로트최대판매가 IS NULL
              THEN 1 ELSE 0 END)                                    AS [무상추정_로트]

    /* ---------- 매입 원가 ---------- */
    ,MAX(b.입고건수)                                                AS [입고건수]
    ,MAX(b.원가기재건수)                                            AS [원가기재건수]
    ,MAX(b.평균원가)                                                AS [평균원가]
    ,MAX(b.가중평균원가)                                            AS [가중평균원가]
    ,MAX(b.최소원가)                                                AS [최소원가]
    ,MAX(b.최대원가)                                                AS [최대원가]
    ,LB.최근원가                                                    AS [최근매입원가]
    ,CONVERT(VARCHAR(10), LB.최근일, 23)                            AS [최근매입일]

    /* ---------- 판매 실적 ---------- */
    ,MAX(s.출고건수)                                                AS [출고건수]
    ,MAX(s.판매가기재건수)                                          AS [판매가기재건수]
    ,MAX(s.평균판매가)                                              AS [평균판매가]
    ,MAX(s.가중평균판매가)                                          AS [가중평균판매가]
    ,MAX(s.최소판매가)                                              AS [최소판매가]
    ,MAX(s.최대판매가)                                              AS [최대판매가]
    ,LS.최근판매가                                                  AS [최근판매가]
    ,CONVERT(VARCHAR(10), LS.최근일, 23)                            AS [최근판매일]

    /* ---------- 실현 마진 — 그동안 실제로 붙여온 마진 ---------- */
    ,CAST(MAX(s.가중평균판매가) / NULLIF(MAX(b.가중평균원가),0) AS DECIMAL(10,3)) AS [실현마진배수]

FROM lot AS l
LEFT JOIN buy  AS b ON b.partNo = l.partNo AND b.maker = l.maker
LEFT JOIN sale AS s ON s.partNo = l.partNo AND s.maker = l.maker
OUTER APPLY (
    SELECT TOP 1 partKorName FROM epmsPartMst (NOLOCK) AS EPM
    WHERE EPM.partNo = l.partNo ORDER BY EPM.partId DESC
) AS EPM
OUTER APPLY (
    SELECT TOP 1 t.단가 AS 최근원가, t.dt AS 최근일
    FROM tx AS t
    WHERE t.partNo = l.partNo AND t.maker = l.maker
      AND t.srType = 'S' AND t.단가 IS NOT NULL
    ORDER BY t.dt DESC
) AS LB
OUTER APPLY (
    SELECT TOP 1 t.단가 AS 최근판매가, t.dt AS 최근일
    FROM tx AS t
    WHERE t.partNo = l.partNo AND t.maker = l.maker
      AND t.srType = 'R' AND t.단가 IS NOT NULL
    ORDER BY t.dt DESC
) AS LS
GROUP BY l.partNo, l.maker, EPM.partKorName,
         LB.최근원가, LB.최근일, LS.최근판매가, LS.최근일
ORDER BY COUNT(*) DESC;
