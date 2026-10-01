# Routines

Routines are user-defined functions (SQL or JavaScript), table-valued functions and stored procedures (SQL, or Apache Spark in Python, Java or Scala). They are declared in the top-level `routines` section, and each names its dataset with `dataset:`, a key under `datasets`:

```yaml
datasets:
  udfs: {}

routines:
  normalize_email:                   # routine_type defaults to SCALAR_FUNCTION
    dataset: udfs
    arguments:
      - { name: email, data_type: STRING }
    return_type: STRING
    definition_body: LOWER(TRIM(email))
```

## Keys

| Key | Type | Default | Description |
|---|---|---|---|
| `dataset` | string | required | Key of the routine's dataset under `datasets`. |
| `routine_id` | string | map key | Routine ID. |
| `routine_type` | `SCALAR_FUNCTION`, `TABLE_VALUED_FUNCTION`, `PROCEDURE` | `SCALAR_FUNCTION` | |
| `language` | `SQL`, `JAVASCRIPT`, `PYTHON`, `JAVA`, `SCALA` | BigQuery: `SQL` | Case-insensitive. |
| `definition_body` | string | | The body: for SQL functions the expression inside `AS (...)`, for procedures the `BEGIN ... END` block, for JavaScript the function body. |
| `definition_file` | path | | Read the body from a file; `*.tftpl` files are rendered. Exactly one of `definition_body` / `definition_file`, except for remote functions and Spark procedures that use `main_file_uri`. |
| `description` | string | | |
| `arguments` | list | | See [Arguments](#arguments). |
| `return_type` | [data type](#data-types) | | Required for JavaScript; optional for SQL (inferred). |
| `return_table_type` | `{columns: [{name, type}]}` or JSON string | | Output columns of a table-valued function. |
| `imported_libraries` | list | | `gs://` JavaScript libraries. |
| `determinism_level` | `DETERMINISTIC`, `NOT_DETERMINISTIC` | | JavaScript functions. |
| `data_governance_type` | `DATA_MASKING` | | Makes the function usable as a custom masking routine. |
| `security_mode` | `DEFINER`, `INVOKER` | | |
| `remote_function_options` | mapping | | See [Remote functions](#remote-functions). |
| `spark_options` | mapping | | See [Spark procedures](#spark-procedures). |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | | |
| `iam` | list | | [IAM bindings](configuration.md#iam-bindings) on the routine. |

## Arguments

```yaml
arguments:
  - name: email
    data_type: STRING
  - name: tags
    data_type: { typeKind: ARRAY, arrayElementType: { typeKind: STRING } }
  - name: anything
    argument_kind: ANY_TYPE                # templated SQL function argument
  - name: removed
    data_type: INT64
    mode: OUT                              # procedures: IN, OUT, INOUT
  - name: events
    argument_kind: FIXED_TABLE             # table parameter of a table function
    table_type:
      columns:
        - { name: id, type: STRING }
        - { name: ts, type: TIMESTAMP }
```

| Key | Description |
|---|---|
| `name` | Argument name. Quote names YAML reads as booleans (`name: "y"`). |
| `data_type` | A [data type](#data-types). Required unless `argument_kind` is `ANY_TYPE` or `FIXED_TABLE`. |
| `argument_kind` | `FIXED_TYPE` (default), `ANY_TYPE`, `FIXED_TABLE`. |
| `mode` | `IN`, `OUT`, `INOUT` (procedures only). |
| `table_type` | `{columns: [{name, type}]}` for `FIXED_TABLE` arguments. |

## Data types

BigQuery describes types as `StandardSqlDataType` JSON. Every type field in the YAML (`data_type`, `return_type`, column `type`) accepts three spellings, which the module converts:

| You write | The provider receives |
|---|---|
| `INT64` (any case) | `{"typeKind":"INT64"}` |
| `INTEGER`, `INT`, `FLOAT`, `BOOLEAN`, `DECIMAL`, `BIGDECIMAL` | mapped to `INT64`, `INT64`, `FLOAT64`, `BOOL`, `NUMERIC`, `BIGNUMERIC` |
| a mapping, e.g. `{ typeKind: ARRAY, arrayElementType: { typeKind: STRING } }` | the mapping as JSON |
| a JSON string, e.g. `'{"typeKind":"STRING"}'` | the string as written |

Structs are mappings too:

```yaml
return_type:
  typeKind: STRUCT
  structType:
    fields:
      - { name: id, type: { typeKind: STRING } }
      - { name: amount, type: { typeKind: NUMERIC } }
```

## Table-valued functions

```yaml
routines:
  orders_above:
    dataset: sales
    routine_type: TABLE_VALUED_FUNCTION
    arguments:
      - { name: min_amount, data_type: NUMERIC }
    definition_body: |
      SELECT order_id, amount
      FROM `${project_id}.sales.orders`
      WHERE amount > min_amount
    return_table_type:
      columns:
        - { name: order_id, type: STRING }
        - { name: amount, type: NUMERIC }
```

A table function can be [authorized](authorized-views.md) on the dataset it reads, just like a view.

## Procedures

```yaml
routines:
  archive_cancelled_orders:
    dataset: sales
    routine_type: PROCEDURE
    arguments:
      - { name: older_than_days, data_type: INT64, mode: IN }
      - { name: archived, data_type: INT64, mode: OUT }
    definition_file: sql/archive_cancelled_orders.sql.tftpl
```

The file holds the `BEGIN ... END` block. Call the procedure with `CALL sales.archive_cancelled_orders(30, archived)`, for example from a [scheduled query](transfers.md).

## JavaScript functions

```yaml
routines:
  title_case:
    dataset: udfs
    language: JAVASCRIPT
    arguments: [{ name: s, data_type: STRING }]
    return_type: STRING
    determinism_level: DETERMINISTIC
    imported_libraries: [gs://my-libs/lodash.min.js]
    definition_file: js/title_case.js
```

JavaScript template literals (`` `${x}` ``) are safe in files that do not end in `.tftpl`, which are sent verbatim. Inline in the YAML, which is always rendered, write them as `$${x}`.

## Remote functions

A remote function calls an HTTP endpoint (Cloud Run or Cloud Functions) through a connection:

```yaml
connections:
  remote:
    cloud_resource: {}

datasets:
  udfs: {}

routines:
  detect_language:
    dataset: udfs
    arguments: [{ name: text, data_type: STRING }]
    return_type: STRING
    remote_function_options:
      endpoint: https://detect-language-abc123-uc.a.run.app
      connection: remote              # connection key, or full connection name
      max_batching_rows: 50
      user_defined_context: { model: fast }
```

Grant the connection's service account (`module.bigquery.connections["remote"].service_account_id`) `roles/run.invoker` on the service. `definition_body` stays empty for remote functions.

## Spark procedures

```yaml
connections:
  spark:
    spark: {}

datasets:
  lake: {}

routines:
  compact_small_files:
    dataset: lake
    routine_type: PROCEDURE
    language: PYTHON
    spark_options:
      connection: spark
      runtime_version: "2.1"
      main_file_uri: gs://my-bucket/jobs/compact.py
      properties: { spark.executor.instances: "2" }
```

`spark_options` keys: `connection`, `runtime_version`, `container_image`, `properties`, `main_file_uri`, `main_class`, `py_file_uris`, `jar_uris`, `file_uris`, `archive_uris`. For PySpark code in `definition_body` / `definition_file`, leave out `main_file_uri`.
