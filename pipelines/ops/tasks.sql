--!jinja
-- One task graph runs the whole cascade: Bronze, then Silver, then Gold.
-- Recreating the root removes its child links, so the children are recreated right after it.
CREATE OR REPLACE TASK OPS.PIPELINE_ROOT
    WAREHOUSE = PIPELINE_WH
    SCHEDULE = 'USING CRON 0 6 * * * America/Los_Angeles'
    USER_TASK_TIMEOUT_MS = 600000
AS
    CALL BRONZE.LOAD_AMPLITUDE_EVENTS();

CREATE OR REPLACE TASK OPS.BUILD_SILVER
    WAREHOUSE = PIPELINE_WH
    AFTER OPS.PIPELINE_ROOT
AS
    CALL SILVER.BUILD_EVENTS();

CREATE OR REPLACE TASK OPS.BUILD_GOLD
    WAREHOUSE = PIPELINE_WH
    AFTER OPS.BUILD_SILVER
AS
    CALL GOLD.BUILD_WEEKLY_ACTIVE_USERS();

-- Child tasks must be resumed or the graph skips them.
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ANALYTICS_{{ env }}.OPS.PIPELINE_ROOT');

{% if env != 'PRD' %}
-- Only PROD runs on the schedule; DEV and QA run when CI triggers them.
ALTER TASK OPS.PIPELINE_ROOT SUSPEND;
{% endif %}
