/* ============================================================================
   [2단계] 본 추출 쿼리  —  적정 판매가 산출용
   ============================================================================
   환경 : SQL Server 2019 엔진, DB 호환성 수준 100 (2008)
          -> TRY_CONVERT / PERCENTILE_CONT / IIF / CONCAT / LAG 사용 불가

   확정된 스키마
     srType    nchar(2)      'S' = 입고(원가),  'R' = 발주/출고(판매가)
     storeEa   int           입고수량
     releaseEa int           출고수량
     srPrice   int           1개당 단가 (0 = 미기재 또는 무상)
     srDesc    nvarchar(2000) 발생사유  <- '한성에서 무료' 처럼 무상 여부가 적힌다
     srRealYmd smalldatetime 실입출고일 <- 선입선출 기준일. 등록일(regYmd) 아님
     stockNo   int           재고 로트

   ※ 사용하지 않기로 확인된 컬럼
     supplyCompanyNo (공급처) — 대부분 미입력
     epmsPartStock 의 optimumEa / prevCenterPrice / centerPrice / purchasePrice
       — 대부분 0 이라 대체 가격원으로 쓸 수 없다.
       따라서 입고 단가가 없는 부품은 이 데이터만으로 원가를 알 수 없고,
       외부 가격표(제조사 MSRP, 공급처 견적)를 붙이는 수밖에 없다.

   설계
     1) 로트(stockNo) 단위로 잔여수량 = 입고 - 출고
        stockNo 의 85%가 입고 1건이지만 15%는 여러 건이므로
        로트원가는 MAX 가 아니라 '수량가중 평균'으로 구한다.
     2) 보유재고 단위원가 = SUM(잔여수량 x 로트원가) / SUM(잔여수량)
        전체 기간 평균이 아니라 지금 들고 있는 재고의 원가다.
        원래 문제였던 '선입선출 미관리'를 정면으로 푼다.
     3) 0원은 srDesc 로 무상/미기재를 갈라낸다.
        무상이면 원가 0 이 맞고, 미기재면 원가 계산에서 빼야 한다.
     4) 음수 수량 3건(C2C3563 -3, N90855001 -7, NQ0810.. -1)은 오입력이므로
        0 으로 보정하고 플래그로 남긴다. 그대로 두면 재고가 오히려 늘어난다.
   ============================================================================ */

