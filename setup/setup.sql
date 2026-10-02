-- =============================================================================
-- NATIVE SNOWFLAKE CI/CD DEMO - ONE-TIME ACCOUNT SETUP
-- =============================================================================
-- Account infrastructure only: roles, warehouses, cost guardrails, environment
-- databases, the Git connection, CI service users and a synthetic source table.
-- Pipeline objects (tables, procedures, tasks, dashboard) are NOT created here.
-- They come from Git through pipelines/deploy.sql.
--
-- In production this file is what Terraform (or an admin runbook) would own.
--
-- Before running, replace every <your-org>, <your-org-id>, <your-repo> and
-- <your-repo-id>. Every statement can be rerun safely. IF NOT EXISTS keeps
-- existing objects as they are; it does not update their settings.
-- Never put a password or token in this file.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- 01 - Roles: one deploy role and one reader role per environment
-- =============================================================================
CREATE ROLE IF NOT EXISTS ANALYTICS_DEPLOY_DEV;
CREATE ROLE IF NOT EXISTS ANALYTICS_DEPLOY_QA;
CREATE ROLE IF NOT EXISTS ANALYTICS_DEPLOY_PRD;
CREATE ROLE IF NOT EXISTS ANALYTICS_READER_DEV;
CREATE ROLE IF NOT EXISTS ANALYTICS_READER_QA;
CREATE ROLE IF NOT EXISTS ANALYTICS_READER_PRD;

GRANT ROLE ANALYTICS_DEPLOY_DEV TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_DEPLOY_QA TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_DEPLOY_PRD TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_READER_DEV TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_READER_QA TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_READER_PRD TO ROLE SYSADMIN;

-- =============================================================================
-- 02 - Warehouses by workload, with a monthly credit budget
-- =============================================================================
CREATE WAREHOUSE IF NOT EXISTS PIPELINE_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 600
    COMMENT = 'Deployments and scheduled pipeline runs';

CREATE WAREHOUSE IF NOT EXISTS REPORTING_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 300
    COMMENT = 'Dashboards and ad hoc reads';

-- Notify at 75%, stop both warehouses at 100% of 10 credits per month.
CREATE RESOURCE MONITOR IF NOT EXISTS ANALYTICS_MONTHLY_BUDGET
    WITH CREDIT_QUOTA = 10
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE PIPELINE_WH SET RESOURCE_MONITOR = ANALYTICS_MONTHLY_BUDGET;
ALTER WAREHOUSE REPORTING_WH SET RESOURCE_MONITOR = ANALYTICS_MONTHLY_BUDGET;

GRANT USAGE ON WAREHOUSE PIPELINE_WH TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON WAREHOUSE PIPELINE_WH TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON WAREHOUSE PIPELINE_WH TO ROLE ANALYTICS_DEPLOY_PRD;
-- The dashboard owner (deploy role) and its viewers both need the reporting warehouse.
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE ANALYTICS_DEPLOY_PRD;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE ANALYTICS_READER_DEV;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE ANALYTICS_READER_QA;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE ANALYTICS_READER_PRD;

-- =============================================================================
-- 03 - One database per environment, owned by that environment's deploy role
-- =============================================================================
-- Each deploy role can only change its own database. A DEV deployment
-- cannot touch PROD even if someone passes the wrong environment name.
CREATE DATABASE IF NOT EXISTS ANALYTICS_DEV COMMENT = 'native-cicd-demo';
CREATE DATABASE IF NOT EXISTS ANALYTICS_QA COMMENT = 'native-cicd-demo';
CREATE DATABASE IF NOT EXISTS ANALYTICS_PRD COMMENT = 'native-cicd-demo';

GRANT OWNERSHIP ON DATABASE ANALYTICS_DEV TO ROLE ANALYTICS_DEPLOY_DEV COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE ANALYTICS_QA TO ROLE ANALYTICS_DEPLOY_QA COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE ANALYTICS_PRD TO ROLE ANALYTICS_DEPLOY_PRD COPY CURRENT GRANTS;

GRANT EXECUTE TASK ON ACCOUNT TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ANALYTICS_DEPLOY_QA;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ANALYTICS_DEPLOY_PRD;

