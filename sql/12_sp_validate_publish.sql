/* 12_sp_validate_publish.sql
   Two child procs, same shape as the others: CALL proc(load_id), returns INS / UPD / DEL.

   MAIN.SP_VALIDATE_MEMBER  batch checks on the whole load. Any ERROR check stops the run
                            (the proc raises, the master logs it), so bad data never
                            reaches the country tables. WARN checks are only logged.
   MAIN.SP_PUBLISH_MEMBER   latest record wins, country moves, MERGE into the country
                            tables and MEMBER_CURRENT, all in one transaction. */

USE DATABASE SKYPOINTS_DB;

/* ------------------------------------------------------------------------ */
CREATE OR REPLACE PROCEDURE MAIN.SP_VALIDATE_MEMBER(P_LOAD_ID NUMBER)
RETURNS TABLE (INS_COUNT NUMBER, UPD_COUNT NUMBER, DEL_COUNT NUMBER)
LANGUAGE SQL
AS
$$
DECLARE
    v_raw       NUMBER;
    v_stg       NUMBER;
    v_loss      NUMBER;
    v_rej       NUMBER;
    v_dup       NUMBER;
    v_max_pct   NUMBER;
    v_min_rows  NUMBER;
    v_errors    NUMBER DEFAULT 0;
    rs          RESULTSET;
    data_check_failed EXCEPTION (-20002, 'Data check failed for this load. Details in CTRL.PROCESS_ERROR_LOG');
BEGIN
    SELECT TO_NUMBER(KEY_VALUE) INTO :v_max_pct  FROM CTRL.KEY_VALUE_CONFIG WHERE COLUMN_NAME = 'REJECT_RATE_MAX_PCT'  AND IS_ACTIVE;
    SELECT TO_NUMBER(KEY_VALUE) INTO :v_min_rows FROM CTRL.KEY_VALUE_CONFIG WHERE COLUMN_NAME = 'REJECT_RATE_MIN_ROWS' AND IS_ACTIVE;

    -- 1. record count: every raw row must reach staging
    SELECT COUNT(*) INTO :v_raw FROM RAW.MEMBER_FILE WHERE LOAD_ID = :P_LOAD_ID;
    SELECT COUNT(*) INTO :v_stg FROM STG.MEMBER      WHERE LOAD_ID = :P_LOAD_ID;
    IF (v_raw <> v_stg) THEN
        INSERT INTO CTRL.PROCESS_ERROR_LOG (LOAD_ID, SEVERITY, ERROR_DESCRIPTION)
        VALUES (:P_LOAD_ID, 'ERROR', 'RAW_TO_STAGING_COUNT: raw ' || :v_raw || ' rows, staging ' || :v_stg);
        v_errors := v_errors + 1;
    END IF;

    -- 2. column level: a value that was in the file must not go missing in staging.
    --    This is the check that would have caught the blank Agent_Name in the brief's staging sample.
    SELECT COUNT(*) INTO :v_loss
    FROM RAW.MEMBER_FILE r
    JOIN STG.MEMBER s
      ON  s.LOAD_ID = r.LOAD_ID
      AND s.FILE_NAME = r.FILE_NAME
      AND s.FILE_ROW_NUMBER = r.FILE_ROW_NUMBER
    WHERE r.LOAD_ID = :P_LOAD_ID
      AND (   (STG.FN_CLEAN(r.MEMBER_NAME) IS NOT NULL AND s.MEMBER_NAME IS NULL)
           OR (STG.FN_CLEAN(r.MEMBER_ID)   IS NOT NULL AND s.MEMBER_ID   IS NULL)
           OR (STG.FN_CLEAN(r.TIER_CODE)   IS NOT NULL AND s.TIER_CODE   IS NULL)
           OR (STG.FN_CLEAN(r.AGENT_NAME)  IS NOT NULL AND s.AGENT_NAME  IS NULL)
           OR (STG.FN_CLEAN(r.STATE)       IS NOT NULL AND s.STATE       IS NULL)
           OR (STG.FN_CLEAN(r.COUNTRY)     IS NOT NULL AND s.COUNTRY_RAW IS NULL)
           OR (STG.FN_CLEAN(r.IS_ACTIVE)   IS NOT NULL AND s.IS_ACTIVE   IS NULL));
    IF (v_loss > 0) THEN
        INSERT INTO CTRL.PROCESS_ERROR_LOG (LOAD_ID, SEVERITY, ERROR_DESCRIPTION)
        VALUES (:P_LOAD_ID, 'ERROR', 'COLUMN_VALUE_LOSS: ' || :v_loss || ' rows lost a value between raw and staging');
        v_errors := v_errors + 1;
    END IF;

    -- 3. business rule: reject rate. Only blocks on a real sized batch, tiny test files just warn.
    SELECT COUNT_IF(DQ_STATUS = 'REJECT') INTO :v_rej FROM STG.MEMBER WHERE LOAD_ID = :P_LOAD_ID;
    IF (v_stg > 0 AND v_rej * 100 / v_stg > v_max_pct AND v_stg >= v_min_rows) THEN
        INSERT INTO CTRL.PROCESS_ERROR_LOG (LOAD_ID, SEVERITY, ERROR_DESCRIPTION)
        VALUES (:P_LOAD_ID, 'ERROR', 'REJECT_RATE: ' || :v_rej || ' of ' || :v_stg || ' rows rejected, limit ' || :v_max_pct || '%');
        v_errors := v_errors + 1;
    ELSEIF (v_rej > 0) THEN
        INSERT INTO CTRL.PROCESS_ERROR_LOG (LOAD_ID, SEVERITY, ERROR_DESCRIPTION)
        VALUES (:P_LOAD_ID, 'WARN', 'REJECT_RATE: ' || :v_rej || ' of ' || :v_stg || ' rows rejected, see DQ.MEMBER_QUARANTINE');
    END IF;

    -- 4. key uniqueness: duplicates are resolved by latest record wins in publish, reported here
    SELECT COUNT(*) INTO :v_dup
    FROM (SELECT MEMBER_ID FROM STG.MEMBER
          WHERE LOAD_ID = :P_LOAD_ID AND MEMBER_ID IS NOT NULL
          GROUP BY MEMBER_ID HAVING COUNT(*) > 1);
    IF (v_dup > 0) THEN
        INSERT INTO CTRL.PROCESS_ERROR_LOG (LOAD_ID, SEVERITY, ERROR_DESCRIPTION)
        VALUES (:P_LOAD_ID, 'WARN', 'DUPLICATE_MEMBER_ID: ' || :v_dup || ' member ids appear more than once in this load');
    END IF;

    IF (v_errors > 0) THEN
        RAISE data_check_failed;
    END IF;

    rs := (SELECT 0 AS INS_COUNT, 0 AS UPD_COUNT, 0 AS DEL_COUNT);
    RETURN TABLE(rs);
