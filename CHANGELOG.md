# Changelog

All notable changes to this module are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/dsbip/terraform-google-bigquery-yaml/releases/tag/v1.0.0
