"""The JSON Schema: is it valid, do the examples conform to it, and does it stay
in sync with what the Terraform code expects?"""
import copy

import pytest
from jsonschema import Draft7Validator

from conftest import example_configs, load_yaml, referenced_definitions


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
    ("bad routine type", {"datasets": {"a": {"routines": {"f": {"routine_type": "MACRO"}}}}}),
    ("clustering too long", {"datasets": {"a": {"tables": {"t": {"clustering": ["a", "b", "c", "d", "e"]}}}}}),
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
    assert {"defaults", "datasets", "connections", "transfers"} <= set(doc)
    copy.deepcopy(doc)  # sanity: plain data
