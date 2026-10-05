"""The JSON Schema: is it valid, do the examples conform to it, and does it stay
in sync with what the Terraform code expects?"""
import copy
import json
import re

import pytest
from jsonschema import Draft7Validator

from conftest import EXAMPLES, REPO, example_configs, load_yaml, referenced_definitions


def test_schema_is_valid_draft7(schema):
    Draft7Validator.check_schema(schema)


@pytest.mark.parametrize("path", example_configs(), ids=lambda p: p.parent.name + "/" + p.name)
def test_example_conforms_to_schema(schema, path):
    errors = sorted(Draft7Validator(schema).iter_errors(load_yaml(path)), key=lambda e: list(e.path))
    assert not errors, "\n".join(f"{'/'.join(map(str, e.path))}: {e.message}" for e in errors)


def test_every_definition_used_by_validation_exists(schema):
    """validation.tf looks up allowed keys by definition name; a typo there
    would make the plan fail for every configuration."""
    # "root" is the top-level object (schema["properties"]), not a definition.
    missing = [d for d in referenced_definitions() if d != "root" and d not in schema["definitions"]]
    assert not missing, f"validation.tf references unknown definitions: {missing}"
    assert len(referenced_definitions()) > 40


def test_defaults_forbid_identity_keys(schema):
    """Each defaults.<type> entry must name its forbidden keys where
    validation.tf reads them (allOf[1].propertyNames.not.enum), and those keys
    must exist on the referenced definition."""
    props = schema["definitions"]["defaults"]["properties"]
    for type_name in ["datasets", "tables", "views", "materialized_views", "routines", "connections", "transfers"]:
        all_of = props[type_name]["allOf"]
        definition = all_of[0]["$ref"].split("/")[-1]
        forbidden = all_of[1]["propertyNames"]["not"]["enum"]
        assert forbidden, type_name
        unknown = set(forbidden) - set(schema["definitions"][definition]["properties"])
        assert not unknown, f"defaults.{type_name} forbids keys that do not exist: {unknown}"


INVALID = [
    ("unknown top-level key", {"dataset": {}}),
    ("unknown dataset key", {"datasets": {"a": {"descripton": "x"}}}),
    ("datasets as a list", {"datasets": [{"dataset_id": "a"}]}),
    ("bad enum", {"datasets": {"a": {"storage_billing_model": "CHEAP"}}}),
    ("bad routine type", {"datasets": {"a": {}}, "routines": {"f": {"dataset": "a", "routine_type": "MACRO"}}}),
    ("clustering too long", {"datasets": {"a": {}}, "tables": {"t": {"dataset": "a", "clustering": ["a", "b", "c", "d", "e"]}}}),
    ("table without dataset", {"datasets": {"a": {}}, "tables": {"t": {"description": "x"}}}),
    ("view without dataset", {"views": {"v": {"query": "SELECT 1"}}}),
    ("empty routine entry", {"routines": {"f": None}}),
    ("dataset that is not a string", {"tables": {"t": {"dataset": ["a"]}}}),
    ("v1 nesting of tables in a dataset", {"datasets": {"a": {"tables": {"t": {}}}}}),
    ("dataset as a default", {"defaults": {"tables": {"dataset": "a"}}}),
    ("schema field key typo", {"tables": {"t": {"dataset": "a", "schema": [{"name": "x", "type": "STRING", "mdoe": "REQUIRED"}]}}}),
    ("policy tag key typo", {"tables": {"t": {"dataset": "a", "schema": [{"name": "x", "type": "STRING", "policyTags": {"name": ["p"]}}]}}}),
    ("bad range element type", {"tables": {"t": {"dataset": "a", "schema": [{"name": "x", "type": "RANGE", "rangeElementType": {"type": "INT64"}}]}}}),
    ("access without members", {"datasets": {"a": {"access": [{"role": "READER"}]}}}),
    ("identity key as default", {"defaults": {"tables": {"table_id": "x"}}}),
    ("placeholder-free string for a boolean", {"datasets": {"a": {"delete_contents_on_destroy": "yes please"}}}),
    ("cloud_sql without password_secret", {"connections": {"c": {"cloud_sql": {"instance_id": "p:r:i", "database": "d", "type": "POSTGRES", "credential": {"username": "u"}}}}}),
]


@pytest.mark.parametrize("name,config", INVALID, ids=[n for n, _ in INVALID])
def test_invalid_configuration_is_rejected(schema, name, config):
    assert list(Draft7Validator(schema).iter_errors(config)), f"schema accepted: {name}"