-- =============================================================================
-- 04 - Synthetic source: stands in for an Amplitude connector
-- =============================================================================
CREATE DATABASE IF NOT EXISTS LANDING COMMENT = 'native-cicd-demo: simulated ingestion';
CREATE SCHEMA IF NOT EXISTS LANDING.AMPLITUDE;
CREATE TABLE IF NOT EXISTS LANDING.AMPLITUDE.EVENTS (
    EVENT_ID VARCHAR,
    USER_ID VARCHAR,
    EVENT_TIME TIMESTAMP_NTZ,
    EVENT_TYPE VARCHAR,
    CONTENT_AREA VARCHAR,
    PLATFORM VARCHAR,
    USER_TYPE VARCHAR
);

-- Inserts only into an empty table, so rerunning setup never duplicates rows.
-- The rows include one duplicate delivery (e2), one missing user (e6),
-- untidy content-area names and two internal staff accounts (u4, u5).
INSERT INTO LANDING.AMPLITUDE.EVENTS
SELECT * FROM VALUES
-- SEED START
    ('e1', 'u1', '2026-09-21 09:00:00', 'page_view', ' Parents ', 'web', 'visitor'),
    ('e2', 'u2', '2026-09-21 10:30:00', 'page_view', 'parents', 'app', 'member'),
    ('e2', 'u2', '2026-09-21 10:30:00', 'page_view', 'parents', 'app', 'member'),
    ('e3', 'u3', '2026-09-22 08:15:00', 'page_view', 'Educators', 'web', 'visitor'),
    ('e4', 'u4', '2026-09-22 12:00:00', 'page_view', 'parents', 'web', 'internal'),
    ('e5', 'u5', '2026-09-23 14:45:00', 'page_view', 'educators', 'web', 'internal'),
    ('e6', NULL, '2026-09-23 16:00:00', 'page_view', 'parents', 'web', 'visitor'),
    ('e7', 'u1', '2026-09-24 19:20:00', 'page_view', 'parents', 'app', 'visitor')
-- SEED END
WHERE NOT EXISTS (SELECT 1 FROM LANDING.AMPLITUDE.EVENTS);

GRANT USAGE ON DATABASE LANDING TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON DATABASE LANDING TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON DATABASE LANDING TO ROLE ANALYTICS_DEPLOY_PRD;
GRANT USAGE ON SCHEMA LANDING.AMPLITUDE TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON SCHEMA LANDING.AMPLITUDE TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON SCHEMA LANDING.AMPLITUDE TO ROLE ANALYTICS_DEPLOY_PRD;
GRANT SELECT ON TABLE LANDING.AMPLITUDE.EVENTS TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT SELECT ON TABLE LANDING.AMPLITUDE.EVENTS TO ROLE ANALYTICS_DEPLOY_QA;
GRANT SELECT ON TABLE LANDING.AMPLITUDE.EVENTS TO ROLE ANALYTICS_DEPLOY_PRD;

-- =============================================================================
-- 05 - Git connection: Snowflake reads deployment SQL straight from GitHub
-- =============================================================================
CREATE DATABASE IF NOT EXISTS PLATFORM COMMENT = 'native-cicd-demo: shared platform objects';
CREATE SCHEMA IF NOT EXISTS PLATFORM.GIT;

-- PRIVATE REPOSITORY ONLY: create a read-only GitHub token (Contents: read),
-- then run this statement in a Snowsight worksheet. Never commit the token.
-- CREATE SECRET IF NOT EXISTS PLATFORM.GIT.GITHUB_TOKEN
--     TYPE = PASSWORD
--     USERNAME = '<github-user>'
--     PASSWORD = '<read-only token>';

CREATE API INTEGRATION IF NOT EXISTS ANALYTICS_GIT_API
    API_PROVIDER = GIT_HTTPS_API
    API_ALLOWED_PREFIXES = ('https://github.com/<your-org>/')
    -- PRIVATE REPOSITORY ONLY: ALLOWED_AUTHENTICATION_SECRETS = (PLATFORM.GIT.GITHUB_TOKEN)
    ENABLED = TRUE;

CREATE GIT REPOSITORY IF NOT EXISTS PLATFORM.GIT.ANALYTICS_REPO
    API_INTEGRATION = ANALYTICS_GIT_API
    -- PRIVATE REPOSITORY ONLY: GIT_CREDENTIALS = PLATFORM.GIT.GITHUB_TOKEN
    ORIGIN = 'https://github.com/<your-org>/<your-repo>.git';

