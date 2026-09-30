# Tables

Tables are declared under their dataset:

```yaml
datasets:
  sales:
    tables:
      orders:
        description: One row per order.
        schema_file: schemas/orders.json
        time_partitioning:
          field: ordered_at
        clustering: [customer_id]
        require_partition_filter: true
```

- [Keys](#keys)
- [Schemas](#schemas)
- [Partitioning and clustering](#partitioning-and-clustering)
- [Primary and foreign keys](#primary-and-foreign-keys)
- [External tables](#external-tables)
- [BigLake managed tables](#biglake-managed-tables)
- [Deletion protection](#deletion-protection)
- [Table IAM](#table-iam)

## Keys

| Key | Type | Default | Description |
|---|---|---|---|
| `table_id` | string | map key | Table ID. |
| `friendly_name` | string | | |
| `description` | string | | |
| `labels` | map | | Merged with the default labels. |
| `schema` | list or JSON string | | Inline schema. Mutually exclusive with `schema_file`. |
| `schema_file` | path | | JSON or YAML schema file. |
| `time_partitioning` | mapping | | `type` (`DAY` default, `HOUR`, `MONTH`, `YEAR`), `field` (omit for ingestion time), `expiration_ms`. |
| `range_partitioning` | mapping | | `field` and `range: {start, end, interval}`. |
| `require_partition_filter` | bool | | Queries must filter on the partitioning column. |
| `clustering` | list | | Up to four columns, in priority order. |
| `expiration_time` | number | | Expiry time, in milliseconds since the epoch. |
| `deletion_protection` | bool | provider default (`true`) | See [Deletion protection](#deletion-protection). |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | | Provider deletion policy. |
| `encryption_configuration` | `{kms_key_name}` | | Customer-managed encryption key. |
| `table_constraints` | mapping | | `primary_key` and `foreign_keys`. |
| `external_data_configuration` | mapping | | Makes the table external. |
| `biglake_configuration` | mapping | | Makes the table a BigLake managed (Iceberg) table. |
| `max_staleness` | string | | INTERVAL literal, e.g. `"0-0 0 4:0:0"` (BigLake metadata caching). |
| `resource_tags` | map | | Resource Manager tags. |
| `ignore_auto_generated_schema` | bool | | Ignore columns the server adds (e.g. hive partition keys). |
| `ignore_schema_changes` | list | | Schema fields to ignore; currently only `dataPolicies`. |
| `iam` | list | | [Table IAM](#table-iam). |

## Schemas

A schema is a list of BigQuery fields, in the format used by the BigQuery API and `bq show --schema`. Field keys are camelCase (`policyTags`, `defaultValueExpression`, `maxLength`, ...).

Inline:

```yaml
schema:
  - { name: order_id, type: STRING, mode: REQUIRED, description: Primary key }
  - { name: amount, type: NUMERIC, precision: "12", scale: "2" }
  - name: items
    type: RECORD
    mode: REPEATED
    fields:
      - { name: sku, type: STRING }
      - { name: quantity, type: INT64 }
```

From a file (relative to the configuration file):

```yaml
schema_file: schemas/orders.json    # or .yaml / .yml
```

As a JSON string: `schema: '[{"name":"id","type":"STRING"}]'`.

Notes:

- The provider compares schemas as JSON. Write types the way BigQuery returns them to avoid diffs after apply: `RECORD` rather than `STRUCT`, `NUMERIC` rather than `DECIMAL`. `INTEGER`/`INT64`, `FLOAT`/`FLOAT64` and `BOOLEAN`/`BOOL` are treated as equal.
- Write integer attributes (`maxLength`, `precision`, `scale`) as quoted strings. The API returns them as strings.
- Quote column names that YAML would read as booleans: `name: "on"`, `name: "y"`. Validation reports them otherwise ([troubleshooting](troubleshooting.md#yaml-booleans)).
- Some schema changes make the provider **replace the table, losing its data**. These are: changing a column's type, changing a mode other than `REQUIRED` → `NULLABLE`, adding a `REQUIRED` column, dropping a nested field, or dropping and adding columns in the same change. In-place changes are: adding `NULLABLE`/`REPEATED` columns, relaxing `REQUIRED` to `NULLABLE`, dropping top-level columns (unless the table has row access policies), and changing descriptions or policy tags. Check the plan for `must be replaced` before applying schema changes.

## Partitioning and clustering

```yaml
time_partitioning:           # daily partitions on a column
  field: event_time
  expiration_ms: 7776000000  # drop partitions after 90 days

time_partitioning: {}        # ingestion-time partitioning (daily)

range_partitioning:          # integer ranges
  field: customer_id
  range: { start: 0, end: 1000000, interval: 10000 }
```

`time_partitioning` and `range_partitioning` are mutually exclusive. `require_partition_filter` is a table-level key (the provider's `time_partitioning.require_partition_filter` is deprecated). Datasets can set `default_partition_expiration_ms` for all their partitioned tables.

## Primary and foreign keys

```yaml
table_constraints:
  primary_key:
    columns: [order_id]
  foreign_keys:
    - name: fk_orders_customers
      referenced_table: sales.customers       # a table key in this file, or dataset.table, or project.dataset.table
      column_references:
        referencing_column: customer_id
        referenced_column: customer_id
```

`referenced_table` is resolved like other [references](configuration.md#references). It can also be written as `{project_id, dataset_id, table_id}`.

BigQuery keys are **not enforced**: they document relationships and let the optimiser remove unnecessary joins. Terraform creates all tables of one configuration in parallel, so a foreign key may be created before the table it references. The live test creates such a pair in one apply to check this against real BigQuery. If your project rejects it, declare the referenced tables in an earlier module call.

## External tables

`external_data_configuration` makes a table read files in Cloud Storage, Google Sheets or Bigtable:

```yaml
daily_orders:
  schema:                       # optional for self-describing formats
    - { name: order_id, type: STRING }
    - { name: amount, type: NUMERIC }
  external_data_configuration:
    source_format: CSV
    source_uris: ["gs://my-bucket/orders/*.csv"]
    csv_options:
      skip_leading_rows: 1
    max_bad_records: 10
```

Put the schema at table level (`schema` or `schema_file`), whatever the table kind. The provider wants it inside `external_data_configuration` when there is no `connection_id`, and at the top level when there is one; the module places it accordingly. When no schema is given, `autodetect` defaults to `true`.

| Key | Description |
|---|---|
| `source_uris` | Required. `gs://...` patterns, a Sheets URL, or a Bigtable table URI. |
| `source_format` | `CSV`, `NEWLINE_DELIMITED_JSON`, `AVRO`, `PARQUET`, `ORC`, `GOOGLE_SHEETS`, `BIGTABLE`, `DATASTORE_BACKUP`, `ICEBERG`, `DELTA_LAKE`. |
| `autodetect` | Infer the schema. Defaults to `true` without a schema, `false` with one. |
| `connection_id` | A [connection key](connections.md) or full connection ID. Makes the table a BigLake table (access through the connection's service account). |
| `metadata_cache_mode` | `AUTOMATIC` or `MANUAL` (BigLake). Combine with the table-level `max_staleness`. |
| `object_metadata` | `SIMPLE` creates an object table (one row per object). |
| `compression` | `NONE` or `GZIP`. |
| `ignore_unknown_values`, `max_bad_records` | Error tolerance. |
| `json_extension` | `GEOJSON` for GeoJSON files. |
| `reference_file_schema_uri` | File to take the schema from (AVRO, PARQUET, ORC). |
| `file_set_spec_type` | How `source_uris` are interpreted (e.g. manifest files). |
| `decimal_target_types` | Types to convert decimal values to. |
| `csv_options` | `quote` (default `"`), `field_delimiter`, `skip_leading_rows`, `encoding`, `allow_jagged_rows`, `allow_quoted_newlines`, `source_column_match`. |
| `json_options` | `encoding`. |
| `parquet_options` | `enum_as_string`, `enable_list_inference`. |
| `avro_options` | `use_avro_logical_types`. |
| `google_sheets_options` | `range`, `skip_leading_rows`. |
| `hive_partitioning_options` | `mode` (`AUTO`, `STRINGS`, `CUSTOM`), `source_uri_prefix`, `require_partition_filter`. |
| `bigtable_options` | `column_family` (list of `family_id`, `type`, `encoding`, `only_read_latest`, `column`), `ignore_unspecified_column_families`, `read_rowkey_as_string`, `output_column_families_as_json`. Each `column` takes `qualifier_string` or `qualifier_encoded`, `field_name`, `type`, `encoding`, `only_read_latest`. |

A table is either external or a BigLake managed table, not both.

## BigLake managed tables

BigLake managed tables store data in Apache Iceberg format in your bucket, while BigQuery manages the table:

```yaml
events_iceberg:
  schema: [{ name: event_id, type: STRING }, { name: payload, type: JSON }]
  biglake_configuration:
    connection_id: lake                   # connection key or full ID
    storage_uri: gs://my-lake/iceberg/events/
    file_format: PARQUET                  # default
    table_format: ICEBERG                 # default
```

The connection's service account needs write access to the storage location (see [connections.md](connections.md#granting-access-to-the-connection)).

## Deletion protection

The provider refuses to delete a table unless `deletion_protection` is `false` in the Terraform state. The module leaves the provider default (`true`) for tables and materialized views, and uses `false` for views.

To delete a protected table: set `deletion_protection: false`, apply, then remove the table from the YAML and apply again. For development configurations, set it once:

```yaml
defaults:
  tables:
    deletion_protection: false
```

`deletion_policy: PREVENT` is an additional, provider-wide safeguard, and `ABANDON` removes a table from Terraform without deleting it.

## Table IAM

```yaml
orders:
  iam:
    - role: roles/bigquery.dataViewer
      members: [serviceAccount:partner@partner-project.iam.gserviceaccount.com]
```

Each role and member pair is a `google_bigquery_table_iam_member`. The same `iam` key works on views and materialized views. See [IAM bindings](configuration.md#iam-bindings).
