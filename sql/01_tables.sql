/* 01_tables.sql
   All tables for every layer. Safe to rerun (IF NOT EXISTS).

   Audit columns on every table:
     LOAD_ID           the run that last wrote the row. NOT NULL on every table the
                       pipeline loads. Config tables don't have it: they are set up
                       by script, not by a pipeline run.
     INSERT_DATE       when the row was created
     LAST_UPDATE_DATE  when the row last changed (same as INSERT_DATE on insert).
                       Left out of insert-only tables (raw, staging, move history,
                       error log): their rows are never updated.
   File name and row number are kept only in raw, staging and quarantine,
   which is where you need them to trace a row back to the source line.

   Note: Snowflake doesn't enforce PRIMARY KEY. I declare it anyway to document
   the key, and the pipeline itself guarantees uniqueness. */

USE DATABASE SKYPOINTS_DB;

/* ---------------- CTRL: config ---------------- */

-- One place for thresholds and settings, so nothing is hardcoded in the procs.
-- Same shape as the key-value table I used in production: a value is identified by
-- the table it applies to, the proc or view that reads it, and the column/setting name.
CREATE TABLE IF NOT EXISTS CTRL.KEY_VALUE_CONFIG (
    BASE_TABLE_NAME   VARCHAR(100)  NOT NULL,
    SP_OR_VIEW_NAME   VARCHAR(100)  NOT NULL,
    COLUMN_NAME       VARCHAR(100)  NOT NULL,
    KEY_VALUE         VARCHAR(1000) NOT NULL,
    IS_ACTIVE         BOOLEAN       DEFAULT TRUE,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (BASE_TABLE_NAME, SP_OR_VIEW_NAME, COLUMN_NAME)
);

