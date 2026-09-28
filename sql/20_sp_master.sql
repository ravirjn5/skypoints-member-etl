/* 20_sp_master.sql
   Master procedure: runs every step of the daily load in order, logs each one,
   and on a rerun resumes from the step that failed.

   Same framework I built before:
     PROCESS_REGISTRY   which procs to run, in which order (add a step = add a row)
     LOAD_CONTROL       one row per run: I / C / E
     PROCESS_EXEC_LOG   one row per proc per run, with INS / UPD / DEL counts
     PROCESS_ERROR_LOG  sqlcode: sqlerrm: sqlstate for anything that fails
   Execution is serial, one proc after another. */

USE DATABASE SKYPOINTS_DB;

/* ---------------- Registry ---------------- */

MERGE INTO CTRL.PROCESS_REGISTRY t
USING (
    SELECT * FROM (VALUES
        ('RAW.SP_LOAD_RAW_MEMBER',      10),
        ('RAW.SP_LOAD_RAW_REDEMPTION',  20),
        ('STG.SP_LOAD_MEMBER',          30),
        ('MAIN.SP_VALIDATE_MEMBER',     40),
        ('MAIN.SP_PUBLISH_MEMBER',      50),
        ('MAIN.SP_LOAD_REDEMPTIONS',    60)
    ) AS v (SP_NAME, SP_EXECUTION_ORDER)
) s
ON t.SP_NAME = s.SP_NAME
WHEN MATCHED AND t.SP_EXECUTION_ORDER <> s.SP_EXECUTION_ORDER THEN UPDATE SET
    t.SP_EXECUTION_ORDER = s.SP_EXECUTION_ORDER,
    t.LAST_UPDATE_DATE   = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (SP_NAME, SP_EXECUTION_ORDER, SP_ACT_FLG)
    VALUES (s.SP_NAME, s.SP_EXECUTION_ORDER, TRUE);

/* ---------------- Master procedure ---------------- */

CREATE OR REPLACE PROCEDURE CTRL.SP_MASTER_LOAD()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_resGetProcedure RESULTSET;
    v_resExeSP        RESULTSET;
    v_LoadId          NUMBER;
    v_SPID            NUMBER;
    v_SPNAME          VARCHAR;
    v_ExeLogId        NUMBER;
    v_SQL             VARCHAR;
    v_ErrorMsg        VARCHAR;
    v_InsCnt          NUMBER;
    v_UpdCnt          NUMBER;
    v_DelCnt          NUMBER;
BEGIN
    -- 1. resume the last load that errored or didn't finish, otherwise start a new one
    SELECT NVL(MAX(LOAD_ID), 0) INTO :v_LoadId
    FROM CTRL.LOAD_CONTROL
    WHERE LOAD_STATUS IN ('E', 'I');

    IF (v_LoadId = 0) THEN
        INSERT INTO CTRL.LOAD_CONTROL (LOAD_STATUS, LOAD_ST) VALUES ('I', CURRENT_TIMESTAMP());
        SELECT MAX(LOAD_ID) INTO :v_LoadId FROM CTRL.LOAD_CONTROL;   -- runs are serial, so MAX is this run
    ELSE
        UPDATE CTRL.LOAD_CONTROL SET LOAD_STATUS = 'I' WHERE LOAD_ID = :v_LoadId;
    END IF;

    -- 2. the steps to run: everything from the first active step not yet completed for this load.
    --    On a new load that's step 1; on a resume it's the step that failed.
    v_resGetProcedure := (
        SELECT SP_ID, SP_NAME
        FROM CTRL.PROCESS_REGISTRY
        WHERE SP_ACT_FLG
          AND SP_EXECUTION_ORDER >= (
                SELECT NVL(MIN(r.SP_EXECUTION_ORDER), 999999)
                FROM CTRL.PROCESS_REGISTRY r
                WHERE r.SP_ACT_FLG
                  AND r.SP_ID NOT IN (SELECT SP_ID FROM CTRL.PROCESS_EXEC_LOG
                                      WHERE LOAD_ID = :v_LoadId AND SP_EXE_LOG_STATUS = 'C'))
        ORDER BY SP_EXECUTION_ORDER);

    DECLARE
        curGetProcedure CURSOR FOR v_resGetProcedure;
    BEGIN
        FOR row_variable IN curGetProcedure DO
            v_SPID   := row_variable.SP_ID;
            v_SPNAME := row_variable.SP_NAME;

            -- 3. log the start of this step
            INSERT INTO CTRL.PROCESS_EXEC_LOG (LOAD_ID, SP_ID, SP_EXE_LOG_STATUS, SP_EXE_LOG_ST)
            VALUES (:v_LoadId, :v_SPID, 'I', CURRENT_TIMESTAMP());

            SELECT MAX(SP_EXE_LOG_ID) INTO :v_ExeLogId
            FROM CTRL.PROCESS_EXEC_LOG
            WHERE LOAD_ID = :v_LoadId AND SP_ID = :v_SPID;

            -- 4. run the child proc with the load id
            v_SQL := 'CALL ' || v_SPNAME || '(' || v_LoadId || ')';

            BEGIN
                v_resExeSP := (EXECUTE IMMEDIATE :v_SQL);
            EXCEPTION
                WHEN OTHER THEN
                    -- 5a. failure: error log, step E, load E, then stop and raise
                    v_ErrorMsg := SQLCODE || ': ' || SQLERRM || ': ' || SQLSTATE;

                    INSERT INTO CTRL.PROCESS_ERROR_LOG (LOAD_ID, SP_EXE_LOG_ID, SEVERITY, ERROR_DESCRIPTION)
                    VALUES (:v_LoadId, :v_ExeLogId, 'ERROR', :v_ErrorMsg);

                    UPDATE CTRL.PROCESS_EXEC_LOG
                    SET SP_EXE_LOG_STATUS = 'E', SP_EXE_LOG_ET = CURRENT_TIMESTAMP()
                    WHERE SP_EXE_LOG_ID = :v_ExeLogId;

                    UPDATE CTRL.LOAD_CONTROL
                    SET LOAD_STATUS = 'E', LOAD_ET = CURRENT_TIMESTAMP()
                    WHERE LOAD_ID = :v_LoadId;

                    RAISE;   -- the caller (scheduler) sees a real failure, not a success message
            END;

            -- 5b. success: read the counts the child returned and close the step
            DECLARE
                curExeSP CURSOR FOR v_resExeSP;
            BEGIN
                FOR row_SP IN curExeSP DO
                    v_InsCnt := row_SP.INS_COUNT;
                    v_UpdCnt := row_SP.UPD_COUNT;
                    v_DelCnt := row_SP.DEL_COUNT;
                END FOR;
            END;

            UPDATE CTRL.PROCESS_EXEC_LOG
            SET SP_EXE_LOG_STATUS = 'C',
                INS_CNT = :v_InsCnt,
                UPD_CNT = :v_UpdCnt,
                DEL_CNT = :v_DelCnt,
                SP_EXE_LOG_ET = CURRENT_TIMESTAMP()
            WHERE SP_EXE_LOG_ID = :v_ExeLogId;
        END FOR;
    END;

    -- 6. every step done: the load is complete (once, after the loop)
    UPDATE CTRL.LOAD_CONTROL
    SET LOAD_STATUS = 'C', LOAD_ET = CURRENT_TIMESTAMP()
    WHERE LOAD_ID = :v_LoadId;

    RETURN 'Load ' || v_LoadId || ' completed';
END;
$$;
