"""Offline checks that run on every pull request before anything touches Snowflake."""
import re
import subprocess
import unittest
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PIPELINES = ROOT / "pipelines"
V2 = ROOT / "examples/v2"
ENVIRONMENT_DATABASE = re.compile(r"\bANALYTICS_(DEV|QA|PRD)\b")
SAFE_CREATE = re.compile(r"(?i)^\s*CREATE\s+(OR\s+(REPLACE|ALTER)\s|\w+\s+IF\s+NOT\s+EXISTS\s)")


def pipeline_files():
    return sorted(PIPELINES.rglob("*.sql"))


def seed_rows():
    block = (ROOT / "setup/setup.sql").read_text().split("-- SEED START", 1)[1].split("-- SEED END", 1)[0]
    rows = []
    for line in block.splitlines():
        if line.strip().startswith("('"):
            rows.append([None if null else value for value, null in re.findall(r"'([^']*)'|(NULL)", line)])
    return rows


def simulate_weekly_active_users(silver_sql):
    """Apply the Silver rules in Python to the seed rows, then count users per content area."""
    excludes_internal = "<> 'internal'" in silver_sql
    seen, users = set(), defaultdict(set)
    for event_id, user_id, event_time, _, area, _, user_type in seed_rows():
        if event_id is None or user_id is None or event_time is None or event_id in seen:
            continue
        if excludes_internal and (user_type or "").lower() == "internal":
            continue
        seen.add(event_id)
        users[area.strip().lower()].add(user_id)
    return {area: len(ids) for area, ids in users.items()}


def expected_users(checks_sql):
    values = re.search(r"FROM VALUES (.+)$", checks_sql, re.M).group(1)
    return {area: int(count) for area, count in re.findall(r"\('([a-z]+)', (\d+)\)", values)}


def expected_version(checks_sql):
    return re.search(r"'gold rules version', NULL, '(v\d+)'", checks_sql).group(1)


def silver_version(silver_sql):
    return re.search(r"'(v\d+)' AS RULES_VERSION", silver_sql).group(1)


class PipelineFiles(unittest.TestCase):
    def test_deploy_runs_every_pipeline_file_exactly_once(self):
        deploy = (PIPELINES / "deploy.sql").read_text()
        referenced = re.findall(r"EXECUTE IMMEDIATE FROM '\./([^']+)'", deploy)
        self.assertEqual(len(referenced), len(set(referenced)), "a file is deployed twice")
        others = {str(path.relative_to(PIPELINES)) for path in pipeline_files() if path.name != "deploy.sql"}
        self.assertEqual(set(referenced), others, "deploy.sql must list every pipeline file")

    def test_definitions_are_safe_to_rerun(self):
        for path in pipeline_files():
            text = path.read_text()
            for line in text.splitlines():
                if re.match(r"(?i)\s*CREATE\b", line):
                    self.assertRegex(line, SAFE_CREATE, f"{path.name}: use OR REPLACE, OR ALTER or IF NOT EXISTS")
                if re.match(r"(?i)\s*INSERT\s+INTO\b", line):
                    self.assertEqual(path.name, "deploy.sql", f"{path.name}: rebuild with INSERT OVERWRITE")
            self.assertNotRegex(text, r"(?im)^\s*(DROP|TRUNCATE)\b", f"{path.name}: destructive change needs review")

    def test_environment_comes_from_the_pipeline_not_the_code(self):
        for path in [*pipeline_files(), *(ROOT / "checks").glob("*.sql"), *(ROOT / "streamlit").glob("*.py")]:
            self.assertNotRegex(path.read_text(), ENVIRONMENT_DATABASE, f"{path.name}: use {{{{ env }}}}")

    def test_templated_files_enable_jinja(self):
        for path in [*pipeline_files(), *(ROOT / "checks").glob("*.sql")]:
            text = path.read_text()
            if "{{" in text or "{%" in text:
                self.assertTrue(text.startswith("--!jinja\n"), f"{path.name} must start with --!jinja")

    def test_seed_rows_fall_in_the_checked_week(self):
        rows = seed_rows()
        self.assertEqual(len(rows), 8)
        for row in rows:
            self.assertEqual(len(row), 7)
            day = datetime.strptime(row[2], "%Y-%m-%d %H:%M:%S").date()
            self.assertTrue(date(2026, 9, 21) <= day <= date(2026, 9, 27))