END;
$$;

/* ------------------------------------------------------------------------ */
CREATE OR REPLACE PROCEDURE MAIN.SP_PUBLISH_MEMBER(P_LOAD_ID NUMBER)
RETURNS TABLE (INS_COUNT NUMBER, UPD_COUNT NUMBER, DEL_COUNT NUMBER)
LANGUAGE SQL
AS
$$
DECLARE
    v_ins    NUMBER DEFAULT 0;
    v_upd    NUMBER DEFAULT 0;
    v_del    NUMBER DEFAULT 0;
    v_code   VARCHAR;
    v_table  VARCHAR;
    v_sql    VARCHAR;
    rs       RESULTSET;
    c_country CURSOR FOR
        SELECT COUNTRY_CODE, UPPER(TARGET_TABLE) AS TARGET_TABLE
        FROM CTRL.COUNTRY_CONFIG
        WHERE IS_ACTIVE;
    bad_table_name EXCEPTION (-20001, 'COUNTRY_CONFIG has an invalid TARGET_TABLE name');
BEGIN
    /* Work tables are created before the transaction starts, because in Snowflake
       any CREATE (even a temporary table) commits the open transaction. */

    -- Step 1: candidates. Newest file wins; inside that file the later flight date wins.
    -- VERSIONS > 1 means the same member is still there with different values: we can't tell
    -- which one is right, so those rows go to quarantine.
    CREATE OR REPLACE TEMPORARY TABLE MAIN.TMP_MEMBER_CANDIDATE AS
    WITH ok_rows AS (
        SELECT s.*,
               MAX(s.FILE_TS) OVER (PARTITION BY s.MEMBER_ID) AS MAX_FILE_TS
        FROM STG.MEMBER s
        WHERE s.LOAD_ID = :P_LOAD_ID
          AND s.DQ_STATUS <> 'REJECT'
    ),
    latest_file AS (
        SELECT o.*,
               MAX(o.LAST_FLIGHT_DATE) OVER (PARTITION BY o.MEMBER_ID) AS MAX_FLIGHT
        FROM ok_rows o
        WHERE o.FILE_TS = o.MAX_FILE_TS
    )
    SELECT l.*,
           COUNT(DISTINCT HASH(l.MEMBER_NAME, l.ENROLLMENT_DATE, l.LAST_FLIGHT_DATE, l.TIER_CODE,
                               l.AGENT_NAME, l.STATE, l.COUNTRY_CODE, l.DOB, l.IS_ACTIVE))
               OVER (PARTITION BY l.MEMBER_ID) AS VERSIONS
    FROM latest_file l
    WHERE EQUAL_NULL(l.LAST_FLIGHT_DATE, l.MAX_FLIGHT);

    -- Step 2: what actually changes, compared with what is published now.
    CREATE OR REPLACE TEMPORARY TABLE MAIN.TMP_MEMBER_PUBLISH AS
    SELECT w.MEMBER_ID, w.MEMBER_NAME, w.ENROLLMENT_DATE, w.LAST_FLIGHT_DATE, w.TIER_CODE,
           w.AGENT_NAME, w.STATE, w.COUNTRY_CODE, w.POST_CODE, w.DOB, w.IS_ACTIVE,
           w.FILE_TS::DATE AS AS_OF_DATE, w.AGE, w.STALE_MEMBER, w.FILE_TS, w.LOAD_ID,
           mc.COUNTRY_CODE AS OLD_COUNTRY_CODE,
           CASE WHEN mc.MEMBER_ID IS NULL               THEN 'NEW'
                WHEN mc.COUNTRY_CODE <> w.COUNTRY_CODE THEN 'MOVE'
                ELSE 'UPDATE'
           END AS CHANGE_TYPE
    FROM (SELECT * FROM MAIN.TMP_MEMBER_CANDIDATE
          WHERE VERSIONS = 1
          QUALIFY ROW_NUMBER() OVER (PARTITION BY MEMBER_ID ORDER BY FILE_ROW_NUMBER) = 1) w
    LEFT JOIN MAIN.MEMBER_CURRENT mc
           ON mc.MEMBER_ID = w.MEMBER_ID
    WHERE mc.MEMBER_ID IS NULL                          -- new member
       OR (    w.FILE_TS >= mc.FILE_TS                  -- a late, older file is ignored (A3)
           AND NOT (    EQUAL_NULL(w.MEMBER_NAME,      mc.MEMBER_NAME)
                    AND EQUAL_NULL(w.ENROLLMENT_DATE,  mc.ENROLLMENT_DATE)
                    AND EQUAL_NULL(w.LAST_FLIGHT_DATE, mc.LAST_FLIGHT_DATE)
                    AND EQUAL_NULL(w.TIER_CODE,        mc.TIER_CODE)
                    AND EQUAL_NULL(w.AGENT_NAME,       mc.AGENT_NAME)
                    AND EQUAL_NULL(w.STATE,            mc.STATE)
                    AND EQUAL_NULL(w.COUNTRY_CODE,     mc.COUNTRY_CODE)
                    AND EQUAL_NULL(w.DOB,              mc.DOB)
                    AND EQUAL_NULL(w.IS_ACTIVE,        mc.IS_ACTIVE)
                    AND EQUAL_NULL(w.AGE,              mc.AGE)
                    AND EQUAL_NULL(w.STALE_MEMBER,     mc.STALE_MEMBER)));  -- nothing changed: leave the row alone

    SELECT COUNT_IF(CHANGE_TYPE IN ('NEW', 'MOVE')), COUNT_IF(CHANGE_TYPE = 'UPDATE'), COUNT_IF(CHANGE_TYPE = 'MOVE')
      INTO :v_ins, :v_upd, :v_del
    FROM MAIN.TMP_MEMBER_PUBLISH;

    BEGIN TRANSACTION;

    -- conflicting duplicates to quarantine (cleared first so a rerun doesn't duplicate them)
    DELETE FROM DQ.MEMBER_QUARANTINE
    WHERE LOAD_ID = :P_LOAD_ID
      AND ARRAY_CONTAINS('DUPLICATE_MEMBER_CONFLICT'::VARIANT, REASON);

    INSERT INTO DQ.MEMBER_QUARANTINE (LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, REASON)
    SELECT LOAD_ID, FILE_NAME, FILE_ROW_NUMBER, MEMBER_ID, ARRAY_CONSTRUCT('DUPLICATE_MEMBER_CONFLICT')
    FROM MAIN.TMP_MEMBER_CANDIDATE
    WHERE VERSIONS > 1;

    -- history of country moves
    INSERT INTO MAIN.MEMBER_COUNTRY_MOVE (MEMBER_ID, OLD_COUNTRY_CODE, NEW_COUNTRY_CODE, FILE_TS, LOAD_ID)
    SELECT MEMBER_ID, OLD_COUNTRY_CODE, COUNTRY_CODE, FILE_TS, LOAD_ID
    FROM MAIN.TMP_MEMBER_PUBLISH
    WHERE CHANGE_TYPE = 'MOVE';

    -- each country table: movers out, then new / moved in / changed members in
    FOR rec IN c_country DO
        v_code  := rec.COUNTRY_CODE;
        v_table := rec.TARGET_TABLE;

        -- the name goes straight into the SQL text, so only allow TABLE_ + letters/underscore
        IF (NOT REGEXP_LIKE(v_table, '^TABLE_[A-Z_]+$')) THEN
            RAISE bad_table_name;
        END IF;

        v_sql := 'DELETE FROM MAIN.' || v_table || '
                  WHERE MEMBER_ID IN (SELECT MEMBER_ID FROM MAIN.TMP_MEMBER_PUBLISH
                                      WHERE CHANGE_TYPE = ''MOVE'' AND OLD_COUNTRY_CODE = ?)';
        EXECUTE IMMEDIATE :v_sql USING (v_code);

        v_sql := 'MERGE INTO MAIN.' || v_table || ' t
                  USING (SELECT * FROM MAIN.TMP_MEMBER_PUBLISH WHERE COUNTRY_CODE = ?) s
                  ON t.MEMBER_ID = s.MEMBER_ID
                  WHEN MATCHED THEN UPDATE SET
                      t.MEMBER_NAME = s.MEMBER_NAME, t.ENROLLMENT_DATE = s.ENROLLMENT_DATE,
                      t.LAST_FLIGHT_DATE = s.LAST_FLIGHT_DATE, t.TIER_CODE = s.TIER_CODE,
                      t.AGENT_NAME = s.AGENT_NAME, t.STATE = s.STATE, t.COUNTRY_CODE = s.COUNTRY_CODE,
                      t.POST_CODE = s.POST_CODE, t.DOB = s.DOB, t.IS_ACTIVE = s.IS_ACTIVE,
                      t.AS_OF_DATE = s.AS_OF_DATE, t.AGE = s.AGE, t.STALE_MEMBER = s.STALE_MEMBER,
                      t.LOAD_ID = s.LOAD_ID, t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
                  WHEN NOT MATCHED THEN INSERT
                      (MEMBER_ID, MEMBER_NAME, ENROLLMENT_DATE, LAST_FLIGHT_DATE, TIER_CODE, AGENT_NAME,
                       STATE, COUNTRY_CODE, POST_CODE, DOB, IS_ACTIVE, AS_OF_DATE, AGE, STALE_MEMBER,
                       LOAD_ID, INSERT_DATE, LAST_UPDATE_DATE)
                  VALUES
                      (s.MEMBER_ID, s.MEMBER_NAME, s.ENROLLMENT_DATE, s.LAST_FLIGHT_DATE, s.TIER_CODE, s.AGENT_NAME,
                       s.STATE, s.COUNTRY_CODE, s.POST_CODE, s.DOB, s.IS_ACTIVE, s.AS_OF_DATE, s.AGE, s.STALE_MEMBER,
                       s.LOAD_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())';
        EXECUTE IMMEDIATE :v_sql USING (v_code);
    END FOR;

    -- the one list of where every member is now
    MERGE INTO MAIN.MEMBER_CURRENT t
    USING MAIN.TMP_MEMBER_PUBLISH s
    ON t.MEMBER_ID = s.MEMBER_ID
    WHEN MATCHED THEN UPDATE SET
        t.MEMBER_NAME = s.MEMBER_NAME, t.ENROLLMENT_DATE = s.ENROLLMENT_DATE,
        t.LAST_FLIGHT_DATE = s.LAST_FLIGHT_DATE, t.TIER_CODE = s.TIER_CODE,
        t.AGENT_NAME = s.AGENT_NAME, t.STATE = s.STATE, t.COUNTRY_CODE = s.COUNTRY_CODE,
        t.POST_CODE = s.POST_CODE, t.DOB = s.DOB, t.IS_ACTIVE = s.IS_ACTIVE,
        t.AGE = s.AGE, t.STALE_MEMBER = s.STALE_MEMBER, t.FILE_TS = s.FILE_TS,
        t.LOAD_ID = s.LOAD_ID, t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (MEMBER_ID, MEMBER_NAME, ENROLLMENT_DATE, LAST_FLIGHT_DATE, TIER_CODE, AGENT_NAME,
         STATE, COUNTRY_CODE, POST_CODE, DOB, IS_ACTIVE, AGE, STALE_MEMBER, FILE_TS,
         LOAD_ID, INSERT_DATE, LAST_UPDATE_DATE)
    VALUES
        (s.MEMBER_ID, s.MEMBER_NAME, s.ENROLLMENT_DATE, s.LAST_FLIGHT_DATE, s.TIER_CODE, s.AGENT_NAME,
         s.STATE, s.COUNTRY_CODE, s.POST_CODE, s.DOB, s.IS_ACTIVE, s.AGE, s.STALE_MEMBER, s.FILE_TS,
         s.LOAD_ID, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

    COMMIT;

    rs := (SELECT :v_ins AS INS_COUNT, :v_upd AS UPD_COUNT, :v_del AS DEL_COUNT);
    RETURN TABLE(rs);

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;     -- nothing half published
        RAISE;        -- the master logs it
END;
$$;
