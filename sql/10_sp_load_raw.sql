/* 10_sp_load_raw.sql
   Raw load procs: stage files -> RAW tables with COPY INTO.

   Every child proc in this project has the same shape, so the master proc
   can call any of them the same way:
     CALL proc(load_id)
     returns one row: INS_COUNT, UPD_COUNT, DEL_COUNT
   Rejected rows are not counted here; they sit in the DQ quarantine tables.

   COPY INTO remembers which files it already loaded (load metadata), so a rerun
   never loads the same file twice. Uploading a new file and running again only
   picks up the new file. */

USE DATABASE SKYPOINTS_DB;

-- Member file. Each line starts with |, so $1 is always empty and $2 is the record type.
CREATE OR REPLACE PROCEDURE RAW.SP_LOAD_RAW_MEMBER(P_LOAD_ID NUMBER)
RETURNS TABLE (INS_COUNT NUMBER, UPD_COUNT NUMBER, DEL_COUNT NUMBER)
LANGUAGE SQL
AS
$$
DECLARE
    v_sql  VARCHAR;
    v_ins  NUMBER DEFAULT 0;
    rs     RESULTSET;
BEGIN
    -- load id goes in as a literal because COPY can't take bind variables
    v_sql := 'COPY INTO RAW.MEMBER_FILE
                (RECORD_TYPE, MEMBER_NAME, MEMBER_ID, ENROLLMENT_DATE, LAST_FLIGHT_DATE,
                 TIER_CODE, AGENT_NAME, STATE, COUNTRY, DOB, IS_ACTIVE,
                 FILE_NAME, FILE_ROW_NUMBER, LOAD_ID)
              FROM (SELECT $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
                           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, ' || P_LOAD_ID || '
                    FROM @RAW.LANDING/members/)
              FILE_FORMAT = (FORMAT_NAME = ''RAW.FF_MEMBER_PIPE'')
              PATTERN = ''.*members_[0-9]{8}_[0-9]{6}[.]txt''
              ON_ERROR = ''CONTINUE''';

    EXECUTE IMMEDIATE :v_sql;

    SELECT COUNT(*) INTO :v_ins FROM RAW.MEMBER_FILE WHERE LOAD_ID = :P_LOAD_ID;

    rs := (SELECT :v_ins AS INS_COUNT, 0 AS UPD_COUNT, 0 AS DEL_COUNT);
    RETURN TABLE(rs);
END;
$$;

-- Redemption feed. One row per JSON document.
CREATE OR REPLACE PROCEDURE RAW.SP_LOAD_RAW_REDEMPTION(P_LOAD_ID NUMBER)
RETURNS TABLE (INS_COUNT NUMBER, UPD_COUNT NUMBER, DEL_COUNT NUMBER)
LANGUAGE SQL
AS
$$
DECLARE
    v_sql  VARCHAR;
    v_ins  NUMBER DEFAULT 0;
    rs     RESULTSET;
BEGIN
    v_sql := 'COPY INTO RAW.REDEMPTION_FEED (PAYLOAD, FILE_NAME, FILE_ROW_NUMBER, LOAD_ID)
              FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, ' || P_LOAD_ID || '
                    FROM @RAW.LANDING/redemptions/)
              FILE_FORMAT = (FORMAT_NAME = ''RAW.FF_REDEMPTION_JSON'')
              PATTERN = ''.*redemptions_[0-9]{8}[.]json''
              ON_ERROR = ''CONTINUE''';

    EXECUTE IMMEDIATE :v_sql;

    SELECT COUNT(*) INTO :v_ins FROM RAW.REDEMPTION_FEED WHERE LOAD_ID = :P_LOAD_ID;

    rs := (SELECT :v_ins AS INS_COUNT, 0 AS UPD_COUNT, 0 AS DEL_COUNT);
    RETURN TABLE(rs);
END;
$$;
