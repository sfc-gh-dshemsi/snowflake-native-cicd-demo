-- =============================================================================
-- NATIVE SQL CI/CD DEMO - ONE-TIME SETUP
-- =============================================================================
-- Create prerequisites in the demo account before the first CI/CD release.
-- Creation statements can be rerun; section 07 remains a one-time seed.
-- The file intentionally uses direct SQL so every creation step is visible.
--
-- Before running:
--   1. Replace every <your-org>, <your-org-id>, <your-repo> and <your-repo-id>
--      below with your GitHub owner, repository and their numeric IDs.
--   2. For a private repository, uncomment the three PRIVATE REPOSITORY ONLY
--      blocks in section 05.
--   3. Select the intended demo account, matching your SNOWFLAKE_ACCOUNT secret.
--   4. Run sections 00-08 in order as a user who holds ACCOUNTADMIN.
--      Section 09 is optional.
--
-- Each section uses the least powerful system role that can do the work:
--   USERADMIN     creates roles and users
--   SYSADMIN      creates warehouses, databases and the Git repository object
--   SECURITYADMIN grants privileges
--   ACCOUNTADMIN  only for what requires it: resource monitors, integrations
--                 and the account-level EXECUTE TASK privilege
--
-- This is setup, not the application release. Tables, procedures, the task
-- graph, reader grants and the dashboard are installed later from Git by
-- pipelines/deploy.sql. In production, Terraform or an admin runbook owns this.
-- IF NOT EXISTS keeps existing objects; it does not update their configuration.
-- Review existing user OIDC settings and object definitions if they differ.
-- Never add a password or token to this file.
-- =============================================================================

-- =============================================================================
-- 00 - Confirm the setup user
-- =============================================================================
-- The user running this file needs ACCOUNTADMIN, which inherits every role below.
-- No CI identity ever receives ACCOUNTADMIN, SECURITYADMIN or SYSADMIN.
USE ROLE ACCOUNTADMIN;
SELECT CURRENT_USER() AS SETUP_USER, CURRENT_ACCOUNT_NAME() AS ACCOUNT_NAME;

-- =============================================================================
-- 01 - Deployment and reader roles
-- =============================================================================
-- Each environment has one deploy role (owns its database, used only by CI) and
-- one reader role (sees Gold and the dashboard only). All of them roll up to
-- SYSADMIN so administrators can still manage every object.
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS ANALYTICS_DEPLOY_DEV
    COMMENT = 'native-sql-cicd-demo-v1: CI deploys DEV';
CREATE ROLE IF NOT EXISTS ANALYTICS_DEPLOY_QA
    COMMENT = 'native-sql-cicd-demo-v1: CI deploys QA';
CREATE ROLE IF NOT EXISTS ANALYTICS_DEPLOY_PRD
    COMMENT = 'native-sql-cicd-demo-v1: CI deploys PROD';
CREATE ROLE IF NOT EXISTS ANALYTICS_READER_DEV
    COMMENT = 'native-sql-cicd-demo-v1: read DEV Gold and dashboard';
CREATE ROLE IF NOT EXISTS ANALYTICS_READER_QA
    COMMENT = 'native-sql-cicd-demo-v1: read QA Gold and dashboard';
CREATE ROLE IF NOT EXISTS ANALYTICS_READER_PRD
    COMMENT = 'native-sql-cicd-demo-v1: read PROD Gold and dashboard';

GRANT ROLE ANALYTICS_DEPLOY_DEV TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_DEPLOY_QA TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_DEPLOY_PRD TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_READER_DEV TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_READER_QA TO ROLE SYSADMIN;
GRANT ROLE ANALYTICS_READER_PRD TO ROLE SYSADMIN;

-- =============================================================================
-- 02 - Warehouses, databases and source table
-- =============================================================================
USE ROLE SYSADMIN;

-- Separate warehouses by workload so pipeline and dashboard costs stay visible.
-- Extra small, suspend after 60 idle seconds, and cap how long a statement can
-- run or wait in the queue.
CREATE WAREHOUSE IF NOT EXISTS PIPELINE_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 600
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 300
    COMMENT = 'native-sql-cicd-demo-v1: deployments and scheduled pipeline runs';
CREATE WAREHOUSE IF NOT EXISTS REPORTING_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 300
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 120
    COMMENT = 'native-sql-cicd-demo-v1: dashboards and ad hoc reads';

-- One database per environment. Schemas and objects inside them come from Git.
CREATE DATABASE IF NOT EXISTS ANALYTICS_DEV
    COMMENT = 'native-sql-cicd-demo-v1';
