/* 13_sp_redemptions.sql
   Redemption JSON: raw documents -> one row per transaction in MAIN.REDEMPTION_TXN,
   plus two views that join it back to the members.

   Same child proc shape: CALL MAIN.SP_LOAD_REDEMPTIONS(load_id), returns INS / UPD / DEL.

   Rules
   - A bad document (no member_id, bad feed_date, redemptions not a list) goes to
     quarantine whole. Nothing from it is loaded.
   - A transaction with no txn_id goes to quarantine. The rest of its document still loads.
   - Negative or zero miles, or a status we don't know, is flagged but kept.
   - txn_id is the key. The same txn_id can come again later with a new status:
     the newer feed_date wins (MERGE). */

USE DATABASE SKYPOINTS_DB;

CREATE OR REPLACE PROCEDURE MAIN.SP_LOAD_REDEMPTIONS(P_LOAD_ID NUMBER)
RETURNS TABLE (INS_COUNT NUMBER, UPD_COUNT NUMBER, DEL_COUNT NUMBER)
LANGUAGE SQL
AS
$$
DECLARE
    v_valid_status VARCHAR;
    v_ins          NUMBER DEFAULT 0;
    v_upd          NUMBER DEFAULT 0;
    rs             RESULTSET;
BEGIN
    SELECT KEY_VALUE INTO :v_valid_status
    FROM CTRL.KEY_VALUE_CONFIG
    WHERE COLUMN_NAME = 'VALID_STATUS' AND IS_ACTIVE;

    -- work tables first: a CREATE would commit an open transaction

    -- 1. one row per document, with document level checks
    CREATE OR REPLACE TEMPORARY TABLE MAIN.TMP_REDEMPTION_DOC AS
    SELECT f.LOAD_ID, f.FILE_NAME, f.FILE_ROW_NUMBER, f.PAYLOAD,
           NULLIF(TRIM(f.PAYLOAD:member_id::VARCHAR), '')                AS MEMBER_ID,   -- kept as text, same as the member file
           TRY_TO_DATE(f.PAYLOAD:feed_date::VARCHAR, 'YYYYMMDD')         AS FEED_DATE,
           ARRAY_CONSTRUCT_COMPACT(
               IFF(MEMBER_ID IS NULL,                                    'MISSING_MEMBER_ID',     NULL),
               IFF(FEED_DATE IS NULL,                                    'INVALID_FEED_DATE',     NULL),
               IFF(NOT COALESCE(IS_ARRAY(f.PAYLOAD:redemptions), FALSE), 'REDEMPTIONS_NOT_ARRAY', NULL)
           )                                                             AS DOC_ISSUES
    FROM RAW.REDEMPTION_FEED f
    WHERE f.LOAD_ID = :P_LOAD_ID;

    -- 2. flatten the good documents: one row per transaction
    CREATE OR REPLACE TEMPORARY TABLE MAIN.TMP_REDEMPTION_TXN AS
    SELECT x.*,
           ARRAY_CONSTRUCT_COMPACT(
               IFF(x.TXN_ID IS NULL,                    'MISSING_TXN_ID',     NULL),   -- reject
               IFF(x.MILES_REDEEMED <= 0,               'NON_POSITIVE_MILES', NULL),   -- warn
               IFF(NOT ARRAY_CONTAINS(x.STATUS::VARIANT, SPLIT(:v_valid_status, ',')),
                                                        'UNKNOWN_STATUS',     NULL)    -- warn
           ) AS DQ_ISSUES
    FROM (
        SELECT d.LOAD_ID, d.FILE_NAME, d.FILE_ROW_NUMBER, d.MEMBER_ID, d.FEED_DATE,
               r.index                                              AS ARRAY_INDEX,
               r.value                                              AS TXN_JSON,
               NULLIF(TRIM(r.value:txn_id::VARCHAR), '')            AS TXN_ID,
               TRY_TO_DATE(r.value:txn_date::VARCHAR, 'YYYYMMDD')   AS TXN_DATE,
               r.value:partner::VARCHAR                             AS PARTNER,
               TRY_TO_NUMBER(r.value:miles_redeemed::VARCHAR)       AS MILES_REDEEMED,
               UPPER(r.value:status::VARCHAR)                       AS STATUS
        FROM MAIN.TMP_REDEMPTION_DOC d,
             LATERAL FLATTEN(INPUT => d.PAYLOAD:redemptions) r
        WHERE ARRAY_SIZE(d.DOC_ISSUES) = 0
    ) x;

    -- 3. one row per txn_id (newest feed wins), and what it does to the table
    CREATE OR REPLACE TEMPORARY TABLE MAIN.TMP_REDEMPTION_PUBLISH AS
    SELECT s.*,
           IFF(t.TXN_ID IS NULL, 'NEW', 'UPDATE') AS CHANGE_TYPE
    FROM (SELECT * FROM MAIN.TMP_REDEMPTION_TXN
          WHERE TXN_ID IS NOT NULL
          QUALIFY ROW_NUMBER() OVER (PARTITION BY TXN_ID
                                     ORDER BY FEED_DATE DESC, FILE_NAME DESC, FILE_ROW_NUMBER DESC, ARRAY_INDEX DESC) = 1) s
    LEFT JOIN MAIN.REDEMPTION_TXN t
           ON t.TXN_ID = s.TXN_ID
    WHERE t.TXN_ID IS NULL                               -- new transaction
       OR (    s.FEED_DATE >= t.FEED_DATE                -- an older feed can't overwrite a newer status
           AND NOT (    EQUAL_NULL(s.MEMBER_ID,      t.MEMBER_ID)
                    AND EQUAL_NULL(s.TXN_DATE,       t.TXN_DATE)
                    AND EQUAL_NULL(s.PARTNER,        t.PARTNER)
                    AND EQUAL_NULL(s.MILES_REDEEMED, t.MILES_REDEEMED)
                    AND EQUAL_NULL(s.STATUS,         t.STATUS)));   -- nothing changed: skip

    SELECT COUNT_IF(CHANGE_TYPE = 'NEW'), COUNT_IF(CHANGE_TYPE = 'UPDATE')
      INTO :v_ins, :v_upd
    FROM MAIN.TMP_REDEMPTION_PUBLISH;

    BEGIN TRANSACTION;

    -- quarantine: clear this load's open rows first so a rerun doesn't duplicate
    DELETE FROM DQ.REDEMPTION_QUARANTINE WHERE LOAD_ID = :P_LOAD_ID AND STATUS = 'OPEN';

    INSERT INTO DQ.REDEMPTION_QUARANTINE (LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, TXN_ID, PAYLOAD, REASON)
    SELECT LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, NULL, PAYLOAD, DOC_ISSUES
    FROM MAIN.TMP_REDEMPTION_DOC
    WHERE ARRAY_SIZE(DOC_ISSUES) > 0
    UNION ALL
    SELECT LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, TXN_ID, TXN_JSON, DQ_ISSUES
    FROM MAIN.TMP_REDEMPTION_TXN
    WHERE TXN_ID IS NULL;

    MERGE INTO MAIN.REDEMPTION_TXN t
    USING MAIN.TMP_REDEMPTION_PUBLISH s
    ON t.TXN_ID = s.TXN_ID
    WHEN MATCHED THEN UPDATE SET
        t.MEMBER_ID = s.MEMBER_ID, t.FEED_DATE = s.FEED_DATE, t.TXN_DATE = s.TXN_DATE,
        t.PARTNER = s.PARTNER, t.MILES_REDEEMED = s.MILES_REDEEMED, t.STATUS = s.STATUS,
        t.DQ_ISSUES = s.DQ_ISSUES, t.LOAD_ID = s.LOAD_ID, t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (TXN_ID, MEMBER_ID, FEED_DATE, TXN_DATE, PARTNER, MILES_REDEEMED, STATUS, DQ_ISSUES,
         LOAD_ID, INSERT_DATE, LAST_UPDATE_DATE)
    VALUES
        (s.TXN_ID, s.MEMBER_ID, s.FEED_DATE, s.TXN_DATE, s.PARTNER, s.MILES_REDEEMED, s.STATUS, s.DQ_ISSUES,
         s.LOAD_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

    COMMIT;

    rs := (SELECT :v_ins AS INS_COUNT, :v_upd AS UPD_COUNT, 0 AS DEL_COUNT);
    RETURN TABLE(rs);

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;

/* ---------------- Join back to members ---------------- */

-- One row per transaction with the member's details.
-- LEFT JOIN, not INNER: a redemption can arrive before the member's profile.
-- We keep it and flag it as an orphan instead of losing it.
-- MEMBER_CURRENT has one row per member, so the join never duplicates transactions.
CREATE OR REPLACE VIEW MAIN.V_REDEMPTION_ENRICHED AS
SELECT r.TXN_ID, r.MEMBER_ID, r.FEED_DATE, r.TXN_DATE, r.PARTNER, r.MILES_REDEEMED, r.STATUS, r.DQ_ISSUES,
       m.MEMBER_NAME, m.COUNTRY_CODE, m.TIER_CODE,
       (m.MEMBER_ID IS NULL) AS IS_ORPHAN
FROM MAIN.REDEMPTION_TXN r
LEFT JOIN MAIN.MEMBER_CURRENT m
       ON m.MEMBER_ID = r.MEMBER_ID;

-- One row per member: completed miles, pending count, last redemption.
CREATE OR REPLACE VIEW MAIN.V_MEMBER_REDEMPTION_SUMMARY AS
SELECT m.MEMBER_ID, m.MEMBER_NAME, m.COUNTRY_CODE,
       COALESCE(SUM(IFF(r.STATUS = 'COMPLETED' AND r.MILES_REDEEMED > 0, r.MILES_REDEEMED, 0)), 0) AS COMPLETED_MILES,
       COUNT_IF(r.STATUS = 'PENDING')                                                           AS PENDING_TXNS,
       MAX(r.TXN_DATE)                                                                          AS LAST_REDEMPTION_DATE
FROM MAIN.MEMBER_CURRENT m
LEFT JOIN MAIN.REDEMPTION_TXN r
       ON r.MEMBER_ID = m.MEMBER_ID
GROUP BY m.MEMBER_ID, m.MEMBER_NAME, m.COUNTRY_CODE;