def test_placeholders_are_accepted_in_typed_fields(schema):
    config = {
        "defaults": {
            "tables": {"deletion_protection": "${protect}"},
            "datasets": {"deletion_policy": "${policy}", "default_table_expiration_ms": "${ms}"},
        }
    }
    errors = list(Draft7Validator(schema).iter_errors(config))
    assert not errors, [e.message for e in errors]


def test_complete_example_uses_every_top_level_section(schema):
    doc = load_yaml(next(p for p in example_configs() if p.parent.name == "complete"))
    assert set(schema["properties"]) - {"project_id"} <= set(doc)
    copy.deepcopy(doc)  # sanity: plain data


def test_child_sections_require_a_dataset(schema):
    """tables, views, materialized_views and routines entries must name their
    dataset; the definitions themselves must not require it, because
    defaults.<type> reuses them and forbids dataset."""
    for section, definition in {
        "tables": "table", "views": "view", "materialized_views": "materialized_view", "routines": "routine",
    }.items():
        entry = schema["properties"][section]["additionalProperties"]["allOf"]
        assert entry[0] == {"$ref": f"#/definitions/{definition}"}
        assert entry[1]["required"] == ["dataset"]
        assert "required" not in schema["definitions"][definition]
        assert list(schema["definitions"][definition]["properties"])[0] == "dataset"
        assert section not in schema["definitions"]["dataset"]["properties"]


@pytest.mark.parametrize("path", example_configs(), ids=lambda p: p.parent.name + "/" + p.name)
def test_examples_keep_schemas_sql_and_routines_in_files(path):
    """The examples show the recommended layout: table schemas in JSON files
    (schema_file), view SQL in SQL files (query_file) and routine bodies in
    routines/ (definition_file)."""
    doc = load_yaml(path)
    for key, table in (doc.get("tables") or {}).items():
        assert "schema" not in table, f"tables.{key}: use schema_file with a JSON file"
        if "schema_file" in table:
            assert table["schema_file"].endswith(".json"), f"tables.{key}: {table['schema_file']}"
            assert (path.parent / table["schema_file"]).is_file(), table["schema_file"]
    for section in ("views", "materialized_views"):
        for key, view in (doc.get(section) or {}).items():
            assert "query" not in view, f"{section}.{key}: use query_file with a SQL file"
            assert view["query_file"].endswith((".sql", ".sql.tftpl")), f"{section}.{key}: {view['query_file']}"
            assert (path.parent / view["query_file"]).is_file(), view["query_file"]
    extensions = {"SQL": (".sql", ".sql.tftpl"), "JAVASCRIPT": (".js",), "PYTHON": (".py",)}
    for key, routine in (doc.get("routines") or {}).items():
        assert "definition_body" not in routine, f"routines.{key}: use definition_file with a file in routines/"
        if "definition_file" in routine:
            language = str(routine.get("language", "SQL")).upper()
            assert routine["definition_file"].startswith("routines/"), f"routines.{key}: {routine['definition_file']}"
            assert routine["definition_file"].endswith(extensions[language]), f"routines.{key}: {routine['definition_file']}"
            assert (path.parent / routine["definition_file"]).is_file(), routine["definition_file"]


def example_schema_files():
    return sorted(EXAMPLES.glob("*/schemas/*.json"))


@pytest.mark.parametrize("path", example_schema_files(), ids=lambda p: p.parent.parent.name + "/" + p.name)
def test_example_schema_files_conform(schema, path):
    """Schema files are checked against the same field definition as inline
    schemas: required name and type, known keys, valid types and modes."""
    validator = Draft7Validator({"$ref": "#/definitions/schema", "definitions": schema["definitions"]})
    with open(path, encoding="utf-8") as fh:
        errors = list(validator.iter_errors(json.load(fh)))
    assert not errors, [f"{'/'.join(map(str, e.path))}: {e.message}" for e in errors]


def test_schema_revision_matches_the_module(schema):
    """validation.tf compares the schema file's revision with the one the .tf
    files expect, to catch partial copies of the module; both must change
    together."""
    main_tf = (REPO / "main.tf").read_text(encoding="utf-8")
    expected = int(re.search(r"^\s*schema_revision\s*=\s*(\d+)", main_tf, re.M).group(1))
    assert schema["x-schema-revision"] == expected
