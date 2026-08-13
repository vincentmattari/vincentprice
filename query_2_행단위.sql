/* ============================================================================
   [3단계] 행 단위 추출 — 선입선출(FIFO) 계산용
   ============================================================================
   환경 : SQL Server 2019 엔진 / DB 호환성 수준 100 (2008)
          2012+ 함수는 쓰지 않는다. 이 쿼리는 단순 SELECT 라 제약과 무관하다.

   왜 행 단위인가
   --------------
   stockNo 는 매입 로트가 아니라 '부품별 재고 등록 단위'다 (stockNo 약 2,183개 vs
   부품 2,180개로 사실상 1:1). 따라서 집계만으로는 어느 시점에 들어온 재고가
   남아 있는지 알 수 없고, 선입선출 원가를 구할 수 없다.

   입출고를 실입출고일(srRealYmd) 순으로 재생하면 진짜 FIFO 가 계산된다.
     입고 2024-05-09  2개 @30,000
     입고 2025-02-11  3개 @45,000
     출고 2025-08-08  2개          -> 먼저 들어온 30,000 짜리 2개가 소진
                                   -> 남은 3개는 전부 45,000 짜리
   이 재생은 GROUP BY 로는 불가능하므로 행을 그대로 뽑아 Python 에서 처리한다.
   전체 6,745행(입고 2,850 + 출고 3,895) 이라 부담이 없다.

   정렬이 중요하다 — 날짜순, 같은 날짜면 srNo 순으로 소진시킨다.
   ============================================================================ */

SELECT
     EPS.partNo                                          AS [품번]
    ,ISNULL(EPM.partKorName, '')                         AS [부품명]
    ,EPS.maker                                           AS [메이커]
    ,EPSR.stockNo                                        AS [재고번호]
    ,EPSR.srNo                                           AS [이동번호]
    ,LTRIM(RTRIM(EPSR.srType))                           AS [구분]          /* S=입고, R=발주/출고 */
    ,ISNULL(EPSR.storeEa, 0)                             AS [입고수량]
    ,ISNULL(EPSR.releaseEa, 0)                           AS [출고수량]
    ,ISNULL(EPSR.srPrice, 0)                             AS [단가]          /* 0 = 미기재 또는 무상 */
    ,CONVERT(VARCHAR(10), EPSR.srRealYmd, 23)            AS [실입출고일]
    ,CONVERT(VARCHAR(10), EPSR.regYmd, 23)               AS [등록일]
    ,ISNULL(EPSR.srDesc, '')                             AS [발생사유]      /* '한성에서 무료' 등 */
    ,ISNULL(EPSR.locationNo, '')                         AS [재고위치]
FROM epmsPartStock (NOLOCK) AS EPS
INNER JOIN epmsPartStockStoreRelease (NOLOCK) AS EPSR
        ON EPS.stockNo = EPSR.stockNo
OUTER APPLY (
    SELECT TOP 1 partKorName
    FROM epmsPartMst (NOLOCK) AS EPM
    WHERE EPM.partNo = EPS.partNo
    ORDER BY EPM.partId DESC
) AS EPM
ORDER BY
     EPS.partNo
    ,EPS.maker
    ,EPSR.srRealYmd      /* FIFO 소진 순서 */
    ,EPSR.srNo;
