"""Shared helpers for the Python test suite (schema checks and real-provider
plans). Run from the repository root:  python -m pytest tests/python
"""
import json
import os
import pathlib
import re
import shutil

import pytest
import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO / "schemas" / "bigquery-config.schema.json"
EXAMPLES = REPO / "examples"


def example_configs():
    """Every YAML configuration under examples/ (schema files excluded)."""
    return sorted(
        p for p in EXAMPLES.rglob("*.yaml") if "schemas" not in p.relative_to(EXAMPLES).parts
    )


def load_yaml(path):
    """Parse a configuration the way an editor would: before template rendering."""
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


@pytest.fixture(scope="session")
def schema():
    with open(SCHEMA_PATH, encoding="utf-8") as fh:
        return json.load(fh)


@pytest.fixture(scope="session")
def terraform_bin():
    """Terraform binary for the plan tests: $TERRAFORM_BIN or terraform on PATH."""
    path = os.environ.get("TERRAFORM_BIN") or shutil.which("terraform")
    if not path:
        pytest.skip("terraform not found (set TERRAFORM_BIN)")
    return path


def tf_files_text():
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(REPO.glob("*.tf")))


def referenced_definitions():
    """Schema definition names that validation.tf checks objects against."""
    return sorted(set(re.findall(r'def\s*=\s*"([a-z_]+)"', tf_files_text())))
