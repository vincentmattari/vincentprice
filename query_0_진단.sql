/* ============================================================================
   [1단계] 진단 쿼리  —  SQL Server 2005/2008 호환
   ============================================================================
   TRY_CONVERT / PERCENTILE_CONT / IIF / CONCAT / LAG 등 2012+ 함수는 쓰지 않는다.
   ============================================================================ */

/* --- ★ (0) 버전 확인 — 어디까지 쓸 수 있는지 판단 ----------------------- */
SELECT @@VERSION AS 버전
      ,SERVERPROPERTY('ProductVersion')   AS 제품버전
      ,SERVERPROPERTY('ProductLevel')     AS 서비스팩
      ,(SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) AS 호환성수준;


/* --- ★ (1) 컬럼 목록 — 발생사유·실입출고일·공급처의 실제 컬럼명 확인 ----
   화면에 있는 항목들의 컬럼명을 알아야 쿼리에 넣을 수 있다.
     발생사유   : 0원이 '무상'인지 '미기재'인지 구분하는 핵심
     실입출고일 : 선입선출은 등록일이 아니라 이 날짜 기준이어야 정확
     공급처     : 매입처별 단가 비교에 유용                                */
SELECT c.column_id AS 순번, c.name AS 컬럼명, t.name AS 자료형
      ,c.max_length AS 길이, c.is_nullable AS NULL허용
FROM sys.columns c
JOIN sys.types  t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('epmsPartStockStoreRelease')
ORDER BY c.column_id;

SELECT c.column_id AS 순번, c.name AS 컬럼명, t.name AS 자료형
      ,c.max_length AS 길이, c.is_nullable AS NULL허용
FROM sys.columns c
JOIN sys.types  t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('epmsPartStock')
ORDER BY c.column_id;


/* --- ★ (2) 화면에서 본 두 부품의 원본 행 ---------------------------------
   218823100C : 입고 55,000 -> 출고 0   (출고 단가 미기재)
   1778810600 : 입고 0(한성에서 무료) -> 출고 0  (정당한 무상)
   컬럼명 확인 후 발생사유가 어떻게 저장돼 있는지 눈으로 본다.            */
SELECT EPSR.*
FROM epmsPartStock (NOLOCK) AS EPS
INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR ON EPS.stockNo = EPSR.stockNo
WHERE EPS.partNo IN ('218823100C', '1778810600')
ORDER BY EPS.partNo, EPSR.stockNo;


/* --- ★ (3) 0원 건의 발생사유 상위 목록 ------------------------------------
   '무료', '무상', '서비스', '재고조사' 같은 말이 얼마나 자주 나오는지 본다.
   ※ 아래 [발생사유] 를 (1)에서 확인한 실제 컬럼명으로 바꿔서 실행할 것     */
/*
SELECT TOP 50
     srType
    ,[발생사유]
    ,COUNT(*) AS 건수
FROM epmsPartStockStoreRelease (NOLOCK)
WHERE ISNULL(srPrice,0) <= 0
GROUP BY srType, [발생사유]
ORDER BY COUNT(*) DESC;
*/


/* --- ★ (4) 수량 이상치 — 음수 수량이 어디에 있는가 ------------------------
   N90855001 의 출고수량 -7 처럼 잘못 입력된 건을 찾는다.                  */
SELECT
     EPS.partNo
    ,EPSR.srType
    ,EPSR.storeEa
    ,EPSR.releaseEa
    ,EPSR.srPrice
    ,EPSR.regYmd
FROM epmsPartStock (NOLOCK) AS EPS
INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR ON EPS.stockNo = EPSR.stockNo
WHERE ISNULL(EPSR.storeEa,0) < 0 OR ISNULL(EPSR.releaseEa,0) < 0
ORDER BY EPS.partNo;


/* --- ★ (5) 재고 음수 로트 — 최소값은 0 이어야 한다 ------------------------ */
SELECT
     EPS.partNo
    ,EPSR.stockNo
    ,SUM(ISNULL(EPSR.storeEa,0))                                    AS 입고수량
    ,SUM(ISNULL(EPSR.releaseEa,0))                                  AS 출고수량
    ,SUM(ISNULL(EPSR.storeEa,0)) - SUM(ISNULL(EPSR.releaseEa,0))    AS 잔여수량
