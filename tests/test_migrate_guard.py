"""The migration workflow refuses to run when its approval gate is missing (F-17)."""
import json
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "check-migrate-environment.sh"

PROTECTED = {
    "name": "migrate-dev",
    "can_admins_bypass": False,
    "protection_rules": [
        {"type": "required_reviewers", "prevent_self_review": False,
         "reviewers": [{"type": "User", "reviewer": {"login": "reviewer"}}]},
        {"type": "branch_policy"},
    ],
    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
}
MAIN_ONLY = {"total_count": 1, "branch_policies": [{"name": "main", "type": "branch"}]}


def run(tmp_path, environment, policies):
    env_file, policies_file = tmp_path / "env.json", tmp_path / "policies.json"
    env_file.write_text(json.dumps(environment))
    policies_file.write_text(json.dumps(policies))
    return subprocess.run(
        ["bash", str(SCRIPT)], capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin",
             "ENV_JSON_FILE": str(env_file), "POLICIES_JSON_FILE": str(policies_file)},
    )


def test_protected_environment_passes(tmp_path):
    result = run(tmp_path, PROTECTED, MAIN_ONLY)
    assert result.returncode == 0, result.stderr
    assert "OK: migrate-dev requires 1 reviewer(s)" in result.stdout


def without_reviewers():
    """The state that let runs 1 and 2 through: no reviewers, administrator bypass on."""
    env = json.loads(json.dumps(PROTECTED))
    env["protection_rules"] = [r for r in env["protection_rules"] if r["type"] != "required_reviewers"]
    env["can_admins_bypass"] = True
    return env


@pytest.mark.parametrize("environment, policies, reason", [
    (without_reviewers(), MAIN_ONLY, "no required reviewers"),
    ({**PROTECTED, "can_admins_bypass": True}, MAIN_ONLY, "administrators can bypass"),
    ({**PROTECTED, "deployment_branch_policy": None}, {"branch_policies": []}, "not limited to the main branch"),
    (PROTECTED, {"branch_policies": [{"name": "*", "type": "branch"}]}, "not limited to the main branch"),
    (PROTECTED, {"branch_policies": [{"name": "main", "type": "branch"},
                                     {"name": "dev", "type": "branch"}]}, "not limited to the main branch"),
])
def test_missing_gate_fails(tmp_path, environment, policies, reason):
    result = run(tmp_path, environment, policies)
    assert result.returncode == 1
    assert reason in result.stderr


def test_every_problem_is_reported(tmp_path):
    result = run(tmp_path, {**without_reviewers(), "deployment_branch_policy": None}, {})
    assert result.stderr.count("FAIL:") == 3
