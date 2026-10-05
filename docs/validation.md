# Validation

The module validates the whole configuration during `terraform plan`, before anything is created, and reports every problem at once:

```
Error: Resource precondition failed

The BigQuery YAML configuration has 5 problem(s):
  - datasets.sales: unknown key "descripton" (did you mean description?)
  - tables.orders.dataset: "salse" is not a key under datasets (did you mean sales?); declare a dataset managed elsewhere with create: false
  - tables.orders.time_partitioning: unknown key "feild" (did you mean field?)
  - views.v_orders: query or query_file is required
  - connections.orders_db.cloud_sql.credential.password_secret: "orders_pw" is not a key of the secrets variable
```

Each problem starts with its **YAML path**, so you can go straight to the line.

## Nothing is planned for an invalid file

While the configuration is invalid, the module gives every resource an empty `for_each`, so the plan shows only this message. It never mixes it with provider errors about half-built resources, and never deletes anything: a failed plan cannot be applied. `terraform destroy` still works with an invalid file.

## What is checked

**Structure**

- Unknown keys at every level, with suggestions for likely typos (same letters in another order, or a shared prefix or suffix).
- Sections that must be mappings (`datasets`, `tables`, `time_partitioning`, ...) or lists (`access`, `clustering`, `iam`, `arguments`, ...).
- Keys that cannot be defaults (`defaults.tables.table_id`, `defaults.tables.dataset`, ...).
- Keys that contain `.` (datasets, tables, views, materialized views, routines).
- Keys and names that YAML read as booleans (`on:`, `name: n`); see [troubleshooting](troubleshooting.md#yaml-booleans).
- Tab indentation, with the line numbers, when it stops the file from parsing; see [troubleshooting](troubleshooting.md#tabs).
- Duplicate keys, with their line numbers: top-level sections, and the keys of `datasets`, `tables`, `views`, `materialized_views`, `routines`, `connections` and `transfers` (block style). Terraform's YAML parser would otherwise keep only the last one; see [troubleshooting](troubleshooting.md#duplicate-keys).
- `tables`, `views`, `materialized_views` or `routines` inside a dataset (the v1 layout), with a pointer to [upgrading.md](upgrading.md).

**Required settings and combinations**

| Resource | Checks |
|---|---|
| configuration | exactly one of `config_file` / `config_yaml`; a project for every resource |
| datasets | `create` is a boolean; nothing but grants, authorizations and IDs on `create: false` datasets; `external_dataset_reference` complete |
| tables, views, materialized views, routines | `dataset` is set and is a key under `datasets` (with suggestions for typos) |
| tables | `schema` xor `schema_file`; a schema is a list of fields; time xor range partitioning; complete range partitioning; `source_uris` for external tables; external xor BigLake; complete `biglake_configuration`; resolvable foreign keys with both columns |
| views, materialized views | exactly one of `query` / `query_file`; time xor range partitioning |
| routines | at most one of `definition_body` / `definition_file`, and one of them unless remote or Spark; `data_type` on arguments unless `ANY_TYPE` / `FIXED_TABLE`; well-formed `return_type` / `return_table_type` |
| connections | exactly one type; complete Cloud SQL and connector settings; `aws.access_role.iam_role_id` |
| transfers | `data_source_id`; at most one of `query`, `query_file`, `params.query`; scalar `params` values |
| access and IAM entries | `role`; non-empty `members`; valid member formats; condition `expression` (and `title` for IAM conditions) |

**Files:** every `schema_file`, `query_file` and `definition_file` is a string and exists. Schema files must hold a JSON or YAML list of fields, or `{"fields": [...]}`.

**Schemas** (inline or from files, five levels deep): every field has a `name` and a valid `type`; `mode` is valid; only TableFieldSchema keys are used, with suggestions for typos; `RECORD` fields have `fields`; column names are unique, ignoring case. See [tables.md](tables.md#what-is-checked).

**SQL of views and materialized views:** not empty; a `.sql` file that uses `${project_id}`, `${datasets...}` or a `template_vars` name must be a `.tftpl` file instead. See [views.md](views.md#sql-files).

**References**

- Every `dataset:` of a table, view, materialized view or routine is a key under `datasets`.
- Authorized views, datasets and routines and foreign keys resolve: to a key in the file, `dataset.name` or `project.dataset.name`. A key shared by a view and a materialized view is reported as ambiguous.
- A bare connection name must be a connection key in the file.
- Every `password_secret` / `secret_access_key_secret` exists in the `secrets` variable.

**Uniqueness**

- No two dataset keys resolve to the same dataset.
- No two table, view or materialized view entries resolve to the same table.
- Keys are unique across tables, views and materialized views of a dataset.
- No two connection keys resolve to the same connection.

## What is left to the provider and BigQuery

- **Value formats** such as ID patterns and most enum values are validated by the Google provider during plan. The module does not duplicate those checks. The [JSON Schema](../schemas/bigquery-config.schema.json) flags common ones in your editor.
- **SQL**: BigQuery checks queries when views, materialized views, routines and scheduled queries are created, so SQL errors surface during apply.
- **Permissions and APIs** surface during apply.

## The JSON Schema

The allowed keys come from [`schemas/bigquery-config.schema.json`](../schemas/bigquery-config.schema.json): the module reads each definition's `properties`. Adding a key to the module means adding it to the schema, and the editor and the module always agree. The schema also knows types and enum values, and gives earlier feedback in the editor ([editor support](configuration.md#editor-support)).
