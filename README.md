# Native Snowflake CI/CD demo

Git for version control, Snowflake for everything else. GitHub Actions only decides **when** to deploy. Snowflake pulls the SQL from Git and runs it.

```text
Pull request    -> DEV   (deploy, run the pipeline once, check the numbers)
Merge to main   -> QA    (same steps, on the merged commit)
Approve         -> PROD  (same commit, same steps, schedule switched on)
```

It covers three goals:

| Goal | How |
|---|---|
| Version control of pipelines, transformations and schemas | Every table, procedure, task, grant and the dashboard is a file in `pipelines/` or `streamlit/`. |
| Auditability | Each environment records commit, time and person in `OPS.DEPLOY_LOG`, and every deployment statement is tagged `deploy:<env>:<commit>`. |
| No manual deployment | Nobody runs SQL in QA or PROD by hand. The workflow runs one entry point, `pipelines/deploy.sql`. |

## The one idea that keeps changes calm: deploying is not running

- **Deploying** changes definitions: tables, procedures, tasks and grants. CI does it once per change.
- **Running** moves data. The task graph does it, on its schedule in PROD.

After a deployment, CI runs the task graph **once** and checks the result. A merge never triggers an open-ended rebuild of the whole database. If a run fails, the definitions are still correct and the next scheduled run retries.

```text
OPS.PIPELINE_ROOT   (cron in PROD, manual in DEV/QA)  -> CALL BRONZE.LOAD_AMPLITUDE_EVENTS()
  └─ OPS.BUILD_SILVER                                   -> CALL SILVER.BUILD_EVENTS()
       └─ OPS.BUILD_GOLD                                -> CALL GOLD.BUILD_WEEKLY_ACTIVE_USERS()
```

## Repository layout

```text
pipelines/
├── deploy.sql                  # the only entry point; lists every file in dependency order
├── bronze/amplitude_events.sql # raw events as delivered
├── silver/events.sql           # cleaning and business rules
├── gold/weekly_active_users.sql
├── gold/dashboard.sql          # Streamlit app, built from the same commit
└── ops/                        # deploy log, task graph, grants
streamlit/streamlit_app.py
checks/pipeline_checks.sql      # runs after every deployment; any returned row fails CI
ci/deploy.sh                    # fetch, deploy, run the graph once, run checks
.github/workflows/deploy.yml    # PR -> DEV; main -> QA -> PROD
setup/setup.sql                 # one-time account setup (roles, warehouses, Git connection)
sql/audit.sql                   # who deployed what, task runs, cost
tests/test_repo.py              # offline checks that run before anything touches Snowflake
```

There is **one copy of the SQL**. Files never name an environment database. `deploy.sql` receives `env` (DEV, QA or PRD) and selects `ANALYTICS_<env>`. Each environment has its own deploy role that owns only its own database, so a DEV deployment cannot change PROD.

## How a change is made

A normal change touches two files in one pull request:

1. **The rule:** edit the definition in place, for example `pipelines/silver/events.sql`. Git keeps every previous version.
2. **The expectation:** update the numbers in `checks/pipeline_checks.sql`.

Rules that keep this repeatable (the offline tests enforce the first four):

- **Every file is safe to rerun.** Use `CREATE OR ALTER TABLE`, `CREATE OR REPLACE PROCEDURE/TASK/STREAMLIT` and `CREATE ... IF NOT EXISTS`. Deploying the same commit twice changes nothing.
- **Procedures rebuild their output** with `INSERT OVERWRITE`, so running them twice gives the same result.
- **New files are added to `deploy.sql`.** Nothing is deployed that isn't listed there, and nothing is run by hand.
- **No `DROP` or `TRUNCATE` in pipeline files.** A destructive change is a reviewed, one-off decision. Note that removing a column from a `CREATE OR ALTER TABLE` definition drops that column and its data.
- **Nobody edits DEV, QA or PROD directly in Snowsight.** If it isn't in Git, the next deployment overwrites it.
- **Fix forward.** If a release is wrong, open a new pull request. Don't patch the live object.

## Run the demo