CREATE DATABASE IF NOT EXISTS ANALYTICS_QA
    COMMENT = 'native-sql-cicd-demo-v1';
CREATE DATABASE IF NOT EXISTS ANALYTICS_PRD
    COMMENT = 'native-sql-cicd-demo-v1';

-- Shared platform objects: the Git repository connection.
CREATE DATABASE IF NOT EXISTS PLATFORM
    COMMENT = 'native-sql-cicd-demo-v1';
CREATE SCHEMA IF NOT EXISTS PLATFORM.GIT WITH MANAGED ACCESS
    COMMENT = 'native-sql-cicd-demo-v1';

-- Shared source, standing in for an Amplitude connector. Read-only to CI.
CREATE DATABASE IF NOT EXISTS LANDING
    COMMENT = 'native-sql-cicd-demo-v1';
CREATE SCHEMA IF NOT EXISTS LANDING.AMPLITUDE WITH MANAGED ACCESS
    COMMENT = 'native-sql-cicd-demo-v1';
CREATE TABLE IF NOT EXISTS LANDING.AMPLITUDE.EVENTS (
    EVENT_ID VARCHAR, USER_ID VARCHAR, EVENT_TIME TIMESTAMP_NTZ, EVENT_TYPE VARCHAR,
    CONTENT_AREA VARCHAR, PLATFORM VARCHAR, USER_TYPE VARCHAR
) COMMENT = 'native-sql-cicd-demo-v1: simulated Amplitude connector output';

-- =============================================================================
-- 03 - Account-level settings that require ACCOUNTADMIN
-- =============================================================================
USE ROLE ACCOUNTADMIN;

-- Notify at 75%, suspend both warehouses at 100% of 10 credits per month.
-- Notifications go to account administrators who have enabled them in Snowsight.
CREATE RESOURCE MONITOR IF NOT EXISTS ANALYTICS_MONTHLY_BUDGET
    WITH CREDIT_QUOTA = 10
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE PIPELINE_WH SET RESOURCE_MONITOR = ANALYTICS_MONTHLY_BUDGET;
ALTER WAREHOUSE REPORTING_WH SET RESOURCE_MONITOR = ANALYTICS_MONTHLY_BUDGET;

-- Task owners need EXECUTE TASK for their tasks to run; only ACCOUNTADMIN can grant it.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ANALYTICS_DEPLOY_QA;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ANALYTICS_DEPLOY_PRD;

-- =============================================================================
-- 04 - Grants
-- =============================================================================
USE ROLE SECURITYADMIN;

-- Each deploy role owns only its own database, so a DEV deployment cannot
-- change QA or PROD even if it is given the wrong environment name.
GRANT OWNERSHIP ON DATABASE ANALYTICS_DEV TO ROLE ANALYTICS_DEPLOY_DEV COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE ANALYTICS_QA TO ROLE ANALYTICS_DEPLOY_QA COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE ANALYTICS_PRD TO ROLE ANALYTICS_DEPLOY_PRD COPY CURRENT GRANTS;

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

-- LANDING is read-only to all deployment identities. Nothing in CI changes shared input.
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
-- Public repository: run as is.
-- Private repository: uncomment the three PRIVATE REPOSITORY ONLY blocks.
-- Create a fine-grained GitHub token limited to this repository with
-- Contents = Read-only and an expiry date. Paste it into the Snowsight
-- worksheet only, never into this file. Rotate it before it expires with:
--   ALTER SECRET PLATFORM.GIT.GITHUB_TOKEN SET PASSWORD = '<new token>';

-- PRIVATE REPOSITORY ONLY (1 of 3):
-- USE ROLE SYSADMIN;
-- CREATE SECRET IF NOT EXISTS PLATFORM.GIT.GITHUB_TOKEN
--     TYPE = PASSWORD
--     USERNAME = '<github-user>'
--     PASSWORD = '<read-only token>'
--     COMMENT = 'native-sql-cicd-demo-v1: read-only access to <your-repo>';

-- Creating an integration requires ACCOUNTADMIN. The allowed prefix is this one
-- repository, not the whole organization.
USE ROLE ACCOUNTADMIN;
CREATE API INTEGRATION IF NOT EXISTS ANALYTICS_GIT_API
    API_PROVIDER = GIT_HTTPS_API
    API_ALLOWED_PREFIXES = (
        'https://github.com/<your-org>/<your-repo>'
    )
    -- PRIVATE REPOSITORY ONLY (2 of 3):
    -- ALLOWED_AUTHENTICATION_SECRETS = (PLATFORM.GIT.GITHUB_TOKEN)
    ENABLED = TRUE
    COMMENT = 'native-sql-cicd-demo-v1: deployment source';
