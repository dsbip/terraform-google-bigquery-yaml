"""Documentation checks: every configuration key is documented on its page, and
every relative link in the markdown files points to a file that exists."""
import re

import pytest

from conftest import REPO

# Schema definition -> documentation page that must mention each of its keys.
DOCUMENTED_IN = {
    "defaults": "docs/configuration.md",
    "iam_binding": "docs/configuration.md",
    "iam_condition": "docs/configuration.md",
    "dataset": "docs/datasets.md",
    "access_entry": "docs/datasets.md",
    "access_condition": "docs/datasets.md",
    "external_dataset_reference": "docs/datasets.md",
    "external_catalog_dataset_options": "docs/datasets.md",
    "table": "docs/tables.md",
    "time_partitioning": "docs/tables.md",
    "range_partitioning": "docs/tables.md",
    "range": "docs/tables.md",
    "table_constraints": "docs/tables.md",
    "foreign_key": "docs/tables.md",
    "column_references": "docs/tables.md",
    "external_data_configuration": "docs/tables.md",
    "csv_options": "docs/tables.md",
    "json_options": "docs/tables.md",
    "parquet_options": "docs/tables.md",
    "avro_options": "docs/tables.md",
    "google_sheets_options": "docs/tables.md",
    "hive_partitioning_options": "docs/tables.md",
    "bigtable_options": "docs/tables.md",
    "bigtable_column_family": "docs/tables.md",
    "bigtable_column": "docs/tables.md",
    "biglake_configuration": "docs/tables.md",
    "view": "docs/views.md",
    "materialized_view": "docs/views.md",
    "routine": "docs/routines.md",
    "routine_argument": "docs/routines.md",
    "remote_function_options": "docs/routines.md",
    "spark_options": "docs/routines.md",
    "connection": "docs/connections.md",
    "cloud_sql": "docs/connections.md",
    "cloud_sql_credential": "docs/connections.md",
    "aws": "docs/connections.md",
    "aws_access_role": "docs/connections.md",
    "azure": "docs/connections.md",
    "cloud_spanner": "docs/connections.md",
    "spark": "docs/connections.md",
    "spark_metastore_service_config": "docs/connections.md",
    "spark_history_server_config": "docs/connections.md",
    "connector_configuration": "docs/connections.md",
    "connector_asset": "docs/connections.md",
    "connector_authentication": "docs/connections.md",
    "connector_username_password": "docs/connections.md",
    "connector_endpoint": "docs/connections.md",
    "connector_network": "docs/connections.md",
    "connector_private_service_connect": "docs/connections.md",
    "transfer": "docs/transfers.md",
    "schedule_options": "docs/transfers.md",
    "email_preferences": "docs/transfers.md",
    "sensitive_params": "docs/transfers.md",
}


@pytest.mark.parametrize("definition", sorted(DOCUMENTED_IN))
def test_every_key_is_documented(schema, definition):
    text = (REPO / DOCUMENTED_IN[definition]).read_text(encoding="utf-8")
    keys = schema["definitions"][definition].get("properties", {})
    missing = [k for k in keys if not re.search(rf"\b{re.escape(k)}\b", text)]
    assert not missing, f"{DOCUMENTED_IN[definition]} does not mention {definition} keys: {missing}"


def test_top_level_keys_are_documented(schema):
    text = (REPO / "docs/configuration.md").read_text(encoding="utf-8")
    assert all(re.search(rf"\b{k}\b", text) for k in schema["properties"])


def markdown_files():
    return sorted(
        p for p in REPO.rglob("*.md")
        if not any(part.startswith(".terraform") or part == ".pytest_cache" for part in p.parts)
    )


@pytest.mark.parametrize("path", markdown_files(), ids=lambda p: str(p.relative_to(REPO)).replace("\\", "/"))
def test_relative_links_resolve(path):
    text = path.read_text(encoding="utf-8")
    # Ignore code blocks: they contain HCL/YAML, not links.
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    broken = []
    for target in re.findall(r"\]\(([^)\s]+)\)", text):
        if re.match(r"^(https?:|mailto:|#)", target):
            continue
        file_part = target.split("#", 1)[0]
        if not (path.parent / file_part).exists():
            broken.append(target)
    assert not broken, f"broken links in {path.relative_to(REPO)}: {broken}"