| Stage | DEV | QA | PROD |
|---|---|---|---|
| Baseline (v1) | parents 3, educators 2 | parents 3, educators 2 | parents 3, educators 2 |
| v2 pull request validated | **parents 2, educators 1** | parents 3, educators 2 | parents 3, educators 2 |
| v2 merged and approved | parents 2, educators 1 | **parents 2, educators 1** | **parents 2, educators 1** |

The synthetic source in `setup/setup.sql` has 8 events: one duplicate delivery, one event with no user, untidy content-area names and two internal staff accounts. v1 cleans and deduplicates them. v2 adds one business rule: exclude internal traffic.

### 1. Baseline (before the meeting)

Run **Actions -> Analytics CI/CD -> Run workflow** on `main`, then approve `prod`. Afterwards, run `sql/audit.sql`: every environment shows v1, and the deploy log shows the same commit in QA and PROD.

### 2. The change (live)

```bash
git checkout -b feature/exclude-internal-traffic
cp -R examples/v2/. .
git diff                       # one WHERE clause, a version label, and the expected numbers
git commit -am "Exclude internal traffic from audience metrics"
git push -u origin feature/exclude-internal-traffic
gh pr create --fill
```

In the pull request's **Checks** tab, `checks` passes, then `dev` deploys and verifies. Open `GOLD.ENGAGEMENT_DASHBOARD` in `ANALYTICS_DEV` (Snowsight -> Projects -> Streamlit): DEV shows v2 while QA and PROD still show v1.

**Optional, to show the safety net:** copy only the Silver file, without the updated checks. The offline `checks` job fails in seconds, because the rule now produces numbers the checks don't expect. Nothing reaches Snowflake. If a mistake only shows up on real data, the Snowflake checks in `dev` fail instead and print a row like `weekly active users | parents | 3 | 2`.

### 3. Release

Merge the pull request. QA deploys automatically. Approve `prod`. Run `sql/audit.sql` to show the same commit in QA and PROD, the PROD task graph on its schedule, and the tagged deployment statements.

## Audit and cost

`sql/audit.sql` answers the questions that come up after go-live:

- What commit is in each environment, who deployed it, and when?
- Which numbers does each environment show?
- Did the last task graph runs succeed, and where did they fail?
- Does the live procedure match the file in Git?
- What did deployments, pipelines and dashboards cost this month?

Cost guardrails from setup: separate extra-small warehouses for pipelines (`PIPELINE_WH`) and dashboards (`REPORTING_WH`), each suspending after 60 seconds idle and capping statement run time. A 10-credit monthly resource monitor notifies at 75% and suspends both warehouses at 100%. DEV and QA only run when CI triggers them.

## One-time setup

<details>
<summary><strong>Expand: one-time setup, step by step (about 30 minutes)</strong></summary>

**You need:**

