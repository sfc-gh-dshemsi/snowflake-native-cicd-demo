--!jinja
-- Runs after every deployment and task graph run. Each returned row is a failed check;
-- CI passes only when this returns no rows.
-- Expected numbers come from the synthetic source in setup/setup.sql. When a business rule
-- changes, update them in the same pull request as the rule.
WITH expected AS (
    SELECT $1 AS CONTENT_AREA, $2 AS ACTIVE_USERS FROM VALUES ('educators', 1), ('parents', 2)
),
actual AS (
    SELECT CONTENT_AREA, ACTIVE_USERS
    FROM ANALYTICS_{{ env }}.GOLD.WEEKLY_ACTIVE_USERS
    WHERE WEEK_START = '2026-09-21'::DATE
)
SELECT 'weekly active users' AS CHECK_NAME,
       COALESCE(e.CONTENT_AREA, a.CONTENT_AREA) AS DETAIL,
       e.ACTIVE_USERS::VARCHAR AS EXPECTED,
       a.ACTIVE_USERS::VARCHAR AS ACTUAL
FROM expected e
FULL OUTER JOIN actual a ON e.CONTENT_AREA = a.CONTENT_AREA
WHERE e.ACTIVE_USERS IS DISTINCT FROM a.ACTIVE_USERS

UNION ALL
SELECT 'gold rules version', NULL, 'v2', MAX(RULES_VERSION)
FROM ANALYTICS_{{ env }}.GOLD.WEEKLY_ACTIVE_USERS
HAVING MAX(RULES_VERSION) IS DISTINCT FROM 'v2'

UNION ALL
SELECT 'silver has one row per event', NULL, '0', (COUNT(*) - COUNT(DISTINCT EVENT_ID))::VARCHAR
FROM ANALYTICS_{{ env }}.SILVER.EVENTS
HAVING COUNT(*) <> COUNT(DISTINCT EVENT_ID)

UNION ALL
SELECT 'bronze matches the source', NULL, s.ROWS_IN_SOURCE::VARCHAR, b.ROWS_IN_BRONZE::VARCHAR
FROM (SELECT COUNT(*) AS ROWS_IN_SOURCE FROM LANDING.AMPLITUDE.EVENTS) s,
     (SELECT COUNT(*) AS ROWS_IN_BRONZE FROM ANALYTICS_{{ env }}.BRONZE.AMPLITUDE_EVENTS) b
WHERE s.ROWS_IN_SOURCE <> b.ROWS_IN_BRONZE

UNION ALL
SELECT 'deploy log records this commit', NULL, '{{ commit_sha }}', MAX_BY(COMMIT_SHA, DEPLOYED_AT)
FROM ANALYTICS_{{ env }}.OPS.DEPLOY_LOG
HAVING MAX_BY(COMMIT_SHA, DEPLOYED_AT) IS DISTINCT FROM '{{ commit_sha }}';