;WITH tx AS (
    SELECT
         EPS.stockNo
        ,EPS.partNo
        ,EPS.maker
        ,LTRIM(RTRIM(EPSR.srType))                                  AS srType
        ,NULLIF(EPSR.srPrice, 0)                                    AS 단가
        ,EPSR.srRealYmd                                             AS dt
        ,EPSR.srDesc                                                AS 사유
        /* 음수 수량은 오입력 -> 0 으로 보정 */
        ,CASE WHEN ISNULL(EPSR.storeEa,0)   < 0 THEN 0 ELSE ISNULL(EPSR.storeEa,0)   END AS 입고수량
        ,CASE WHEN ISNULL(EPSR.releaseEa,0) < 0 THEN 0 ELSE ISNULL(EPSR.releaseEa,0) END AS 출고수량
        ,CASE WHEN ISNULL(EPSR.storeEa,0) < 0 OR ISNULL(EPSR.releaseEa,0) < 0
              THEN 1 ELSE 0 END                                     AS 수량이상
        /* 발생사유에 무상 표기가 있는가 */
        ,CASE WHEN EPSR.srDesc LIKE N'%무료%' OR EPSR.srDesc LIKE N'%무상%'
                OR EPSR.srDesc LIKE N'%서비스%' OR EPSR.srDesc LIKE N'%증정%'
                OR EPSR.srDesc LIKE N'%샘플%'
              THEN 1 ELSE 0 END                                     AS 무상표기
    FROM epmsPartStock (NOLOCK) AS EPS
    INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR
            ON EPS.stockNo = EPSR.stockNo
),
/* ---- 로트(stockNo) 단위 ---- */
lot AS (
    SELECT
         stockNo, partNo, maker
        ,SUM(입고수량)                                       AS 로트입고수량
        ,SUM(출고수량)                                       AS 로트출고수량
        ,SUM(입고수량) - SUM(출고수량)                        AS 잔여수량
        /* 로트원가 = 그 로트 입고분의 수량가중 평균단가 (0원 건 제외) */
        ,SUM(CASE WHEN srType='S' AND 단가 IS NOT NULL
                  THEN CAST(단가 AS DECIMAL(18,2)) * 입고수량 END)
         / NULLIF(SUM(CASE WHEN srType='S' AND 단가 IS NOT NULL
                           THEN 입고수량 END), 0)              AS 로트원가
        ,MAX(CASE WHEN srType='R' THEN 단가 END)             AS 로트최대판매가
        ,SUM(CASE WHEN srType='R' THEN 1 ELSE 0 END)         AS 로트출고건수
        ,MAX(CASE WHEN srType='S' THEN 무상표기 ELSE 0 END)   AS 입고무상표기
        ,MIN(CASE WHEN srType='S' THEN dt END)               AS 입고일
        ,MAX(수량이상)                                        AS 수량이상
    FROM tx
    GROUP BY stockNo, partNo, maker
),
/* ---- 매입(입고) = 원가 ---- */
buy AS (
    SELECT
         partNo, maker
        ,COUNT(*)                                                   AS 입고건수
        ,SUM(CASE WHEN 단가 IS NOT NULL THEN 1 ELSE 0 END)           AS 원가기재건수
        ,SUM(CASE WHEN 단가 IS NULL AND 무상표기 = 1 THEN 1 ELSE 0 END) AS 무상입고건수
        ,AVG(CAST(단가 AS DECIMAL(18,2)))                            AS 평균원가
        ,MIN(단가)                                                   AS 최소원가
        ,MAX(단가)                                                   AS 최대원가
        ,SUM(CASE WHEN 단가 IS NOT NULL
                  THEN CAST(단가 AS DECIMAL(18,2)) * 입고수량 END)
         / NULLIF(SUM(CASE WHEN 단가 IS NOT NULL THEN 입고수량 END),0) AS 가중평균원가
        ,SUM(CAST(입고수량 AS BIGINT))                               AS 총입고수량
    FROM tx WHERE srType = 'S'
    GROUP BY partNo, maker
),
/* ---- 발주(출고) = 판매 실적 ---- */
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
        ,SUM(CASE WHEN dt >= DATEADD(MONTH,-12,GETDATE())
                  THEN CAST(출고수량 AS BIGINT) ELSE 0 END)          AS 최근12개월_출고수량
    FROM tx WHERE srType = 'R'
    GROUP BY partNo, maker
)
SELECT
     l.partNo                                                       AS [부품 품번]
    ,ISNULL(EPM.partKorName, '')                                    AS [부품명]
    ,l.maker                                                        AS [메이커]

    /* ---------- 재고 (최소 0) ---------- */
    ,CASE WHEN SUM(CAST(l.잔여수량 AS BIGINT)) < 0 THEN 0
          ELSE SUM(CAST(l.잔여수량 AS BIGINT)) END                   AS [현재고수량]
    ,CASE WHEN SUM(CAST(l.잔여수량 AS BIGINT)) > 0 THEN 'Y' ELSE 'N' END AS [재고보유]
    ,SUM(CAST(l.로트입고수량 AS BIGINT))                             AS [총입고수량]
    ,SUM(CAST(l.로트출고수량 AS BIGINT))                             AS [총출고수량]
    ,COUNT(*)                                                       AS [로트수]
    ,SUM(CASE WHEN l.잔여수량 > 0 THEN 1 ELSE 0 END)                 AS [잔여로트수]
    ,MAX(l.수량이상)                                                 AS [수량이상_검토]

    /* ---------- ★ 선입선출 — 지금 보유한 재고의 원가 ---------- */
    ,SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
              THEN l.로트원가 * l.잔여수량 END)                       AS [보유재고_평가액]
    ,SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
              THEN l.잔여수량 END)                                    AS [보유재고_원가확인수량]
    ,CAST(SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
                   THEN l.로트원가 * l.잔여수량 END)
      / NULLIF(SUM(CASE WHEN l.잔여수량 > 0 AND l.로트원가 IS NOT NULL
                        THEN l.잔여수량 END), 0) AS DECIMAL(18,2))    AS [보유재고_단위원가]
    ,CONVERT(VARCHAR(10), MAX(CASE WHEN l.잔여수량 > 0 THEN l.입고일 END), 23)
                                                                    AS [보유재고_최종입고일]

    /* ---------- 0원의 성격 (로트 단위) ---------- */
    ,SUM(CASE WHEN l.로트원가 IS NOT NULL THEN 1 ELSE 0 END)         AS [원가확정_로트]
    ,SUM(CASE WHEN l.로트원가 IS NULL AND l.입고무상표기 = 1
              THEN 1 ELSE 0 END)                                    AS [무상확정_로트]   /* 사유에 무료/무상 명시 */
    ,SUM(CASE WHEN l.로트원가 IS NULL AND l.입고무상표기 = 0
                   AND l.로트최대판매가 IS NOT NULL THEN 1 ELSE 0 END) AS [원가미기재_로트] /* 팔았으니 무상 아님 */
    ,SUM(CASE WHEN l.로트원가 IS NULL AND l.입고무상표기 = 0
                   AND l.로트최대판매가 IS NULL THEN 1 ELSE 0 END)     AS [원가미상_로트]

    /* ---------- 매입 원가 ---------- */
    ,MAX(b.입고건수)                                                AS [입고건수]
    ,MAX(b.원가기재건수)                                            AS [원가기재건수]
    ,MAX(b.무상입고건수)                                            AS [무상입고건수]
    ,CAST(MAX(b.평균원가)     AS DECIMAL(18,2))                     AS [평균원가]
    ,CAST(MAX(b.가중평균원가) AS DECIMAL(18,2))                     AS [가중평균원가]
    ,MAX(b.최소원가)                                                AS [최소원가]
    ,MAX(b.최대원가)                                                AS [최대원가]
    ,LB.최근원가                                                    AS [최근매입원가]
    ,CONVERT(VARCHAR(10), LB.최근일, 23)                            AS [최근매입일]

    /* ---------- 판매 실적 ---------- */
    ,MAX(s.출고건수)                                                AS [출고건수]
    ,MAX(s.판매가기재건수)                                          AS [판매가기재건수]
    ,CAST(MAX(s.평균판매가)     AS DECIMAL(18,2))                   AS [평균판매가]
    ,CAST(MAX(s.가중평균판매가) AS DECIMAL(18,2))                   AS [가중평균판매가]
    ,MAX(s.최소판매가)                                              AS [최소판매가]
    ,MAX(s.최대판매가)                                              AS [최대판매가]
    ,MAX(s.최근12개월_출고수량)                                      AS [최근12개월_출고수량]
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
