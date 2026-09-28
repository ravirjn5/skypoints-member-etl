/* run_step4_check.sql
   Manual run of the raw and staging procs for day 1, before the master proc exists.
   Upload first (Snowsight: Data > Databases > SKYPOINTS_DB > RAW > Stages > LANDING > + Files):
     data/brief_samples/members_20240115_010000.txt  -> path: members
     data/brief_samples/redemptions_20240115.json    -> path: redemptions */

USE DATABASE SKYPOINTS_DB;

LIST @RAW.LANDING;

-- a load id for this manual run
INSERT INTO CTRL.LOAD_CONTROL (LOAD_STATUS, LOAD_ST) VALUES ('I', CURRENT_TIMESTAMP());
SET LID = (SELECT MAX(LOAD_ID) FROM CTRL.LOAD_CONTROL);

CALL RAW.SP_LOAD_RAW_MEMBER($LID);       -- expect INS_COUNT 5
CALL RAW.SP_LOAD_RAW_REDEMPTION($LID);   -- expect INS_COUNT 1
CALL STG.SP_LOAD_MEMBER($LID);           -- expect INS_COUNT 5 (rejects, if any, are in DQ.MEMBER_QUARANTINE)

SELECT MEMBER_ID, MEMBER_NAME, COUNTRY_RAW, COUNTRY_CODE, ENROLLMENT_DATE, LAST_FLIGHT_DATE,
       DOB, AGE, STALE_MEMBER, DQ_STATUS, DQ_ISSUES, FILE_TS
FROM STG.MEMBER
ORDER BY FILE_ROW_NUMBER;
