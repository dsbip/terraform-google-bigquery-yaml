# Changelog

All notable changes to this module are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-10-01

### Changed (breaking)

- Tables, views, materialized views and routines are top-level sections (`tables`, `views`, `materialized_views`, `routines`) instead of being nested inside their dataset. Each entry names its dataset with the new, required `dataset` key. Terraform addresses and output keys stay `"<dataset key>.<key>"`, so an upgraded configuration plans with no changes. See [docs/upgrading.md](docs/upgrading.md).
- Validation messages for these entries use the new paths: `tables.<key>...` instead of `datasets.<dataset>.tables.<key>...`.
- Keys of datasets, tables, views, materialized views and routines cannot contain `.`, which separates the dataset key from the key in references.

### Added

- `scripts/upgrade-to-v2.py` rewrites v1 configuration files in the v2 layout, keeping comments, flow style and placeholders.
- References by key alone: `authorized_views`, `authorized_routines` and `table_constraints.foreign_keys[].referenced_table` accept the key of a view, materialized view, routine or table in the file (`authorized_views: [revenue]`). The v1 forms still work.
- Validation: `dataset` must be a key under `datasets`, with did-you-mean suggestions; a v1 layout gets a message saying how to move each nested section; duplicate keys, which YAML would otherwise drop silently, are reported with their line numbers; tab indentation that stops the file from parsing is reported with its line numbers.
- Table schemas and view SQL in files, checked: a schema file may also contain a TableSchema object, `{"fields": [...]}`. Every schema field, inline or from a file, is checked five levels deep: `name` and `type` present, valid `type` and `mode`, only TableFieldSchema keys (with suggestions), `fields` on `RECORD` fields, and no duplicate column names. Empty view SQL fails the plan, as does a `.sql` file that uses `${project_id}`, `${datasets...}` or a `template_vars` name, since only `.tftpl` files are rendered.
- Every example keeps its table schemas in `schemas/*.json` (`schema_file`) and its view and materialized view SQL in `sql/*.sql.tftpl` (`query_file`).
- Unit tests grew from 81 to 98, with tests for the new layout, references by key, schema and SQL files, and the new checks. Every example and the live-test fixture were planned in their v1 and v2 forms with the real provider, and all 174 resources were identical.

## [1.0.0] - 2026-09-30

First release.

### Added

- YAML-driven creation of BigQuery datasets, tables, views, materialized views, routines, connections and data transfer configs.
- Dataset access grants (`google_bigquery_dataset_access`, non-authoritative) with IAM-style members and role normalisation.
- Authorized views, authorized datasets and authorized routines, with references by YAML key.
- Table, view, routine and connection IAM (`*_iam_member`).
- External tables (Cloud Storage, Google Sheets, Bigtable), BigLake tables with metadata caching, object tables and BigLake managed Iceberg tables.
- Every connection type: Cloud resource, Cloud SQL, Spanner, AWS, Azure, Spark and the connector framework.
- `defaults` per resource type, with merged labels and prepended dataset access.
- Templating: `config_file` is rendered with `templatefile()`; referenced `*.tftpl` files get `project_id`, `datasets` and `template_vars`.
- Data type shortcuts for routines (`data_type: INT64`, mappings, JSON strings).
- Secrets passed through the `secrets` variable and referenced by name.
- Validation of the whole configuration with YAML paths and did-you-mean suggestions; nothing is planned while the configuration is invalid.
- JSON Schema for editors, which is also the module's list of allowed keys.
- Ten examples, 81 unit tests, real-provider plan tests, a live integration test, and CI across Terraform 1.5.7/1.7.5/latest and google provider 7.42.0/latest.

[2.0.0]: https://github.com/dsbip/terraform-google-bigquery-yaml/releases/tag/v2.0.0
[1.0.0]: https://github.com/dsbip/terraform-google-bigquery-yaml/releases/tag/v1.0.0
