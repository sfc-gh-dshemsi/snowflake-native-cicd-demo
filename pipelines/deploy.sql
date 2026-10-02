--!jinja
-- The only deployment entry point. CI runs it from the exact commit being released:
--   EXECUTE IMMEDIATE FROM @PLATFORM.GIT.ANALYTICS_REPO/commits/<sha>/pipelines/deploy.sql
--     USING (env => 'DEV' | 'QA' | 'PRD', commit_sha => '<sha>', actor => '<github user>');
-- Every file is safe to rerun: deploying the same commit twice changes nothing.
-- The order below is the dependency order; add new files here, never run them by hand.

USE DATABASE ANALYTICS_{{ env }};
ALTER SESSION SET QUERY_TAG = 'deploy:{{ env }}:{{ commit_sha }}';

CREATE SCHEMA IF NOT EXISTS BRONZE;
CREATE SCHEMA IF NOT EXISTS SILVER;
CREATE SCHEMA IF NOT EXISTS GOLD;
CREATE SCHEMA IF NOT EXISTS OPS;

-- Child tasks cannot be changed while their root task is running on a schedule.
ALTER TASK IF EXISTS OPS.PIPELINE_ROOT SUSPEND;

EXECUTE IMMEDIATE FROM './ops/deploy_log.sql';
EXECUTE IMMEDIATE FROM './bronze/amplitude_events.sql';
EXECUTE IMMEDIATE FROM './silver/events.sql';
EXECUTE IMMEDIATE FROM './gold/weekly_active_users.sql';
EXECUTE IMMEDIATE FROM './ops/tasks.sql' USING (env => '{{ env }}');
EXECUTE IMMEDIATE FROM './gold/dashboard.sql' USING (env => '{{ env }}', commit_sha => '{{ commit_sha }}');
EXECUTE IMMEDIATE FROM './ops/grants.sql' USING (env => '{{ env }}');

INSERT INTO OPS.DEPLOY_LOG (ENVIRONMENT, COMMIT_SHA, DEPLOYED_BY)
VALUES ('{{ env }}', '{{ commit_sha }}', '{{ actor }}');
