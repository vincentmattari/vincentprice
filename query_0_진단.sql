/* ============================================================================
   [1단계] 진단 쿼리 — 본 추출 전 확인용
   ============================================================================
   확인됨
     srPrice = 1개당 단가 (INT)
     R = 발주/출고 (수량 releaseEa),  S = 입고 (수량 storeEa)
     재고 = SUM(storeEa) - SUM(releaseEa)
     epmsPartStockStoreRelease = 발주(출고)/입고 내역
     epmsPartStock             = 재고부품 기본정보
   ============================================================================ */

/* --- ★ (1) 재고가 음수인 로트가 있는가 -----------------------------------
   잔여수량 = 입고 - 출고 가 음수면 재고 계산 전제가 깨진다.
   초기 재고 이관, 반품, 로트 분할 등이 원인일 수 있다.                    */
SELECT
     CASE WHEN 잔여 < 0 THEN '음수 (문제)'
          WHEN 잔여 = 0 THEN '0 (소진)'
          ELSE '양수 (재고보유)' END AS 구분
    ,COUNT(*)      AS 로트수
    ,SUM(잔여)     AS 수량합
FROM (
    SELECT stockNo
          ,ISNULL(SUM(storeEa),0) - ISNULL(SUM(releaseEa),0) AS 잔여
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY CASE WHEN 잔여 < 0 THEN '음수 (문제)'
              WHEN 잔여 = 0 THEN '0 (소진)'
              ELSE '양수 (재고보유)' END;


/* --- ★ (2) stockNo 당 입고 행이 1건인가 ----------------------------------
   본 쿼리는 로트원가 = MAX(입고단가) 로 잡는다.
   stockNo 당 입고가 여러 건이면 로트 개념이 달라지므로 확인이 필요하다.   */
SELECT
     CAST(입고건수 AS VARCHAR(10)) + '건 입고' AS 구분
    ,COUNT(*) AS stockNo수
FROM (
    SELECT stockNo, SUM(CASE WHEN srType='S' THEN 1 ELSE 0 END) AS 입고건수
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY 입고건수
ORDER BY COUNT(*) DESC;


/* --- ★ (3) 시간 순서 — 입고가 출고보다 먼저인가 --------------------------
   로트 개념이 맞다면 입고일 <= 첫 출고일 이어야 한다.                     */
SELECT
     CASE WHEN 입고일 IS NULL THEN '입고없음 (문제)'
          WHEN 출고일 IS NULL THEN '출고없음 (미사용 재고)'
          WHEN 입고일 <= 출고일 THEN '입고 -> 출고 (정상)'
          ELSE '출고 -> 입고 (역순)' END AS 순서
    ,COUNT(*) AS 로트수
FROM (
    SELECT stockNo
          ,MIN(CASE WHEN srType='S' THEN TRY_CONVERT(DATE, CONVERT(VARCHAR(8), regYmd,112)) END) AS 입고일
          ,MIN(CASE WHEN srType='R' THEN TRY_CONVERT(DATE, CONVERT(VARCHAR(8), regYmd,112)) END) AS 출고일
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY CASE WHEN 입고일 IS NULL THEN '입고없음 (문제)'
              WHEN 출고일 IS NULL THEN '출고없음 (미사용 재고)'
              WHEN 입고일 <= 출고일 THEN '입고 -> 출고 (정상)'
              ELSE '출고 -> 입고 (역순)' END;


/* --- ★ (4) 0원(미기재)이 입고/출고 중 어디서 발생하는가 ------------------
   입고쪽 0원 = 원가 미기재 (원가 산출에 지장)
   출고쪽 0원 = 판매가 미기재 (무상 교체·보증 건일 수도 있다)              */
SELECT
     srType
    ,CASE srType WHEN 'S' THEN '입고(원가)' WHEN 'R' THEN '발주/출고(판매가)' ELSE '기타' END AS 구분
    ,COUNT(*)                                                    AS 건수
    ,SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)     AS 가격0건수
    ,CAST(100.0 * SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*),0) AS DECIMAL(5,1))                  AS 가격0비율
    ,AVG(CAST(NULLIF(srPrice,0) AS DECIMAL(18,2)))               AS 유효평균단가
    ,SUM(CAST(ISNULL(storeEa,0)   AS BIGINT))                    AS 입고수량합
    ,SUM(CAST(ISNULL(releaseEa,0) AS BIGINT))                    AS 출고수량합
FROM epmsPartStockStoreRelease (NOLOCK)
GROUP BY srType;


/* --- (5) 실현 마진 감 잡기 — 출고단가가 입고단가보다 얼마나 높은가 ------
   이 값이 그동안 실제로 적용해온 마진이다.                               */
SELECT TOP 20
     EPS.partNo
    ,AVG(CAST(CASE WHEN srType='S' THEN NULLIF(srPrice,0) END AS DECIMAL(18,2))) AS 평균원가
    ,AVG(CAST(CASE WHEN srType='R' THEN NULLIF(srPrice,0) END AS DECIMAL(18,2))) AS 평균판매가
    ,CAST(AVG(CAST(CASE WHEN srType='R' THEN NULLIF(srPrice,0) END AS DECIMAL(18,2)))
        / NULLIF(AVG(CAST(CASE WHEN srType='S' THEN NULLIF(srPrice,0) END AS DECIMAL(18,2))),0)
        AS DECIMAL(10,3)) AS 마진배수
    ,COUNT(*) AS 건수
FROM epmsPartStock (NOLOCK) AS EPS
INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR ON EPS.stockNo = EPSR.stockNo
GROUP BY EPS.partNo
HAVING AVG(CAST(CASE WHEN srType='S' THEN NULLIF(srPrice,0) END AS DECIMAL(18,2))) > 0
   AND AVG(CAST(CASE WHEN srType='R' THEN NULLIF(srPrice,0) END AS DECIMAL(18,2))) > 0
ORDER BY COUNT(*) DESC;


/* --- (6) epmsPartStock 의 컬럼 — 재고/상태 컬럼이 이미 있는지 ----------- */
SELECT c.name AS 컬럼명, t.name AS 자료형, c.max_length, c.is_nullable
FROM sys.columns c
JOIN sys.types  t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('epmsPartStock')
ORDER BY c.column_id;
