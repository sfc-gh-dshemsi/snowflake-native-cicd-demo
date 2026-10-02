import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()
database = session.get_current_database()

st.title("Weekly active users by content area")
st.caption(f"Environment database: {database}")

users = session.sql(
    "SELECT WEEK_START, CONTENT_AREA, ACTIVE_USERS, RULES_VERSION, REFRESHED_AT "
    "FROM GOLD.WEEKLY_ACTIVE_USERS ORDER BY WEEK_START DESC, CONTENT_AREA"
).to_pandas()

if users.empty:
    st.info("Gold is empty. Run the task graph or check the latest deployment.")
else:
    latest = users[users["WEEK_START"] == users["WEEK_START"].max()]
    columns = st.columns(len(latest))
    for column, row in zip(columns, latest.itertuples()):
        column.metric(row.CONTENT_AREA.title(), int(row.ACTIVE_USERS))
    st.bar_chart(latest, x="CONTENT_AREA", y="ACTIVE_USERS")
    st.caption(f"Business rules: {latest['RULES_VERSION'].iloc[0]} | refreshed {latest['REFRESHED_AT'].max()}")

st.subheader("Recent deployments")
st.dataframe(
    session.sql(
        "SELECT ENVIRONMENT, LEFT(COMMIT_SHA, 7) AS COMMIT, DEPLOYED_BY, DEPLOYED_AT "
        "FROM OPS.DEPLOY_LOG ORDER BY DEPLOYED_AT DESC LIMIT 10"
    ).to_pandas(),
    hide_index=True,
)
