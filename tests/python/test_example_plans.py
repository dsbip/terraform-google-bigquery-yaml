"""Plans every example with the real Google provider, without Google Cloud
access: a dummy OAuth token satisfies provider configuration and -refresh=false
avoids API reads. This exercises the provider's own validation and plan logic,
which the mocked unit tests (terraform test) do not.

Requires network access for `terraform init` (provider download).

Set GOOGLE_PROVIDER_VERSION (e.g. 7.42.0) to pin the provider version, which is
how CI checks the module's minimum supported versions.
"""
import json
import os
import shutil
import subprocess

import pytest

from conftest import EXAMPLES

# Variables each example needs besides project_id, and the resources expected.
EXAMPLE_CASES = {
    "basic": ({}, 6),
    "tables-and-schemas": ({}, 12),
    "authorized-views": ({}, 16),
    "routines": ({}, 15),
    "scheduled-queries": ({"aws_secret_access_key": "dummy"}, 12),
    "connections": ({"orders_db_password": "dummy"}, 14),
    "existing-datasets": ({}, 8),
    "layered-views": ({}, 10),
    "multi-environment": (None, 14),  # no project_id variable: projects come from var.environments
    "complete": ({}, 37),
}


def run(cmd, cwd, env):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=900)


@pytest.fixture(scope="module")
def plan_env(tmp_path_factory):
    env = dict(os.environ)
    env.update(
        GOOGLE_OAUTH_ACCESS_TOKEN="offline-plan-dummy-token",
        CHECKPOINT_DISABLE="1",
        TF_IN_AUTOMATION="1",
    )
    cache = None
    if not env.get("TF_PLUGIN_CACHE_DIR"):
        cache = tmp_path_factory.mktemp("plugin-cache")
        env["TF_PLUGIN_CACHE_DIR"] = str(cache)
    yield env
    if cache:
        shutil.rmtree(cache, ignore_errors=True)


@pytest.fixture
def repo_copy(tmp_path):
    """make(root_module) copies the repository, so .terraform/ and plan files
    never land in it, and returns root_module's directory in the copy. The
    provider is pinned there if GOOGLE_PROVIDER_VERSION is set. The copy is
    deleted after the test: its .terraform/ holds a provider binary of about
    200 MB (copied rather than linked on Windows)."""
    work = tmp_path / "repo"

    def make(root_module):
        shutil.copytree(
            EXAMPLES.parent,
            work,
            ignore=shutil.ignore_patterns(".git", ".terraform*", "*.tfstate*", "__pycache__", ".pytest_cache"),
        )
        cwd = work / root_module
        version = os.environ.get("GOOGLE_PROVIDER_VERSION")
        if version:
            (cwd / "versions_override.tf").write_text(
                'terraform {\n  required_providers {\n    google = {\n'
                f'      source  = "hashicorp/google"\n      version = "{version}"\n'
                "    }\n  }\n}\n",
                encoding="utf-8",
            )
        return cwd

    yield make
    shutil.rmtree(work, ignore_errors=True)


def test_every_example_has_a_case():
    examples = sorted(p.name for p in EXAMPLES.iterdir() if p.is_dir())
    assert examples == sorted(EXAMPLE_CASES), "add new examples to EXAMPLE_CASES"


@pytest.mark.parametrize("example", sorted(EXAMPLE_CASES))
def test_example_plans_with_real_provider(terraform_bin, plan_env, repo_copy, example):
    extra_vars, expected = EXAMPLE_CASES[example]
    cwd = repo_copy(f"examples/{example}")

    init = run([terraform_bin, "init", "-input=false", "-no-color", "-backend=false"], cwd, plan_env)
    assert init.returncode == 0, init.stdout + init.stderr

    args = [terraform_bin, "plan", "-refresh=false", "-input=false", "-no-color", "-lock=false", "-out=plan.bin"]
    if extra_vars is not None:
        args += ["-var", "project_id=example-project"]
        args += [x for k, v in extra_vars.items() for x in ("-var", f"{k}={v}")]
    plan = run(args, cwd, plan_env)
    assert plan.returncode == 0, plan.stdout + plan.stderr

    show = run([terraform_bin, "show", "-json", "plan.bin"], cwd, plan_env)
    assert show.returncode == 0, show.stderr
    changes = json.loads(show.stdout)["resource_changes"]
    creates = [c["address"] for c in changes if c["change"]["actions"] == ["create"]]
    assert len(creates) == expected, f"{len(creates)} resources planned:\n" + "\n".join(creates)
    assert len(creates) == len(changes), "only creations are expected in a fresh plan"


def test_live_fixture_plans_with_all_layers(terraform_bin, plan_env, repo_copy):
    """The live-test fixture (tests/integration) must stay deployable even when
    nobody has credentials to run the live test."""
    cwd = repo_copy("tests/integration")

    init = run([terraform_bin, "init", "-input=false", "-no-color", "-backend=false"], cwd, plan_env)
    assert init.returncode == 0, init.stdout + init.stderr

    plan = run(
        [
            terraform_bin, "plan", "-refresh=false", "-input=false", "-no-color", "-lock=false",
            "-var", "project_id=example-project",
            "-var", "suffix=ci",
            "-var", "test_member=serviceAccount:ci@example-project.iam.gserviceaccount.com",
            "-var", "enable_connections=true",
            "-var", "enable_transfers=true",
        ],
        cwd,
        plan_env,
    )
    assert plan.returncode == 0, plan.stdout + plan.stderr
    assert "Plan: 30 to add, 0 to change, 0 to destroy." in plan.stdout


def plan_errors(result):
    """Error details from `terraform plan -json` output."""
    details = []
    for line in result.stdout.splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("@level") == "error":
            details.append(message.get("diagnostic", {}).get("detail", ""))
    return "\n".join(details)


def test_partial_copy_with_an_older_schema_is_reported(terraform_bin, plan_env, repo_copy):
    """A copy of the module whose schema file is older than its .tf files
    (e.g. new .tf files copied over an old vendored copy) must say so, instead
    of reporting valid keys such as tables and dataset as unknown."""
    cwd = repo_copy("examples/basic")
    schema_path = cwd.parent.parent / "schemas" / "bigquery-config.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    # What a v1 schema file looks like to the v2 code.
    del schema["x-schema-revision"]
    for section in ("tables", "views", "materialized_views", "routines"):
        del schema["properties"][section]
    for definition in ("table", "view", "materialized_view", "routine"):
        del schema["definitions"][definition]["properties"]["dataset"]
    schema_path.write_text(json.dumps(schema), encoding="utf-8")

    init = run([terraform_bin, "init", "-input=false", "-no-color", "-backend=false"], cwd, plan_env)
    assert init.returncode == 0, init.stdout + init.stderr
    plan = run(
        [terraform_bin, "plan", "-refresh=false", "-input=false", "-lock=false", "-json", "-var", "project_id=example-project"],
        cwd,
        plan_env,
    )
    assert plan.returncode != 0
    errors = plan_errors(plan)
    assert "The BigQuery YAML configuration has 1 problem(s)" in errors, errors
    assert "schemas/bigquery-config.schema.json is from an older version of the module than its .tf files (schema revision 1, expected 2)" in errors, errors
    assert "Copy the whole module directory, schemas/ included" in errors, errors
    assert "unknown key" not in errors, errors
