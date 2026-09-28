/* 11_sp_load_staging.sql
   Raw -> staging for the member file, in one INSERT ... SELECT:
     1. clean the text (trim, '' or the text NULL = missing)
     2. convert types (dates per column, country through the mapping table)
     3. derive Age and Stale_Member as of the file date (not today, so reruns match)
     4. flag row level issues, PASS / WARN / REJECT
   Rejected rows are also copied to DQ.MEMBER_QUARANTINE.
   Staging holds one load at a time, so it's truncated first. */

USE DATABASE SKYPOINTS_DB;

-- Small helper so the cleaning rule is written once.
CREATE OR REPLACE FUNCTION STG.FN_CLEAN(V VARCHAR)
RETURNS VARCHAR
AS
$$
    IFF(UPPER(TRIM(V, ' \t\r')) IN ('', 'NULL'), NULL, TRIM(V, ' \t\r'))
$$;

CREATE OR REPLACE PROCEDURE STG.SP_LOAD_MEMBER(P_LOAD_ID NUMBER)
RETURNS TABLE (INS_COUNT NUMBER, UPD_COUNT NUMBER, DEL_COUNT NUMBER)
LANGUAGE SQL
AS
$$
DECLARE
    v_stale_days NUMBER;
    v_ins        NUMBER DEFAULT 0;
    rs           RESULTSET;
