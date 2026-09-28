/* run_step7_check.sql
   End to end with the master proc, from a clean database.

   Setup: DROP DATABASE IF EXISTS SKYPOINTS_DB; then run, in order:
   00_setup, 01_tables, 02_config, 10_sp_load_raw, 11_sp_load_staging,
   12_sp_validate_publish, 13_sp_redemptions, 20_sp_master. */

USE DATABASE SKYPOINTS_DB;

/* ===== DAY 1 =====
   Upload data/brief_samples/members_20240115_010000.txt -> path members
          data/brief_samples/redemptions_20240115.json   -> path redemptions */
CALL CTRL.SP_MASTER_LOAD();          -- expect 'Load 1 completed'

SELECT l.LOAD_ID, p.SP_NAME, l.SP_EXE_LOG_STATUS, l.INS_CNT, l.UPD_CNT, l.DEL_CNT
FROM CTRL.PROCESS_EXEC_LOG l JOIN CTRL.PROCESS_REGISTRY p ON p.SP_ID = l.SP_ID
ORDER BY l.SP_EXE_LOG_ID;
-- expect 6 steps, all C. Raw member 5, raw redemption 1, staging 5, publish 5, redemptions 2

/* ===== DAY 2 =====
   Upload data/test_scenarios/members_20240116_010000.txt -> path members
          data/test_scenarios/redemptions_20240116.json   -> path redemptions */
CALL CTRL.SP_MASTER_LOAD();          -- expect 'Load 2 completed'
-- publish 3 / 1 / 1, redemptions 2 / 1 / 0

/* ===== RESTART TEST =====
   Upload data/test_scenarios/members_20240114_230000.txt -> path members (the late file)
   Break one setting so the staging step fails: */
UPDATE CTRL.KEY_VALUE_CONFIG SET KEY_VALUE = 'abc' WHERE COLUMN_NAME = 'STALE_DAYS';   -- not a number

CALL CTRL.SP_MASTER_LOAD();          -- expect an error; load 3 = E, staging step = E

SELECT * FROM CTRL.LOAD_CONTROL ORDER BY LOAD_ID;
SELECT * FROM CTRL.PROCESS_ERROR_LOG ORDER BY ERROR_LOG_ID;

-- fix it and run again: the same load 3 resumes from the staging step,
-- the two raw steps are not run again
UPDATE CTRL.KEY_VALUE_CONFIG SET KEY_VALUE = '90' WHERE COLUMN_NAME = 'STALE_DAYS';
CALL CTRL.SP_MASTER_LOAD();          -- expect 'Load 3 completed'

SELECT l.LOAD_ID, p.SP_NAME, l.SP_EXE_LOG_STATUS, l.INS_CNT, l.UPD_CNT, l.DEL_CNT
FROM CTRL.PROCESS_EXEC_LOG l JOIN CTRL.PROCESS_REGISTRY p ON p.SP_ID = l.SP_ID
WHERE l.LOAD_ID = 3
ORDER BY l.SP_EXE_LOG_ID;
-- expect raw steps C once, staging E then C, rest C. Publish 0 / 0 / 0 (late file ignored)

SELECT MEMBER_ID, MEMBER_NAME, COUNTRY_CODE, FILE_TS FROM MAIN.MEMBER_CURRENT WHERE MEMBER_ID = '223458';
-- expect Ravi still USA
