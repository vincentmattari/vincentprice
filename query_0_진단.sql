/* ============================================================================
   [1단계] 진단 쿼리 — 본 추출 전 확인용
   ============================================================================
   확인됨 : srPrice 는 1개당 단가
            R = 발주(수량 releaseEa),  S = 입고(수량 storeEa)
   남은 것 : 아래 (1)~(4)
   ============================================================================ */

/* --- ★ (1) stockNo 가 '한 건의 매입'을 가리키는가 -------------------------
   본 추출 쿼리는 stockNo 단위로 발주·입고를 하나로 묶어 원가를 확정한다.
   그 전제가 맞는지 확인한다.
   기대: stockNo 당 R 최대 1건, S 최대 1건 (또는 그에 가까움)              */
SELECT
     행수구성
    ,COUNT(*) AS stockNo수
FROM (
    SELECT stockNo
          ,CAST(SUM(CASE WHEN srType='R' THEN 1 ELSE 0 END) AS VARCHAR(10))
           + 'R + '
           + CAST(SUM(CASE WHEN srType='S' THEN 1 ELSE 0 END) AS VARCHAR(10))
           + 'S' AS 행수구성
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY 행수구성
ORDER BY COUNT(*) DESC;
/* '1R + 1S' 가 대부분이면 stockNo = 매입 1건이 맞다.
   '0R + 1S' 는 발주 없이 입고된 건, '1R + 0S' 는 발주 후 미입고 건이다.   */


/* --- ★ (2) 발주가 입고보다 먼저 일어나는가 (시간 순서 검증) --------------
   R=발주, S=입고 라면 같은 stockNo 안에서 발주일 <= 입고일 이어야 한다.
   반대로 입고가 먼저고 R 이 나중이라면 R 은 발주가 아니라 출고다.        */
SELECT
     CASE WHEN 발주일 IS NULL THEN '발주없음'
          WHEN 입고일 IS NULL THEN '입고없음(미입고)'
          WHEN 발주일 <= 입고일 THEN '발주 -> 입고 (정상)'
          ELSE '입고 -> 발주 (역순)' END AS 순서
    ,COUNT(*) AS 건수
FROM (
    SELECT stockNo
          ,MIN(CASE WHEN srType='R' THEN TRY_CONVERT(DATE, CONVERT(VARCHAR(8), regYmd, 112)) END) AS 발주일
          ,MIN(CASE WHEN srType='S' THEN TRY_CONVERT(DATE, CONVERT(VARCHAR(8), regYmd, 112)) END) AS 입고일
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY CASE WHEN 발주일 IS NULL THEN '발주없음'
              WHEN 입고일 IS NULL THEN '입고없음(미입고)'
              WHEN 발주일 <= 입고일 THEN '발주 -> 입고 (정상)'
              ELSE '입고 -> 발주 (역순)' END;


/* --- ★ (3) 재고를 어디서 얻는가 -----------------------------------------
   이 테이블에는 출고 기록이 없어 현재고를 계산할 수 없다.
   epmsPartStock 에 재고/상태 컬럼이 있는지 확인한다.                      */
SELECT TOP 3 * FROM epmsPartStock (NOLOCK);

/* 컬럼 목록으로 재고 관련 컬럼을 찾는다 */
SELECT c.name AS 컬럼명, t.name AS 자료형, c.max_length, c.is_nullable
FROM sys.columns c
JOIN sys.types  t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('epmsPartStock')
ORDER BY c.column_id;

/* 출고 테이블이 따로 있는지 이름으로 탐색 */
SELECT name FROM sys.tables
WHERE name LIKE '%Release%' OR name LIKE '%Out%' OR name LIKE '%Sale%'
   OR name LIKE '%Issue%'   OR name LIKE '%Stock%'
ORDER BY name;


/* --- (4) 0원(미기재)이 발주/입고 중 어디서 발생하는가 -------------------
   입고 때 단가를 안 적는 것이 원인이라면 S 쪽에 몰려 있어야 한다.        */
SELECT
     srType
    ,COUNT(*)                                                    AS 건수
    ,SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)     AS 가격0건수
    ,CAST(100.0 * SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*),0) AS DECIMAL(5,1))                  AS 가격0비율
    ,AVG(CAST(NULLIF(srPrice,0) AS DECIMAL(18,2)))               AS 유효평균단가
    ,SUM(CAST(ISNULL(storeEa,0)   AS BIGINT))                    AS 입고수량합
    ,SUM(CAST(ISNULL(releaseEa,0) AS BIGINT))                    AS 발주수량합
FROM epmsPartStockStoreRelease (NOLOCK)
GROUP BY srType;