BEGIN
    -- threshold from config; if it's missing this fails, which is what we want
    SELECT TO_NUMBER(KEY_VALUE) INTO :v_stale_days
    FROM CTRL.KEY_VALUE_CONFIG
    WHERE COLUMN_NAME = 'STALE_DAYS' AND IS_ACTIVE;

    TRUNCATE TABLE STG.MEMBER;

    INSERT INTO STG.MEMBER
        (LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, FILE_TS,
         MEMBER_NAME, MEMBER_ID, ENROLLMENT_DATE, LAST_FLIGHT_DATE, TIER_CODE,
         AGENT_NAME, STATE, COUNTRY_RAW, COUNTRY_CODE, POST_CODE, DOB, IS_ACTIVE,
         AGE, STALE_MEMBER, DQ_STATUS, DQ_ISSUES)
    WITH cleaned AS (
        SELECT
            r.LOAD_ID,
            r.FILE_NAME,
            r.FILE_ROW_NUMBER,
            -- members_20240116_010000.txt -> 2024-01-16 01:00:00
            TRY_TO_TIMESTAMP(REGEXP_SUBSTR(r.FILE_NAME, 'members_([0-9]{8}_[0-9]{6})', 1, 1, 'e', 1),
                             'YYYYMMDD_HH24MISS')    AS FILE_TS,
            STG.FN_CLEAN(r.MEMBER_NAME)              AS MEMBER_NAME,
            STG.FN_CLEAN(r.MEMBER_ID)                AS MEMBER_ID,
            STG.FN_CLEAN(r.ENROLLMENT_DATE)          AS ENROLLMENT_TXT,
            STG.FN_CLEAN(r.LAST_FLIGHT_DATE)         AS FLIGHT_TXT,
            UPPER(STG.FN_CLEAN(r.TIER_CODE))         AS TIER_CODE,
            STG.FN_CLEAN(r.AGENT_NAME)               AS AGENT_NAME,
            STG.FN_CLEAN(r.STATE)                    AS STATE,
            UPPER(STG.FN_CLEAN(r.COUNTRY))           AS COUNTRY_RAW,
            STG.FN_CLEAN(r.DOB)                      AS DOB_TXT,
            UPPER(STG.FN_CLEAN(r.IS_ACTIVE))         AS IS_ACTIVE
        FROM RAW.MEMBER_FILE r
        WHERE r.LOAD_ID = :P_LOAD_ID
    ),
    typed AS (
        SELECT
            c.*,
            -- YYYYMMDD, only when it is exactly 8 digits
            IFF(REGEXP_LIKE(c.ENROLLMENT_TXT, '[0-9]{8}'), TRY_TO_DATE(c.ENROLLMENT_TXT, 'YYYYMMDD'), NULL) AS ENROLLMENT_DATE,
            IFF(REGEXP_LIKE(c.FLIGHT_TXT, '[0-9]{8}'),     TRY_TO_DATE(c.FLIGHT_TXT, 'YYYYMMDD'),     NULL) AS LAST_FLIGHT_DATE,
            -- DOB is MMDDYYYY. 7 digits means the leading zero was lost, so pad it back
            IFF(REGEXP_LIKE(c.DOB_TXT, '[0-9]{7,8}'), TRY_TO_DATE(LPAD(c.DOB_TXT, 8, '0'), 'MMDDYYYY'), NULL)  AS DOB,
            cc.COUNTRY_CODE,                          -- NULL when the value isn't mapped or the country is inactive
            t.TIER_CODE                               AS KNOWN_TIER,
            c.FILE_TS::DATE                           AS AS_OF_DATE
        FROM cleaned c
        LEFT JOIN CTRL.COUNTRY_CODE_MAP m ON m.SOURCE_VALUE = c.COUNTRY_RAW
        LEFT JOIN CTRL.COUNTRY_CONFIG  cc ON cc.COUNTRY_CODE = m.COUNTRY_CODE AND cc.IS_ACTIVE
        LEFT JOIN CTRL.TIER_REF        t  ON t.TIER_CODE = c.TIER_CODE
    ),
    derived AS (
        SELECT
            t.*,
            -- completed years; the IFF takes one off if the birthday hasn't come yet this year
            DATEDIFF('year', t.DOB, t.AS_OF_DATE)
              - IFF(DATEADD('year', DATEDIFF('year', t.DOB, t.AS_OF_DATE), t.DOB) > t.AS_OF_DATE, 1, 0) AS AGE,
            -- no flight yet: measure from enrollment
            DATEDIFF('day', COALESCE(t.LAST_FLIGHT_DATE, t.ENROLLMENT_DATE), t.AS_OF_DATE) > :v_stale_days AS STALE_MEMBER,
            ARRAY_CONSTRUCT_COMPACT(
                -- reject: mandatory field missing or unusable
                IFF(t.MEMBER_ID IS NULL,                                 'MISSING_MEMBER_ID',         NULL),
                IFF(t.MEMBER_NAME IS NULL,                               'MISSING_MEMBER_NAME',       NULL),
                IFF(t.ENROLLMENT_DATE IS NULL,                           'INVALID_ENROLLMENT_DATE',   NULL),  -- missing or not a real date
                IFF(t.COUNTRY_CODE IS NULL,                              'UNMAPPED_COUNTRY',          NULL),  -- missing or not in the mapping
                -- warn: row is kept, the issue is flagged
                IFF(LENGTH(t.DOB_TXT) = 7 AND t.DOB IS NOT NULL,         'DOB_LEADING_ZERO_RESTORED', NULL),
                IFF(t.DOB_TXT IS NOT NULL AND t.DOB IS NULL,             'INVALID_DOB',               NULL),
                IFF(t.TIER_CODE IS NOT NULL AND t.KNOWN_TIER IS NULL,    'UNKNOWN_TIER',              NULL)
            ) AS DQ_ISSUES
        FROM typed t
    )
    SELECT
        LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, FILE_TS,
        MEMBER_NAME, MEMBER_ID, ENROLLMENT_DATE, LAST_FLIGHT_DATE, TIER_CODE,
        AGENT_NAME, STATE, COUNTRY_RAW, COUNTRY_CODE,
        NULL AS POST_CODE,                            -- in the spec, not in the file
        DOB, IS_ACTIVE, AGE, STALE_MEMBER,
        CASE
            WHEN ARRAYS_OVERLAP(DQ_ISSUES, ARRAY_CONSTRUCT(
                    'MISSING_MEMBER_ID', 'MISSING_MEMBER_NAME', 'INVALID_ENROLLMENT_DATE', 'UNMAPPED_COUNTRY')) THEN 'REJECT'
            WHEN ARRAY_SIZE(DQ_ISSUES) > 0 THEN 'WARN'
            ELSE 'PASS'
        END AS DQ_STATUS,
        DQ_ISSUES
    FROM derived;

    v_ins := SQLROWCOUNT;

    -- rejected rows go to quarantine; clear this load's open rows first so a rerun doesn't duplicate
    DELETE FROM DQ.MEMBER_QUARANTINE WHERE LOAD_ID = :P_LOAD_ID AND STATUS = 'OPEN';

    INSERT INTO DQ.MEMBER_QUARANTINE (LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, REASON)
    SELECT LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, DQ_ISSUES
    FROM STG.MEMBER
    WHERE DQ_STATUS = 'REJECT';

    rs := (SELECT :v_ins AS INS_COUNT, 0 AS UPD_COUNT, 0 AS DEL_COUNT);
    RETURN TABLE(rs);
END;
$$;