GRANT USAGE ON INTEGRATION ANALYTICS_GIT_API TO ROLE SYSADMIN;

USE ROLE SYSADMIN;
CREATE GIT REPOSITORY IF NOT EXISTS PLATFORM.GIT.ANALYTICS_REPO
    API_INTEGRATION = ANALYTICS_GIT_API
    -- PRIVATE REPOSITORY ONLY (3 of 3):
    -- GIT_CREDENTIALS = PLATFORM.GIT.GITHUB_TOKEN
    ORIGIN = 'https://github.com/<your-org>/<your-repo>.git'
    COMMENT = 'native-sql-cicd-demo-v1';

USE ROLE SECURITYADMIN;
GRANT USAGE ON DATABASE PLATFORM TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON DATABASE PLATFORM TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON DATABASE PLATFORM TO ROLE ANALYTICS_DEPLOY_PRD;
GRANT USAGE ON SCHEMA PLATFORM.GIT TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT USAGE ON SCHEMA PLATFORM.GIT TO ROLE ANALYTICS_DEPLOY_QA;
GRANT USAGE ON SCHEMA PLATFORM.GIT TO ROLE ANALYTICS_DEPLOY_PRD;

-- READ runs files from the repository; WRITE allows FETCH of new commits.
-- Neither lets Snowflake push to GitHub: the token is read-only.
GRANT READ, WRITE ON GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO TO ROLE ANALYTICS_DEPLOY_DEV;
GRANT READ, WRITE ON GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO TO ROLE ANALYTICS_DEPLOY_QA;
GRANT READ, WRITE ON GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO TO ROLE ANALYTICS_DEPLOY_PRD;

-- =============================================================================
-- 06 - GitHub Actions OIDC service users
-- =============================================================================
-- Service users have no password and cannot sign in to Snowsight. Each one
-- trusts a single GitHub environment and has a single role, with no secondary
-- roles, so a token issued for DEV can never act in QA or PROD.
-- The SUBJECT values must match the GitHub environments used by the workflow.
-- Obtain the immutable prefix from GitHub's Actions OIDC settings/API:
--   repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:dev
--   repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:qa
--   repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:prod
-- Find the numeric IDs with:
--   gh api repos/<your-org>/<your-repo> --jq '"owner id: \(.owner.id)  repo id: \(.id)"'
-- Reference:
-- https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS ANALYTICS_CI_DEV
    TYPE = SERVICE
    DEFAULT_ROLE = ANALYTICS_DEPLOY_DEV
    DEFAULT_SECONDARY_ROLES = ()
    DEFAULT_WAREHOUSE = PIPELINE_WH
    COMMENT = 'native-sql-cicd-demo-v1: GitHub environment dev'
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
    COMMENT = 'native-sql-cicd-demo-v1: GitHub environment qa'
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
    COMMENT = 'native-sql-cicd-demo-v1: GitHub environment prod'
    WORKLOAD_IDENTITY = (
        TYPE = OIDC
        ISSUER = 'https://token.actions.githubusercontent.com'
        SUBJECT = 'repo:<your-org>@<your-org-id>/<your-repo>@<your-repo-id>:environment:prod'
    );
GRANT ROLE ANALYTICS_DEPLOY_PRD TO USER ANALYTICS_CI_PRD;

-- =============================================================================
-- 07 - Synthetic shared LANDING source (not part of releases)
-- =============================================================================
-- Run once. LANDING must be empty. This is not release logic.
-- The rows include one duplicate delivery (e2), one missing user (e6),
-- untidy content-area names and two internal staff accounts (u4, u5).
USE ROLE SYSADMIN;
USE WAREHOUSE PIPELINE_WH;

SELECT 'LANDING_BEFORE_INSERT' AS CHECK_NAME, COUNT(*) AS ROW_COUNT
FROM LANDING.AMPLITUDE.EVENTS;

-- STOP unless the count is zero.
-- On a rerun with existing LANDING rows, skip the entire transaction below and go to 08.

BEGIN TRANSACTION;

INSERT INTO LANDING.AMPLITUDE.EVENTS
    (EVENT_ID, USER_ID, EVENT_TIME, EVENT_TYPE, CONTENT_AREA, PLATFORM, USER_TYPE)
VALUES
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
;

COMMIT;

-- =============================================================================
-- 08 - Verify the setup
-- =============================================================================
USE ROLE SECURITYADMIN;

SHOW ROLES LIKE 'ANALYTICS_%';
SHOW USERS LIKE 'ANALYTICS_CI_%';
SHOW GRANTS TO ROLE ANALYTICS_DEPLOY_DEV;
SHOW GRANTS TO ROLE ANALYTICS_DEPLOY_QA;
SHOW GRANTS TO ROLE ANALYTICS_DEPLOY_PRD;
SHOW GRANTS ON DATABASE LANDING;

