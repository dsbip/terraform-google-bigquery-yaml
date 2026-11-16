"""scripts/upgrade-to-v2.py: it must move tables, views, materialized views and
routines out of their datasets without changing anything else, keep comments,
and leave files it cannot rewrite safely untouched."""
import copy
import importlib.util
import shutil
import subprocess
import sys

import pytest
import yaml
from jsonschema import Draft7Validator

from conftest import REPO, example_configs

SCRIPT = REPO / "scripts" / "upgrade-to-v2.py"
V1 = REPO / "tests" / "fixtures" / "v1"
CHILD_TYPES = ["tables", "views", "materialized_views", "routines"]

spec = importlib.util.spec_from_file_location("upgrade_to_v2", SCRIPT)
script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(script)


def expected_v2(v1):
    """The v2 data for parsed v1 data: children moved out, dataset added."""
    v2 = copy.deepcopy(v1)
    for ds_key, ds in v2["datasets"].items():
        for section in CHILD_TYPES:
            if isinstance(ds, dict) and section in ds:
                for key, entry in (ds.pop(section) or {}).items():
                    v2.setdefault(section, {})[key] = {"dataset": ds_key, **(entry or {})}
    # A dataset left empty is written as `key:`, which parses as None.
    v2["datasets"] = {k: (None if v == {} else v) for k, v in v2["datasets"].items()}
    return v2


def run(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)


@pytest.mark.parametrize("name", ["complete.yaml", "edge-cases.yaml"])
def test_children_move_and_nothing_else_changes(name):
    v1 = (V1 / name).read_text(encoding="utf-8")
    assert yaml.safe_load(script.upgrade(v1)) == expected_v2(yaml.safe_load(v1))


@pytest.mark.parametrize("name", ["complete.yaml", "edge-cases.yaml"])
def test_comments_are_kept(name):
    v1 = (V1 / name).read_text(encoding="utf-8")
    v2 = script.upgrade(v1)

    def comments(text):
        return sorted(line.split("#", 1)[1].strip() for line in text.splitlines() if "#" in line and "${" not in line)

    assert comments(v2) == comments(v1)


def test_upgraded_complete_example_conforms_to_schema(schema):
    data = yaml.safe_load(script.upgrade((V1 / "complete.yaml").read_text(encoding="utf-8")))
    errors = list(Draft7Validator(schema).iter_errors(data))
    assert not errors, [e.message for e in errors]


def test_edge_cases_layout():
    v2 = script.upgrade((V1 / "edge-cases.yaml").read_text(encoding="utf-8"))
    assert "  empty_entry: { dataset: sales }\n  null_entry: { dataset: sales }\n" in v2
    assert "  flow: { dataset: sales, table_id: flow_t } # flow style with a comment\n" in v2
    assert '    dataset: "on"\n' in v2, "dataset keys YAML reads as booleans must be quoted"
    assert "tables:\n  # Comment above a section header" in v2
    assert v2.endswith("connections:\n  c:\n    cloud_resource: {}\n")


@pytest.mark.parametrize("path", example_configs(), ids=lambda p: p.parent.name + "/" + p.name)
def test_v2_files_are_left_unchanged(path):
    text = path.read_text(encoding="utf-8")
    assert script.upgrade(text) == text


def test_upgrading_twice_changes_nothing():
    once = script.upgrade((V1 / "complete.yaml").read_text(encoding="utf-8"))
    assert script.upgrade(once) == once


UNSUPPORTED = {
    "flow dataset": "datasets:\n  sales: { tables: { t: {} } }\n",
    "flow section": "datasets:\n  sales:\n    tables: { t: {} }\n",
    "flow datasets": "datasets: { sales: { tables: { t: {} } } }\n",
    "scalar entry": "datasets:\n  sales:\n    tables:\n      t: oops\n",
    "already partly upgraded": "datasets:\n  sales:\n    tables:\n      t: {}\ntables:\n  u: { dataset: sales }\n",
    "same key in two datasets": "datasets:\n  raw:\n    tables:\n      orders: {}\n  staging:\n    tables:\n      orders:\n        description: x\n",
}


def test_same_key_in_two_datasets_explains_the_fix(tmp_path):
    path = tmp_path / "config.yaml"
    path.write_bytes(UNSUPPORTED["same key in two datasets"].encode("utf-8"))
    assert "tables key 'orders' is used in datasets raw, staging" in run(path).stderr
    assert "set table_id: orders" in run(path).stderr


@pytest.mark.parametrize("name", sorted(UNSUPPORTED))
def test_unsupported_layouts_are_reported_and_left_unchanged(tmp_path, name):
    path = tmp_path / "config.yaml"
    path.write_bytes(UNSUPPORTED[name].encode("utf-8"))
    result = run(path)
    assert result.returncode == 1
    assert "not changed" in result.stderr
    assert path.read_bytes().decode("utf-8") == UNSUPPORTED[name]


def test_flow_style_datasets_without_children_are_fine(tmp_path):
    path = tmp_path / "config.yaml"
    path.write_bytes(b"datasets: { a: {}, b: { location: EU } }\n")
    assert run(path).returncode == 0
    assert path.read_bytes() == b"datasets: { a: {}, b: { location: EU } }\n"


def test_command_line_modes(tmp_path):
    path = tmp_path / "config.yaml"
    shutil.copy(V1 / "complete.yaml", path)
    v1 = path.read_bytes()

    check = run("--check", path)
    assert check.returncode == 1 and "needs upgrading" in check.stdout
    assert path.read_bytes() == v1

    stdout = run("--stdout", path)
    assert stdout.returncode == 0 and "\ntables:\n" in stdout.stdout
    assert path.read_bytes() == v1

    upgraded = run(path)
    assert upgraded.returncode == 0 and "upgraded" in upgraded.stdout
    assert run("--check", path).returncode == 0
    assert "already in the v2 layout" in run(path).stdout


def test_windows_line_endings(tmp_path):
    path = tmp_path / "config.yaml"
    v1 = (V1 / "edge-cases.yaml").read_text(encoding="utf-8")
    path.write_bytes(v1.replace("\n", "\r\n").encode("utf-8"))
    assert run(path).returncode == 0
    assert yaml.safe_load(path.read_bytes().decode("utf-8")) == expected_v2(yaml.safe_load(v1))