FROM epmsPartStock (NOLOCK) AS EPS
INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR ON EPS.stockNo = EPSR.stockNo
GROUP BY EPS.partNo, EPSR.stockNo
HAVING SUM(ISNULL(EPSR.storeEa,0)) - SUM(ISNULL(EPSR.releaseEa,0)) < 0
ORDER BY SUM(ISNULL(EPSR.storeEa,0)) - SUM(ISNULL(EPSR.releaseEa,0));


/* --- (6) stockNo 당 입고 행 수 — 로트 개념 검증 --------------------------- */
SELECT 입고건수, COUNT(*) AS stockNo수
FROM (
    SELECT stockNo, SUM(CASE WHEN srType='S' THEN 1 ELSE 0 END) AS 입고건수
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY 입고건수
ORDER BY COUNT(*) DESC;


/* --- (7) 0원 발생 지점 — 입고(원가) vs 출고(판매가) ----------------------- */
SELECT
     srType
    ,CASE srType WHEN 'S' THEN '입고(원가)'
                 WHEN 'R' THEN '발주/출고(판매가)' ELSE '기타' END   AS 구분
    ,COUNT(*)                                                       AS 건수
    ,SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)        AS 가격0건수
    ,CAST(100.0 * SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)
          / COUNT(*) AS DECIMAL(5,1))                               AS 가격0비율
    ,AVG(CAST(NULLIF(srPrice,0) AS DECIMAL(18,2)))                  AS 유효평균단가
FROM epmsPartStockStoreRelease (NOLOCK)
GROUP BY srType;


/* --- ★ (8) 0원 성격 판별 — 로트 단위 교차 확인 ---------------------------
   입고 0 인데 출고가 유가 -> 팔았으니 무상일 리 없다 = 원가 미기재
   입고 유가인데 출고 0     -> 판매가 미기재 (스크린샷 218823100C 유형)
   입고 0 이고 출고도 0     -> 무상 추정 (스크린샷 1778810600 유형)        */
SELECT
     CASE WHEN 입고단가 > 0 AND 출고최대단가 > 0 THEN '1) 양쪽 유가 (정상)'
          WHEN 입고단가 > 0 AND ISNULL(출고최대단가,0) = 0 AND 출고건수 > 0
               THEN '2) 입고 유가 / 출고 0  -> 판매가 미기재'
          WHEN ISNULL(입고단가,0) = 0 AND 출고최대단가 > 0
               THEN '3) 입고 0 / 출고 유가  -> 원가 미기재'
          WHEN ISNULL(입고단가,0) = 0 AND ISNULL(출고최대단가,0) = 0
               THEN '4) 양쪽 0  -> 무상 추정'
          ELSE '5) 기타' END                                        AS 유형
    ,COUNT(*) AS 로트수
FROM (
    SELECT stockNo
          ,MAX(CASE WHEN srType='S' THEN srPrice END)   AS 입고단가
          ,MAX(CASE WHEN srType='R' THEN srPrice END)   AS 출고최대단가
          ,SUM(CASE WHEN srType='R' THEN 1 ELSE 0 END)  AS 출고건수
    FROM epmsPartStockStoreRelease (NOLOCK)
    GROUP BY stockNo
) x
GROUP BY
     CASE WHEN 입고단가 > 0 AND 출고최대단가 > 0 THEN '1) 양쪽 유가 (정상)'
          WHEN 입고단가 > 0 AND ISNULL(출고최대단가,0) = 0 AND 출고건수 > 0
               THEN '2) 입고 유가 / 출고 0  -> 판매가 미기재'
          WHEN ISNULL(입고단가,0) = 0 AND 출고최대단가 > 0
               THEN '3) 입고 0 / 출고 유가  -> 원가 미기재'
          WHEN ISNULL(입고단가,0) = 0 AND ISNULL(출고최대단가,0) = 0
               THEN '4) 양쪽 0  -> 무상 추정'
          ELSE '5) 기타' END
ORDER BY COUNT(*) DESC;