USE ROLE SYSADMIN;
USE WAREHOUSE PIPELINE_WH;

SHOW DATABASES LIKE 'ANALYTICS_%';
SHOW WAREHOUSES LIKE '%_WH';

ALTER GIT REPOSITORY PLATFORM.GIT.ANALYTICS_REPO FETCH;
SHOW GIT BRANCHES IN PLATFORM.GIT.ANALYTICS_REPO;

SELECT 'LANDING' AS TIER, COUNT(*) AS ROW_COUNT, COUNT(DISTINCT EVENT_ID) AS DISTINCT_EVENTS
FROM LANDING.AMPLITUDE.EVENTS;

SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS SNOWFLAKE_ACCOUNT;

USE ROLE ACCOUNTADMIN;
SHOW RESOURCE MONITORS LIKE 'ANALYTICS_MONTHLY_BUDGET';

-- Expected setup verification:
--   Databases ANALYTICS_DEV, ANALYTICS_QA, ANALYTICS_PRD, each owned by its deploy role
--   Users ANALYTICS_CI_DEV, ANALYTICS_CI_QA, ANALYTICS_CI_PRD, all TYPE = SERVICE
--   Deploy roles: SELECT on LANDING, READ/WRITE on the Git repository, no other databases
--   Git branches include main
--   LANDING = 8 rows / 7 distinct events
--   SNOWFLAKE_ACCOUNT = the value for the GitHub secret of the same name
-- The first release later produces week 2026-09-21 in QA and PRD:
--   parents 3 / educators 2 / v1

-- =============================================================================
-- 09 - OPTIONAL: edit pipelines from Snowsight Workspaces with Git
-- =============================================================================
-- For teammates who prefer Snowsight to a local Git setup. They edit the same
-- files (for example pipelines/silver/events.sql and checks/pipeline_checks.sql),
-- commit to a feature branch and open the normal pull request. The pull request
-- then deploys to DEV through CI. Workspaces never deploys anything itself, and
-- the developer role can read DEV results but cannot change any environment.
--
-- This uses a separate integration from section 05: each person signs in to
-- GitHub with their own account (OAuth), so commits show who made them and no
-- shared token is involved. Uncomment the SQL below, replace <teammate-user>,
-- then run only this section.
--
-- USE ROLE ACCOUNTADMIN;
-- CREATE API INTEGRATION IF NOT EXISTS ANALYTICS_WORKSPACE_API
--     API_PROVIDER = GIT_HTTPS_API
--     API_ALLOWED_PREFIXES = (
--         'https://github.com/<your-org>/<your-repo>'
--     )
--     API_USER_AUTHENTICATION = (
--         TYPE = SNOWFLAKE_GITHUB_APP
--     )
--     ENABLED = TRUE
--     COMMENT = 'native-sql-cicd-demo-v1: optional Workspaces authoring';
--
-- USE ROLE USERADMIN;
-- CREATE ROLE IF NOT EXISTS ANALYTICS_DEVELOPER
--     COMMENT = 'native-sql-cicd-demo-v1: edit in Workspaces, read DEV results';
-- GRANT ROLE ANALYTICS_READER_DEV TO ROLE ANALYTICS_DEVELOPER;
-- GRANT ROLE ANALYTICS_DEVELOPER TO ROLE SYSADMIN;
-- GRANT ROLE ANALYTICS_DEVELOPER TO USER <teammate-user>;
--
-- USE ROLE SECURITYADMIN;
-- GRANT USAGE ON INTEGRATION ANALYTICS_WORKSPACE_API TO ROLE ANALYTICS_DEVELOPER;
--
-- Then in Snowsight, as the teammate:
--   1. Switch to the ANALYTICS_DEVELOPER role.
--   2. Projects > Workspaces > From Git repository.
--   3. Enter https://github.com/<your-org>/<your-repo>.git
--   4. Select ANALYTICS_WORKSPACE_API and OAuth2 > Sign in.
--   5. Authorize access to this repository.
--   6. Create a branch such as feature/exclude-internal-traffic, edit the rule
--      and its expected numbers, then commit and push.
--   7. Open the pull request in GitHub. CI deploys it to DEV and runs the checks.
--   8. Review the result in ANALYTICS_DEV.GOLD.WEEKLY_ACTIVE_USERS or the
--      DEV dashboard.
-- Reference:
-- https://docs.snowflake.com/en/user-guide/ui-snowsight/workspaces-git