GRANT USAGE ON DATABASE PLATFORM TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON DATABASE PLATFORM TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON DATABASE PLATFORM TO ROLE ANALYTICS_DEPLOY_PRD;
GRANT USAGE ON SCHEMA PLATFORM.GIT TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON SCHEMA PLATFORM.GIT TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON SCHEMA PLATFORM.GIT TO ROLE ANALYTICS_DEPLOY_PRD;
-- READ runs files from the repository; WRITE allows FETCH of new commits.
GRANT READ, WRITE ON GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT READ, WRITE ON GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO TO ROLE ANALYTICS_DEPLOY_QA;
GRANT READ, WRITE ON GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO TO ROLE ANALYTICS_DEPLOY_PRD;

-- =============================================================================
-- 06 - CI service users: GitHub Actions signs in with OIDC, no passwords or keys
-- =============================================================================
-- Each SUBJECT is tied to one GitHub environment (dev, qa, prod). Find the IDs with:
--   gh api repos/<your-org>/<your-repo> --jq '"owner id: \(.owner.id)  repo id: \(.id)"'
CREATE USER IF NOT EXISTS ANALYTICS_CI_DEV
    TYPE = SERVICE
    DEFAULT_ROLE = ANALYTICS_DEPLOY_DEV
    DEFAULT_SECONDARY_ROLES = ()
    DEFAULT_WAREHOUSE = PIPELINE_WH
    WORKLOAD_IDENTITY = (
        TYPE = OIDC
        ISSUER = 'https://token.actions.githubusercontent.com'
        SUBJECT = 'repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:dev'
    );
GRANT ROLE ANALYTICS_DEPLOY_DEV TO USER ANALYTICS_CI_DEV;

CREATE USER IF NOT EXISTS ANALYTICS_CI_QA
    TYPE = SERVICE
    DEFAULT_ROLE = ANALYTICS_DEPLOY_QA
    DEFAULT_SECONDARY_ROLES = ()
    DEFAULT_WAREHOUSE = PIPELINE_WH
    WORKLOAD_IDENTITY = (
        TYPE = OIDC
        ISSUER = 'https://token.actions.githubusercontent.com'
        SUBJECT = 'repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:qa'
    );
GRANT ROLE ANALYTICS_DEPLOY_QA TO USER ANALYTICS_CI_QA;

CREATE USER IF NOT EXISTS ANALYTICS_CI_PRD
    TYPE = SERVICE
    DEFAULT_ROLE = ANALYTICS_DEPLOY_PRD
    DEFAULT_SECONDARY_ROLES = ()
    DEFAULT_WAREHOUSE = PIPELINE_WH
    WORKLOAD_IDENTITY = (
        TYPE = OIDC
        ISSUER = 'https://token.actions.githubusercontent.com'
        SUBJECT = 'repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:prod'
    );
GRANT ROLE ANALYTICS_DEPLOY_PRD TO USER ANALYTICS_CI_PRD;

-- =============================================================================
-- 07 - Verify
-- =============================================================================
SHOW DATABASES LIKE 'ANALYTICS_%';
SHOW ROLES LIKE 'ANALYTICS_%';
SHOW USERS LIKE 'ANALYTICS_CI_%';
SHOW WAREHOUSES LIKE '%_WH';
SHOW RESOURCE MONITORS LIKE 'ANALYTICS_MONTHLY_BUDGET';
ALTER GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO FETCH;
SHOW GIT BRANCHES IN PLATFORM.GIT.ANALYTICS_REPO;

-- Expected: 8 source rows.
SELECT COUNT(*) AS SOURCE_ROWS FROM LANDING.AMPLITUDE.EVENTS;

-- =============================================================================
-- 08 - OPTIONAL: edit and commit from Snowsight Workspaces
-- =============================================================================
-- Lets less technical teammates change SQL in Snowsight and open the normal
-- GitHub pull request, without a local Git setup. Uncomment to use.
--
-- CREATE API INTEGRATION IF NOT EXISTS ANALYTICS_WORKSPACE_API
--     API_PROVIDER = GIT_HTTPS_API
--     API_ALLOWED_PREFIXES = ('https://github.com/<your-org>/<your-repo>.git')
--     API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
--     ENABLED = TRUE;
-- GRANT USAGE ON INTEGRATION ANALYTICS_WORKSPACE_API TO ROLE SYSADMIN;
--
-- Then in Snowsight: Projects > Workspaces > From Git repository.
-- https://docs.snowflake.com/en/user-guide/ui-snowsight/workspaces-git