-- The fixed list of countries. Each active row gets its own table in MAIN.
CREATE TABLE IF NOT EXISTS CTRL.COUNTRY_CONFIG (
    COUNTRY_CODE      VARCHAR(3)    NOT NULL PRIMARY KEY,
    COUNTRY_NAME      VARCHAR(100)  NOT NULL,
    TARGET_TABLE      VARCHAR(100)  NOT NULL,
    IS_ACTIVE         BOOLEAN       DEFAULT TRUE,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Maps whatever the source sends (PHIL, AU, ...) to one country code.
CREATE TABLE IF NOT EXISTS CTRL.COUNTRY_CODE_MAP (
    SOURCE_VALUE      VARCHAR(20)   NOT NULL PRIMARY KEY,
    COUNTRY_CODE      VARCHAR(3)    NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS CTRL.TIER_REF (
    TIER_CODE         VARCHAR(5)    NOT NULL PRIMARY KEY,
    TIER_NAME         VARCHAR(50)   NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* ---------------- CTRL: orchestration ---------------- */
-- Same four tables as my master procedure framework:
--   PROCESS_REGISTRY   which procs to run and in what order
--   LOAD_CONTROL       one row per run
--   PROCESS_EXEC_LOG   one row per proc per run, with counts
--   PROCESS_ERROR_LOG  one row per error
-- Status codes: I = in progress, C = completed, E = error, B = blocked by a data check.

CREATE TABLE IF NOT EXISTS CTRL.PROCESS_REGISTRY (
    SP_ID             NUMBER        IDENTITY(1,1) PRIMARY KEY,
    SP_NAME           VARCHAR(200)  NOT NULL,
    SP_EXECUTION_ORDER NUMBER       NOT NULL,
    SP_ACT_FLG        BOOLEAN       DEFAULT TRUE,     -- switch a step off without deleting it
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS CTRL.LOAD_CONTROL (
    LOAD_ID           NUMBER        IDENTITY(1,1) PRIMARY KEY,
    LOAD_STATUS       VARCHAR(1)    NOT NULL,         -- I / C / E / B
    LOAD_ST           TIMESTAMP_NTZ,                  -- start time
    LOAD_ET           TIMESTAMP_NTZ                   -- end time
);

CREATE TABLE IF NOT EXISTS CTRL.PROCESS_EXEC_LOG (
    SP_EXE_LOG_ID     NUMBER        IDENTITY(1,1) PRIMARY KEY,
    LOAD_ID           NUMBER        NOT NULL,
    SP_ID             NUMBER        NOT NULL,
    SP_EXE_LOG_STATUS VARCHAR(1)    DEFAULT 'I',      -- I / C / E / B
    INS_CNT           NUMBER,
    UPD_CNT           NUMBER,
    DEL_CNT           NUMBER,
    REJ_CNT           NUMBER,                         -- rows sent to quarantine
    SP_EXE_LOG_ST     TIMESTAMP_NTZ,                  -- start time
    SP_EXE_LOG_ET     TIMESTAMP_NTZ                   -- end time
);

-- SQL errors caught by the master proc, and failed data checks from the validate step.
-- ERROR stops the run; WARN is only recorded.
CREATE TABLE IF NOT EXISTS CTRL.PROCESS_ERROR_LOG (
    ERROR_LOG_ID      NUMBER        IDENTITY(1,1) PRIMARY KEY,
    LOAD_ID           NUMBER        NOT NULL,
    SP_EXE_LOG_ID     NUMBER,
    SEVERITY          VARCHAR(10)   NOT NULL,         -- ERROR / WARN
    ERROR_DESCRIPTION VARCHAR(4000),                  -- sqlcode: sqlerrm: sqlstate, or the check that failed
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* ---------------- RAW: exactly as received ---------------- */

-- One row per member line. Every column is text, exactly as received,
-- so nothing can fail or get changed on the way in. Typing happens in staging.
CREATE TABLE IF NOT EXISTS RAW.MEMBER_FILE (
    RECORD_TYPE       VARCHAR,
    MEMBER_NAME       VARCHAR,
    MEMBER_ID         VARCHAR,
    ENROLLMENT_DATE   VARCHAR,
    LAST_FLIGHT_DATE  VARCHAR,
    TIER_CODE         VARCHAR,
    AGENT_NAME        VARCHAR,
    STATE             VARCHAR,
    COUNTRY           VARCHAR,
    DOB               VARCHAR,
    IS_ACTIVE         VARCHAR,
    FILE_NAME         VARCHAR(500)  NOT NULL,   -- which file
    FILE_ROW_NUMBER   NUMBER        NOT NULL,   -- which line in that file
    LOAD_ID           NUMBER        NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One row per JSON document.
CREATE TABLE IF NOT EXISTS RAW.REDEMPTION_FEED (
    PAYLOAD           VARIANT,
    FILE_NAME         VARCHAR(500)  NOT NULL,
    FILE_ROW_NUMBER   NUMBER        NOT NULL,
    LOAD_ID           NUMBER        NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* ---------------- STG: typed and checked ---------------- */

-- Transient: staging can always be rebuilt from raw, so no need to pay
-- for Fail-safe on it.
-- Text columns have no length limit here on purpose. A value that is too
-- long must be flagged as a DQ issue, not crash the insert.
CREATE TRANSIENT TABLE IF NOT EXISTS STG.MEMBER (
    LOAD_ID           NUMBER        NOT NULL,
    FILE_NAME         VARCHAR(500)  NOT NULL,
    FILE_ROW_NUMBER   NUMBER        NOT NULL,
    FILE_TS           TIMESTAMP_NTZ,              -- date and time from the file name
    MEMBER_NAME       VARCHAR,
    MEMBER_ID         VARCHAR,
    ENROLLMENT_DATE   DATE,
    LAST_FLIGHT_DATE  DATE,
    TIER_CODE         VARCHAR,
    AGENT_NAME        VARCHAR,
    STATE             VARCHAR,
    COUNTRY_RAW       VARCHAR,                    -- as sent, e.g. PHIL
    COUNTRY_CODE      VARCHAR(3),                 -- after mapping, e.g. PHL
    POST_CODE         NUMBER(5,0),                -- in the spec, not in the file yet
    DOB               DATE,
    IS_ACTIVE         VARCHAR,
    AGE               NUMBER(3,0),
    STALE_MEMBER      BOOLEAN,
    DQ_STATUS         VARCHAR(10),                -- PASS / WARN / REJECT
    DQ_ISSUES         ARRAY,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* ---------------- MAIN: final loaded data ---------------- */

-- Every country table is created from this one definition (CREATE TABLE ... LIKE),
-- so they can never drift apart. Lengths follow the spec layout.
CREATE TABLE IF NOT EXISTS MAIN.MEMBER_COUNTRY_TEMPLATE (
    MEMBER_ID         VARCHAR(18)   NOT NULL PRIMARY KEY,
    MEMBER_NAME       VARCHAR(255)  NOT NULL,
    ENROLLMENT_DATE   DATE          NOT NULL,
    LAST_FLIGHT_DATE  DATE,
    TIER_CODE         VARCHAR(5),
    AGENT_NAME        VARCHAR(255),
    STATE             VARCHAR(5),
    COUNTRY_CODE      VARCHAR(3)    NOT NULL,
    POST_CODE         NUMBER(5,0),
    DOB               DATE,
    IS_ACTIVE         VARCHAR(1),
    AS_OF_DATE        DATE,                       -- Age and Stale are as of this date
    AGE               NUMBER(3,0),
    STALE_MEMBER      BOOLEAN,
    LOAD_ID           NUMBER        NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One row per member across all countries: which country they are in now.
-- Used to route moves between country tables and as the join target for redemptions.
-- FILE_TS is the version of the published record, so a late older file can't overwrite it.
CREATE TABLE IF NOT EXISTS MAIN.MEMBER_CURRENT (
    MEMBER_ID         VARCHAR(18)   NOT NULL PRIMARY KEY,
    MEMBER_NAME       VARCHAR(255)  NOT NULL,
    ENROLLMENT_DATE   DATE          NOT NULL,
    LAST_FLIGHT_DATE  DATE,
    TIER_CODE         VARCHAR(5),
    AGENT_NAME        VARCHAR(255),
    STATE             VARCHAR(5),
    COUNTRY_CODE      VARCHAR(3)    NOT NULL,
    POST_CODE         NUMBER(5,0),
    DOB               DATE,
    IS_ACTIVE         VARCHAR(1),
    AGE               NUMBER(3,0),
    STALE_MEMBER      BOOLEAN,
    FILE_TS           TIMESTAMP_NTZ NOT NULL,
    LOAD_ID           NUMBER        NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- History of country moves.
CREATE TABLE IF NOT EXISTS MAIN.MEMBER_COUNTRY_MOVE (
    MEMBER_ID         VARCHAR(18)   NOT NULL,
    OLD_COUNTRY_CODE  VARCHAR(3)    NOT NULL,
    NEW_COUNTRY_CODE  VARCHAR(3)    NOT NULL,
    FILE_TS           TIMESTAMP_NTZ NOT NULL,
    LOAD_ID           NUMBER        NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Flattened redemption feed, one row per transaction. Many rows per member,
-- joined to MAIN.MEMBER_CURRENT on MEMBER_ID.
CREATE TABLE IF NOT EXISTS MAIN.REDEMPTION_TXN (
    TXN_ID            VARCHAR(50)   NOT NULL PRIMARY KEY,
    MEMBER_ID         VARCHAR(18)   NOT NULL,
    FEED_DATE         DATE          NOT NULL,
    TXN_DATE          DATE,
    PARTNER           VARCHAR(100),
    MILES_REDEEMED    NUMBER(18,0),
    STATUS            VARCHAR(20),
    DQ_ISSUES         ARRAY,                      -- warnings, row is still kept
    LOAD_ID           NUMBER        NOT NULL,
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* ---------------- DQ: quarantine and checks ---------------- */

CREATE TABLE IF NOT EXISTS DQ.MEMBER_QUARANTINE (
    LOAD_ID           NUMBER        NOT NULL,
    FILE_NAME         VARCHAR(500)  NOT NULL,
    FILE_ROW_NUMBER   NUMBER        NOT NULL,
    MEMBER_ID         VARCHAR,
    REASON            ARRAY,
    STATUS            VARCHAR(20)   DEFAULT 'OPEN',   -- OPEN / REPROCESSED
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS DQ.REDEMPTION_QUARANTINE (
    LOAD_ID           NUMBER        NOT NULL,
    FILE_NAME         VARCHAR(500)  NOT NULL,
    FILE_ROW_NUMBER   NUMBER        NOT NULL,
    MEMBER_ID         VARCHAR,
    TXN_ID            VARCHAR,
    PAYLOAD           VARIANT,
    REASON            ARRAY,
    STATUS            VARCHAR(20)   DEFAULT 'OPEN',
    INSERT_DATE       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_UPDATE_DATE  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
FROM SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA IN ('CTRL','RAW','STG','MAIN','DQ')
ORDER BY TABLE_SCHEMA, TABLE_NAME;
