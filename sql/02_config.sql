/* 02_config.sql
   Config seed data and the country tables.
   Seeds use MERGE so a rerun never duplicates rows. */

USE DATABASE SKYPOINTS_DB;

/* ---------------- Key-value settings ---------------- */

MERGE INTO CTRL.KEY_VALUE_CONFIG t
USING (
    SELECT * FROM (VALUES
        ('STG.MEMBER',         'STG.SP_LOAD_MEMBER',        'STALE_DAYS',           '90'),
        ('STG.MEMBER',         'MAIN.SP_VALIDATE_MEMBER',   'REJECT_RATE_MAX_PCT',  '5'),
        ('STG.MEMBER',         'MAIN.SP_VALIDATE_MEMBER',   'REJECT_RATE_MIN_ROWS', '100'),
        ('MAIN.REDEMPTION_TXN','MAIN.SP_LOAD_REDEMPTIONS',  'VALID_STATUS',         'COMPLETED,PENDING,CANCELLED,REVERSED')
    ) AS v (BASE_TABLE_NAME, SP_OR_VIEW_NAME, COLUMN_NAME, KEY_VALUE)
) s
ON  t.BASE_TABLE_NAME = s.BASE_TABLE_NAME
AND t.SP_OR_VIEW_NAME = s.SP_OR_VIEW_NAME
AND t.COLUMN_NAME     = s.COLUMN_NAME
WHEN MATCHED AND t.KEY_VALUE <> s.KEY_VALUE THEN UPDATE SET
    t.KEY_VALUE        = s.KEY_VALUE,
    t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (BASE_TABLE_NAME, SP_OR_VIEW_NAME, COLUMN_NAME, KEY_VALUE)
    VALUES (s.BASE_TABLE_NAME, s.SP_OR_VIEW_NAME, s.COLUMN_NAME, s.KEY_VALUE);

/* ---------------- Countries ---------------- */

-- Starting list, taken from the sample data. A new country = one row here.
MERGE INTO CTRL.COUNTRY_CONFIG t
USING (
    SELECT * FROM (VALUES
        ('USA', 'United States', 'TABLE_USA'),
        ('IND', 'India',         'TABLE_INDIA'),
        ('PHL', 'Philippines',   'TABLE_PHILIPPINES'),
        ('CAN', 'Canada',        'TABLE_CANADA'),
        ('AUS', 'Australia',     'TABLE_AUSTRALIA')
    ) AS v (COUNTRY_CODE, COUNTRY_NAME, TARGET_TABLE)
) s
ON t.COUNTRY_CODE = s.COUNTRY_CODE
WHEN MATCHED AND (t.COUNTRY_NAME <> s.COUNTRY_NAME OR t.TARGET_TABLE <> s.TARGET_TABLE) THEN UPDATE SET
    t.COUNTRY_NAME     = s.COUNTRY_NAME,
    t.TARGET_TABLE     = s.TARGET_TABLE,
    t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (COUNTRY_CODE, COUNTRY_NAME, TARGET_TABLE, IS_ACTIVE)
    VALUES (s.COUNTRY_CODE, s.COUNTRY_NAME, s.TARGET_TABLE, TRUE);

-- Every value we have seen from the source, plus each clean code mapping to itself.
MERGE INTO CTRL.COUNTRY_CODE_MAP t
USING (
    SELECT * FROM (VALUES
        ('USA',  'USA'),
        ('IND',  'IND'),
        ('PHL',  'PHL'),
        ('PHIL', 'PHL'),
        ('CAN',  'CAN'),
        ('AUS',  'AUS'),
        ('AU',   'AUS')
    ) AS v (SOURCE_VALUE, COUNTRY_CODE)
) s
ON t.SOURCE_VALUE = s.SOURCE_VALUE
WHEN MATCHED AND t.COUNTRY_CODE <> s.COUNTRY_CODE THEN UPDATE SET
    t.COUNTRY_CODE     = s.COUNTRY_CODE,
    t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (SOURCE_VALUE, COUNTRY_CODE)
    VALUES (s.SOURCE_VALUE, s.COUNTRY_CODE);

/* ---------------- Tiers ---------------- */

MERGE INTO CTRL.TIER_REF t
USING (
    SELECT * FROM (VALUES
        ('SLV', 'Silver'),
        ('GLD', 'Gold'),
        ('PLT', 'Platinum')
    ) AS v (TIER_CODE, TIER_NAME)
) s
ON t.TIER_CODE = s.TIER_CODE
WHEN MATCHED AND t.TIER_NAME <> s.TIER_NAME THEN UPDATE SET
    t.TIER_NAME        = s.TIER_NAME,
    t.LAST_UPDATE_DATE = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (TIER_CODE, TIER_NAME)
    VALUES (s.TIER_CODE, s.TIER_NAME);

/* ---------------- Country tables ---------------- */

-- Loops over the active countries and creates any table that doesn't exist yet,
-- from the one template. Existing tables are not touched, so it's safe to rerun
-- and it's also how a new country gets its table.
CREATE OR REPLACE PROCEDURE CTRL.SP_CREATE_COUNTRY_TABLES()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_table    VARCHAR;
    v_count    NUMBER DEFAULT 0;
    c_country  CURSOR FOR
        SELECT TARGET_TABLE
        FROM CTRL.COUNTRY_CONFIG
        WHERE IS_ACTIVE
        ORDER BY COUNTRY_CODE;
    bad_table_name EXCEPTION (-20001, 'COUNTRY_CONFIG has an invalid TARGET_TABLE name');
BEGIN
    FOR rec IN c_country DO
        v_table := UPPER(rec.TARGET_TABLE);

        -- the name is put straight into DDL, so only allow TABLE_ + letters/underscore
        IF (NOT REGEXP_LIKE(v_table, '^TABLE_[A-Z_]+$')) THEN
            RAISE bad_table_name;
        END IF;

        EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS MAIN.' || v_table ||
                          ' LIKE MAIN.MEMBER_COUNTRY_TEMPLATE';
        v_count := v_count + 1;
    END FOR;

    RETURN v_count || ' country tables in place';
END;
$$;

CALL CTRL.SP_CREATE_COUNTRY_TABLES();

/* ---------------- Check ---------------- */

SELECT c.COUNTRY_CODE, c.TARGET_TABLE,
       IFF(t.TABLE_NAME IS NULL, 'MISSING', 'OK') AS TABLE_STATUS
FROM CTRL.COUNTRY_CONFIG c
LEFT JOIN SKYPOINTS_DB.INFORMATION_SCHEMA.TABLES t
       ON t.TABLE_SCHEMA = 'MAIN' AND t.TABLE_NAME = c.TARGET_TABLE
ORDER BY c.COUNTRY_CODE;