class BusinessRules(unittest.TestCase):
    def check_release(self, silver_path, checks_path):
        silver, checks = silver_path.read_text(), checks_path.read_text()
        self.assertEqual(expected_users(checks), simulate_weekly_active_users(silver),
                         "checks disagree with what the Silver rules produce from the seed data")
        self.assertEqual(expected_version(checks), silver_version(silver))

    def test_current_rules_match_their_checks(self):
        self.check_release(PIPELINES / "silver/events.sql", ROOT / "checks/pipeline_checks.sql")

    def test_v2_example_matches_its_checks(self):
        self.check_release(V2 / "pipelines/silver/events.sql", V2 / "checks/pipeline_checks.sql")
        self.assertEqual(simulate_weekly_active_users((V2 / "pipelines/silver/events.sql").read_text()),
                         {"parents": 2, "educators": 1})

    def test_v1_baseline_numbers(self):
        self.assertEqual(simulate_weekly_active_users("'v1' AS RULES_VERSION"), {"parents": 3, "educators": 2})

    def test_v2_example_only_touches_silver_rules_and_checks(self):
        changed = sorted(str(path.relative_to(V2)) for path in V2.rglob("*") if path.is_file())
        self.assertEqual(changed, ["checks/pipeline_checks.sql", "pipelines/silver/events.sql"])


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/deploy.yml").read_text())
        cls.jobs = cls.workflow["jobs"]

    def test_promotion_order(self):
        self.assertEqual(self.jobs["dev"]["environment"], "dev")
        self.assertEqual(self.jobs["qa"]["environment"], "qa")
        self.assertEqual(self.jobs["prod"]["environment"], "prod")
        self.assertEqual(self.jobs["prod"]["needs"], "qa")
        self.assertIn("pull_request", self.jobs["dev"]["if"])
        self.assertIn("head.repo.full_name == github.repository", self.jobs["dev"]["if"])
        for job in ("qa", "prod"):
            self.assertIn("github.ref == 'refs/heads/main'", self.jobs[job]["if"])
            self.assertNotIn("pull_request", self.jobs[job]["if"])
        self.assertFalse(self.workflow["concurrency"]["cancel-in-progress"])

    def test_each_job_deploys_only_its_own_environment(self):
        for job, environment in (("dev", "DEV"), ("qa", "QA"), ("prod", "PRD")):
            env = self.jobs[job]["env"]
            self.assertEqual(env["SNOWFLAKE_USER"], f"ANALYTICS_CI_{environment}")
            self.assertEqual(env["SNOWFLAKE_ROLE"], f"ANALYTICS_DEPLOY_{environment}")
            runs = [step["run"] for step in self.jobs[job]["steps"] if "run" in step]
            self.assertEqual(runs, [f'ci/deploy.sh {environment} "$DEPLOY_SHA"'])

    def test_least_privilege_and_pinned_actions(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        for name, job in self.jobs.items():
            if "id-token" in job.get("permissions", {}):
                self.assertIn(name, ("dev", "qa", "prod"))
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"@[0-9a-f]{40}$")
                    if step["uses"].startswith("actions/checkout@"):
                        self.assertFalse(step["with"]["persist-credentials"])
                self.assertNotIn("${{", step.get("run", ""), "pass values through env, not inline")

    def test_deploy_script_rejects_bad_input_before_connecting(self):
        script = ROOT / "ci/deploy.sh"
        for arguments in (["UAT", "a" * 40], ["DEV", "main"], ["PRD", "A" * 40], ["DEV", "a" * 40 + "; DROP"]):
            result = subprocess.run(["bash", str(script), *arguments], capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin"})
            self.assertEqual(result.returncode, 2, arguments)
            self.assertIn("FAIL", result.stderr)


if __name__ == "__main__":
    unittest.main()