- A Snowflake account where you can use the `ACCOUNTADMIN` role.
- A GitHub account that can create repositories and change their settings. Required reviewers on environments are free for public repositories; private repositories need GitHub Team or Enterprise.
- The [GitHub CLI](https://cli.github.com/) (`gh`), signed in with `gh auth login`.

Do the steps in order. Snowflake needs the repository to exist first, and GitHub can only require checks that have already run once.

### Step 1 - Create the GitHub repository

From this folder:

```bash
git init -b main          # skip if the folder is already a Git repository
git add -A && git commit -m "Initial native CI/CD demo"
gh repo create <your-org>/<your-repo> --private --source . --push   # or --public
```

Then print the two numeric IDs you'll need in Step 2:

```bash
gh api repos/<your-org>/<your-repo> --jq '"owner id: \(.owner.id)   repo id: \(.id)"'
```

### Step 2 - Fill in the placeholders in `setup/setup.sql`

Open `setup/setup.sql` in your editor and use find-and-replace for each placeholder:

| Placeholder | Replace with | Example |
|---|---|---|
| `<your-org>` | GitHub user or organization name | `acme-data` |
| `<your-repo>` | Repository name | `analytics-pipelines` |
| `<your-org-id>` | `owner id` from Step 1 | `81234567` |
| `<your-repo-id>` | `repo id` from Step 1 | `912345678` |

They appear in section 05 (Git connection), section 06 (the three `SUBJECT` lines) and the optional section 09. Search afterwards for `<your-`; nothing should remain. Commit and push the file.

### Step 3 - Private repository only: give Snowflake read access

Skip this step for a public repository.

1. In GitHub, open your profile picture, then **Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens -> Generate new token**.
2. Under **Repository access**, choose **Only select repositories** and pick this repository. Under **Permissions -> Repository permissions**, set **Contents** to **Read-only**. Generate the token and copy it.
3. In section 05 of `setup/setup.sql`, uncomment the three blocks marked `PRIVATE REPOSITORY ONLY (1 of 3)` to `(3 of 3)`:
   - the `CREATE SECRET` statement: put your GitHub user name in `USERNAME`, and leave `PASSWORD` as the placeholder in the file;
   - the `ALLOWED_AUTHENTICATION_SECRETS` line in `CREATE API INTEGRATION`;
   - the `GIT_CREDENTIALS` line in `CREATE GIT REPOSITORY`.
4. Paste the real token only into the Snowsight worksheet in Step 4, never into the file. Commit and push the file with the placeholder still in place.

### Step 4 - Run the setup in Snowflake

1. In Snowsight, open **Projects -> Workspaces** (or **Worksheets**) and create a new SQL file.
2. Paste the full contents of `setup/setup.sql`. For a private repository, replace `<read-only token>` with the token from Step 3 in this worksheet only.
3. Run sections 00-08 in order. On the first run you can use **Run All**. Each section switches to the least powerful role that can do its work: `USERADMIN` for roles and users, `SYSADMIN` for warehouses and databases, `SECURITYADMIN` for grants, and `ACCOUNTADMIN` only for the budget, the integration and `EXECUTE TASK`. Sections 00-06 are safe to rerun. Section 07 loads the 8 source rows once: it first shows `LANDING_BEFORE_INSERT`. On any later run, if that count isn't 0, skip the transaction and go to section 08.
4. Check the results of section 08:

   | Query | Expected |
   |---|---|
   | `SHOW DATABASES LIKE 'ANALYTICS_%'` | `ANALYTICS_DEV`, `ANALYTICS_QA`, `ANALYTICS_PRD` |
   | `SHOW USERS LIKE 'ANALYTICS_CI_%'` | `ANALYTICS_CI_DEV`, `ANALYTICS_CI_QA`, `ANALYTICS_CI_PRD` |
   | `SHOW GIT BRANCHES` | `main` |
   | `SELECT COUNT(*) ... LANDING.AMPLITUDE.EVENTS` | `8` |

5. Get the account identifier for Step 5:

   ```sql
   SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS SNOWFLAKE_ACCOUNT;
   ```

If `SHOW GIT BRANCHES` fails, the `API_ALLOWED_PREFIXES` or `ORIGIN` URL doesn't match the repository, or a private repository is missing its token.

### Step 5 - Add one secret and one variable in GitHub

In the repository, open **Settings -> Secrets and variables -> Actions**.

| Tab | Button | Name | Value |
|---|---|---|---|
| **Secrets** | **New repository secret** | `SNOWFLAKE_ACCOUNT` | The value from Step 4, for example `MYORG-MYACCOUNT` |
| **Variables** | **New repository variable** | `DEPLOY_ENABLED` | `true` |

`DEPLOY_ENABLED` works as an off switch. Set it to `false` to stop all Snowflake deployments without editing the workflow.

### Step 6 - Create the three GitHub environments

Open **Settings -> Environments -> New environment** three times. The names must be lowercase and exactly as shown, because each one is part of the matching Snowflake user's OIDC `SUBJECT`.

| Environment name | Deployment branches and tags | Required reviewers | Used by |
|---|---|---|---|
| `dev` | **No restriction** (pull requests deploy from `refs/pull/<n>/merge`) | None | Every pull request |
| `qa` | **Selected branches and tags** -> add `main` | None | Every merge to `main` |
| `prod` | **Selected branches and tags** -> add `main` | Tick **Required reviewers** and add the people who approve releases | After QA passes |

For `prod`, you can also tick **Prevent self-review** so the person who merged can't approve their own release. Leave it unticked if you're presenting alone.

### Step 7 - Deploy the baseline (v1)

1. Open **Actions -> Analytics CI/CD -> Run workflow**, keep the branch as `main`, and select **Run workflow**.
2. `checks` runs first, then `qa` deploys automatically. `prod` then waits; select **Review deployments**, tick `prod`, and choose **Approve and deploy**.
3. In Snowsight, run `sql/audit.sql`. Each environment that has been deployed shows **parents 3, educators 2, v1**, and the deploy log shows the same commit in QA and PROD. DEV stays empty until the first pull request, because only pull requests deploy to DEV.

### Step 8 - Protect `main` with a ruleset

This stops anyone from pushing SQL straight to `main`, or merging before DEV has actually passed. GitHub only offers status checks it has already seen, so first make both checks run once:

1. Open a small test pull request, such as a one-line README edit:
   ```bash
   git checkout -b chore/register-checks
   echo "" >> README.md && git commit -am "Register required checks"
   git push -u origin chore/register-checks && gh pr create --fill
   ```
2. Wait for `checks`, `dev` and `dev-verified` to finish, but **don't merge yet**.

Now create the ruleset at **Settings -> Rules -> Rulesets -> New ruleset -> New branch ruleset**:

| Setting | Value |
|---|---|
| **Ruleset name** | `Protect main` |
| **Enforcement status** | **Active** |
| **Bypass list** | Leave empty. If you present alone, add **Repository admin** with **For pull requests only**, so you can merge your own pull request without anyone else approving. |
| **Target branches** | **Add target -> Include default branch** |
| **Restrict deletions** | On |
| **Require a pull request before merging** | On. **Required approvals:** `1`. Also tick **Dismiss stale pull request approvals when new commits are pushed**. |
| **Require status checks to pass** | On. Tick **Require branches to be up to date before merging**. Select **Add checks** and add `checks` and `dev-verified`, both from **GitHub Actions**. |
| **Block force pushes** | On |

Select **Create**, then merge or close the test pull request. From now on, a pull request can only merge after it has deployed to DEV and passed there.

`dev-verified` is the check to require, not `dev`. When DEV is skipped (for example because `DEPLOY_ENABLED` is `false`), GitHub treats the skipped `dev` job as passing, but `dev-verified` fails.

On the older settings page (**Settings -> Branches -> Add branch protection rule**), use the same settings with branch name pattern `main`.

### Step 9 - Optional: edit from Snowsight without a local Git setup

For teammates who'd rather not set up Git locally. Uncomment section 09 of `setup/setup.sql`, replace `<teammate-user>`, and run only that section. It creates:

- a second integration where each person signs in to GitHub with their own account, so commits show who made them and no shared token is used;
- an `ANALYTICS_DEVELOPER` role that can read DEV results but cannot change any environment.

The teammate then switches to `ANALYTICS_DEVELOPER`, opens **Projects -> Workspaces -> From Git repository**, creates a feature branch, edits the rule and its expected numbers, and commits. They open the pull request in GitHub as usual, and CI deploys it to DEV. Workspaces never deploys anything itself, so every change still goes through the same pull request, checks and approvals.

### Before each demo

- [ ] `sql/audit.sql` shows v1 in QA and PROD, and the same commit in both.
- [ ] `DEPLOY_ENABLED` is `true` and the `prod` environment has a reviewer who will be present.
- [ ] The ruleset `Protect main` is **Active** and requires `checks` and `dev-verified`.
- [ ] No open pull request is still waiting on DEV. Deployments run one at a time.

To test a deployment from a laptop with your own Snowflake CLI connection (the commit must already be pushed):

```bash
ci/deploy.sh DEV "$(git rev-parse HEAD)"
```

</details>

## Later: add-ons and when they pay off

- **Terraform:** best for account infrastructure, meaning everything in `setup/setup.sql` (roles, warehouses, databases, resource monitors, the Git integration and service users). Table definitions can stay in `CREATE OR ALTER` SQL, which is already declarative.
- **dbt:** worth adding when Gold has many models that depend on each other and needs tests, documentation and lineage. dbt then replaces the Silver and Gold procedures, while the same workflow and environments stay in place. Don't run procedures and dbt models for the same layer.
- **DCM Projects (Snowflake's declarative option):** see the next section.

## When to move to DCM Projects (declarative)

[DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-use) are Snowflake's built-in declarative deployment, generally available since [August 2026](https://docs.snowflake.com/en/release-notes/2026/other/2026-08-07-dcm-projects-ga). You describe the target state with `DEFINE` statements (tables, views, tasks, procedures, dynamic tables, roles, grants, warehouses and more). Snowflake compares that state with the account, shows a **plan** of what it would create, alter or drop, and applies it on **deploy**. Like this demo, it uses Jinja for DEV, QA and PROD, and the files can live in Git.

**How it differs from this demo:**

| | This demo (imperative, rerunnable) | DCM Projects (declarative) |
|---|---|---|
| You write | The statements to run, in order, in `deploy.sql` | The objects that should exist; Snowflake works out the order |
| Before deploying | Review the Git diff | Review the Git diff **and** a generated plan of every create, alter and drop |
| Removing an object | Write and review a one-off change | Delete its definition; the next deploy **drops** it |
| Drift (someone edited PROD by hand) | Overwritten on the next deploy; not reported | Shows up in the plan |
| Object coverage | Anything SQL can create (including Streamlit) | Supported `DEFINE` types; anything else runs as a separate script |

**Stay with this demo's approach while:**

- The team is still learning the flow, and the pipeline is a few dozen objects in Bronze and Silver.
- Most changes are procedure or rule edits like v2, which `CREATE OR REPLACE` already handles.
- You want every statement visible in one file, in the order it runs.

**Move to DCM Projects when one or more of these is true:**

- **Schemas change often,** especially once Gold grows. Reviewing a plan that says "alter column, drop view" is safer than reviewing hand-written `ALTER`s.
- **Objects get retired.** Removing a definition retires the object in every environment the same way, so nothing is left behind.
- **Drift worries you.** The plan reveals manual changes before they are overwritten.
- **Infrastructure and pipeline objects should share one tool.** Roles, grants, warehouses and tables can sit in one project, instead of SQL plus Terraform.
- **Approvers want to see the impact, not just the code.** The PROD approval step can show the plan output.

**How it fits this repository:** the workflow, the DEV → QA → PROD flow, OIDC sign-in, the checks and the task graph all stay. Only the deploy step changes: `snow dcm plan --target <env>` on the pull request, then `snow dcm deploy --target <env>` after approval. Object definitions move from `CREATE OR ALTER` to `DEFINE`, and objects DCM doesn't define (here, the Streamlit app) stay in a small post-deploy script.

**Cautions:**

- **Deploy drops anything that is no longer defined.** Always read the plan before approving, especially in PROD.
- **Adopt one layer at a time,** for example Bronze and Silver tables first. Don't let two tools manage the same object.
- **Some related features were still in preview** in the August 2026 release notes: the TEST and PREVIEW commands, the GitHub Actions for DCM, and `DEFINE STREAM`/`DEFINE PIPE`. Check their status before depending on them.

Choosing between dbt and DCM Projects: dbt structures the SQL that *transforms* data (models, tests, lineage). DCM Projects manage the *objects* that exist in each environment. A team can use both, with DCM for infrastructure, tables and grants and dbt for Silver and Gold models, as long as each object has exactly one owner.

## Troubleshooting

- **`dev` is skipped:** check `DEPLOY_ENABLED`, the environment branch rules, and that the pull request comes from this repository rather than a fork.
- **OIDC error:** the `SUBJECT` in setup section 06 must match the owner and repository IDs and the environment name (`dev`, `qa`, `prod`) exactly.
- **`commits/<sha>` not found:** the commit must be pushed to a branch before `FETCH`; the workflow deploys the pull request's head commit for this reason.
- **Task graph `FAILED`:** run query 3 in `sql/audit.sql`. `FIRST_ERROR_MESSAGE` names the failing task.
- **Checks failed:** the CI log prints each failing check with the expected and actual values.

Offline tests:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-ci.txt
.venv/bin/python -m unittest discover -s tests -v
```
