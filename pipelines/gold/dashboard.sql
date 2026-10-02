--!jinja
-- The app is built from the same commit as the SQL, so dashboard code and data logic cannot drift.
CREATE OR REPLACE STREAMLIT GOLD.ENGAGEMENT_DASHBOARD
    FROM '@PLATFORM.GIT.ANALYTICS_REPO/commits/{{ commit_sha }}/streamlit'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = REPORTING_WH
    TITLE = 'Weekly active users ({{ env }})';
