/* ============================================================================
   [1단계] 진단 쿼리 — 본 추출 전 확인용
   ============================================================================
   해결됨: srPrice 는 1개당 단가 (합계금액 아님) — 확인 완료
   남은 것: srType R/S 가 각각 무엇인가
   ============================================================================ */

/* --- ★ (1) 가장 중요 — srType 별 수량 컬럼이 어떻게 채워지는가 -------------
   releaseEa(출고수량) 가 R 행에만 채워지고 storeEa(입고수량) 가 S 행에만
   채워진다면, R 은 출고(Release) 이지 발주가 아니다.
   R 이 출고라면 R 쪽 단가는 원가가 아니라 '실제 판매가' 이므로
   판매가를 추정할 게 아니라 이미 보유한 셈이 되어 접근이 달라진다.        */
SELECT
     srType
    ,COUNT(*)                                                        AS 건수
    ,SUM(CASE WHEN ISNULL(storeEa,0)   > 0 THEN 1 ELSE 0 END)        AS 입고수량_있는행
    ,SUM(CASE WHEN ISNULL(releaseEa,0) > 0 THEN 1 ELSE 0 END)        AS 출고수량_있는행
    ,SUM(CAST(ISNULL(storeEa,0)   AS BIGINT))                        AS 입고수량합
    ,SUM(CAST(ISNULL(releaseEa,0) AS BIGINT))                        AS 출고수량합
    ,SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)         AS 가격0건수
    ,CAST(100.0 * SUM(CASE WHEN ISNULL(srPrice,0) <= 0 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*),0) AS DECIMAL(5,1))                      AS 가격0비율
    ,AVG(CAST(NULLIF(srPrice,0) AS DECIMAL(18,2)))                   AS 유효평균단가
FROM epmsPartStockStoreRelease (NOLOCK)
GROUP BY srType;
/* 판정
   - R 행에 출고수량만, S 행에 입고수량만 채워짐  -> R=출고(Release), S=입고(Store)
   - R·S 모두 입고수량이 채워짐                  -> R=발주, S=입고 (라벨대로)
   또한 '가격0비율' 이 어느 쪽에 몰려 있는지가 미기재의 발생 지점을 알려준다. */


/* --- (2) srType 에 R,S 외 다른 값이 있는가 ------------------------------- */
SELECT DISTINCT srType FROM epmsPartStockStoreRelease (NOLOCK);


/* --- (3) 같은 부품의 실제 거래를 시간순으로 눈으로 확인 ------------------
   R 과 S 가 짝을 이루는지(발주->입고), 아니면 S 후 R 이 여러 번 나오는지
   (입고->출고 반복) 를 보면 성격이 드러난다.
   003990949764 는 R 647건 : S 12건 으로 비율이 가장 극단적인 부품이다.    */
SELECT TOP 40
     EPS.partNo, EPSR.srType, EPSR.srPrice, EPSR.storeEa, EPSR.releaseEa, EPSR.regYmd
FROM epmsPartStock (NOLOCK) AS EPS
INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR ON EPS.stockNo = EPSR.stockNo
WHERE EPS.partNo = '003990949764'
ORDER BY EPSR.regYmd;


/* --- (4) regYmd 자료형과 데이터 기간 ------------------------------------ */
SELECT
     MIN(regYmd) AS 최초등록일
    ,MAX(regYmd) AS 최종등록일
    ,COUNT(*)    AS 전체행수
FROM epmsPartStockStoreRelease (NOLOCK);


/* --- (5) 재고 컬럼이 epmsPartStock 에 이미 있는지 -----------------------
   있다면 수량 합산으로 계산하지 말고 그 값을 쓰는 편이 정확하다.          */
SELECT TOP 1 * FROM epmsPartStock (NOLOCK);
