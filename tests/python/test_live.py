"""Live test against a real Google Cloud project (tests/integration).

Skipped unless BQ_YAML_TEST_PROJECT is set. Uses Application Default
Credentials. Everything is created under bqyaml_<random suffix> and destroyed
at the end, also when a step fails.

  apply  ->  plan shows no changes  ->  apply revision 2 (in-place updates)
         ->  plan shows no changes  ->  destroy

Optional environment variables:
  BQ_YAML_TEST_LOCATION      BigQuery location (default US)
  BQ_YAML_TEST_MEMBER        IAM member for table/routine/dataset grants,
                             e.g. serviceAccount:ci@p.iam.gserviceaccount.com
  BQ_YAML_TEST_CONNECTIONS   "true" to test connections (Connection API)
  BQ_YAML_TEST_TRANSFERS     "true" to test transfers (Data Transfer API)
"""
import json
import os
import secrets
import shutil
import subprocess

import pytest

from conftest import REPO

PROJECT = os.environ.get("BQ_YAML_TEST_PROJECT")

pytestmark = pytest.mark.skipif(not PROJECT, reason="set BQ_YAML_TEST_PROJECT to run the live test")


def terraform(binary, args, cwd, env):
    return subprocess.run(
        [binary, *args], cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=3600
    )


def check(result, what):
    assert result.returncode == 0, f"{what} failed:\n{result.stdout}\n{result.stderr}"


def test_live_lifecycle(terraform_bin, tmp_path):
    suffix = "t" + secrets.token_hex(3)
    work = tmp_path / "repo"
    shutil.copytree(REPO, work, ignore=shutil.ignore_patterns(".git", ".terraform*", "*.tfstate*", "__pycache__", ".pytest_cache"))
    cwd = work / "tests" / "integration"
    env = dict(os.environ, TF_IN_AUTOMATION="1", CHECKPOINT_DISABLE="1")

    def variables(revision):
        return [
            "-var", f"project_id={PROJECT}",
            "-var", f"suffix={suffix}",
            "-var", f"location={os.environ.get('BQ_YAML_TEST_LOCATION', 'US')}",
            "-var", f"revision={revision}",
            "-var", f"test_member={os.environ.get('BQ_YAML_TEST_MEMBER', '')}",
            "-var", f"enable_connections={os.environ.get('BQ_YAML_TEST_CONNECTIONS', 'false')}",
            "-var", f"enable_transfers={os.environ.get('BQ_YAML_TEST_TRANSFERS', 'false')}",
        ]

    def assert_no_changes(revision):
        plan = terraform(terraform_bin, ["plan", "-input=false", "-no-color", "-detailed-exitcode", *variables(revision)], cwd, env)
        assert plan.returncode == 0, f"expected an empty plan (exit 0), got {plan.returncode}:\n{plan.stdout}\n{plan.stderr}"

    check(terraform(terraform_bin, ["init", "-input=false", "-no-color"], cwd, env), "init")
    revision = 1
    try:
        check(terraform(terraform_bin, ["apply", "-input=false", "-no-color", "-auto-approve", *variables(1)], cwd, env), "apply")
        assert_no_changes(1)

        outputs = json.loads(terraform(terraform_bin, ["output", "-json"], cwd, env).stdout)
        datasets = outputs["datasets"]["value"]
        assert set(datasets) == {"raw", "shared", "analytics"}
        assert datasets["raw"]["dataset_id"] == f"bqyaml_{suffix}_raw"
        assert outputs["resource_counts"]["value"]["core"]["authorized_views"] == 2

        revision = 2
        check(terraform(terraform_bin, ["apply", "-input=false", "-no-color", "-auto-approve", *variables(2)], cwd, env), "update")
        assert_no_changes(2)
    finally:
        destroy = terraform(terraform_bin, ["destroy", "-input=false", "-no-color", "-auto-approve", *variables(revision)], cwd, env)
        # Keep the copy (and its state) when destroy fails, for manual clean-up.
        check(destroy, f"destroy (state is in {cwd}; clean up bqyaml_{suffix}_* by hand if needed)")
        shutil.rmtree(work, ignore_errors=True)
