# Configuration

This page covers the rules that apply to the whole YAML file. The pages for each resource type list their keys: [datasets](datasets.md), [tables](tables.md), [views](views.md), [authorized views](authorized-views.md), [routines](routines.md), [connections](connections.md), [transfers](transfers.md).

- [File layout](#file-layout)
- [Keys and IDs](#keys-and-ids)
- [Projects](#projects)
- [Defaults](#defaults)
- [Locations](#locations)
- [Labels](#labels)
- [Empty values](#empty-values)
- [References](#references)
- [Files referenced from the YAML](#files-referenced-from-the-yaml)
- [Secrets](#secrets)
- [IAM bindings](#iam-bindings)
- [Editor support](#editor-support)

## File layout

```yaml
project_id: my-project        # optional: default project for this file

defaults:                     # optional: values for every resource of a type
  location: EU
  labels: { team: data }
  datasets: { ... }
  tables: { ... }
  views: { ... }
  materialized_views: { ... }
  routines: { ... }
  connections: { ... }
  transfers: { ... }

connections:                  # BigQuery connections, by key
  <connection key>: { ... }

datasets:                     # datasets, by key
  <dataset key>:
    ...                       # dataset settings
    access: [ ... ]           # access grants
    authorized_views: [ ... ]
    authorized_datasets: [ ... ]
    authorized_routines: [ ... ]
    tables:              { <table key>: { ... } }
    views:               { <view key>: { ... } }
    materialized_views:  { <view key>: { ... } }
    routines:            { <routine key>: { ... } }

transfers:                    # Data Transfer Service configs, by key
  <transfer key>: { ... }
```

Every section is optional. A file with only comments is valid and creates nothing.

## Keys and IDs

Collections are **mappings**, not lists. The key is the name you use inside the file and in Terraform resource addresses. By default it is also the BigQuery ID:

| Collection | ID key (defaults to the map key) | Terraform address |
|---|---|---|
| `datasets.<k>` | `dataset_id` | `google_bigquery_dataset.this["<k>"]` |
| `datasets.<d>.tables.<k>` | `table_id` | `google_bigquery_table.table["<d>.<k>"]` |
| `datasets.<d>.views.<k>` | `table_id` | `google_bigquery_table.view["<d>.<k>"]` |
| `datasets.<d>.materialized_views.<k>` | `table_id` | `google_bigquery_table.materialized_view["<d>.<k>"]` |
| `datasets.<d>.routines.<k>` | `routine_id` | `google_bigquery_routine.this["<d>.<k>"]` |
| `connections.<k>` | `connection_id` | `google_bigquery_connection.this["<k>"]` |
| `transfers.<k>` | `display_name` | `google_bigquery_data_transfer_config.this["<k>"]` |

Setting the ID explicitly lets the key stay stable while the ID varies, for example per environment:

```yaml
datasets:
  raw:                    # referenced as "raw" everywhere in this file
    dataset_id: raw_${env}
```

Consequences:

- **Renaming a key** changes the Terraform address, so Terraform destroys and recreates the resource. Use a [`moved` block](https://developer.hashicorp.com/terraform/language/moved) in your root module to keep it, e.g. `from = module.bigquery.google_bigquery_table.table["sales.orders"]`.
- **Changing an ID** replaces the resource in BigQuery (IDs cannot be changed in place).
- Tables, views and materialized views share one namespace per dataset, so their keys must be distinct within a dataset.
- Quote keys that YAML would read as booleans (`yes`, `no`, `on`, `off`, `y`, `n`, `true`, `false`): `"on": {}`. Unquoted, they become `true`/`false`, and the module rejects them.

## Projects

Every resource gets a project, resolved in this order:

1. `project_id` on the dataset, connection or transfer (tables, views, materialized views and routines use their dataset's project)
2. `project_id` at the top of the YAML file
3. the module's `project_id` variable

If none is set, validation fails and lists the resources without a project.

## Defaults

`defaults.<type>` holds values for every resource of that type. A value on the resource replaces the default. The merge is shallow: a resource's `time_partitioning` replaces the whole default `time_partitioning`. There are two exceptions:

- **labels** are merged (see [Labels](#labels)).
- **`defaults.datasets.access`** is *prepended* to every dataset's own `access` list. A grant that appears in both is created once.

```yaml
defaults:
  location: EU
  datasets:
    delete_contents_on_destroy: false
    access:
      - role: READER
        members: [group:data-platform@example.com]
  tables:
    deletion_protection: true
  views:
    use_legacy_sql: false
  transfers:
    email_preferences: { enable_failure_email: true }
```

Keys that identify or define a single resource cannot be defaults, and validation rejects them:

| Section | Not allowed as a default |
|---|---|
| `defaults.datasets` | `dataset_id`, `project_id`, `create`, `tables`, `views`, `materialized_views`, `routines`, `authorized_views`, `authorized_datasets`, `authorized_routines` |
| `defaults.tables` | `table_id`, `schema`, `schema_file` |
| `defaults.views`, `defaults.materialized_views` | `table_id`, `query`, `query_file` |
| `defaults.routines` | `routine_id`, `definition_body`, `definition_file` |
| `defaults.connections` | `connection_id` and the type keys (`cloud_resource`, `cloud_sql`, ...) |
| `defaults.transfers` | `display_name`, `query`, `query_file` |

The module has a few defaults of its own, applied underneath yours:

| Resource | Module default |
|---|---|
| views | `use_legacy_sql: false`, `deletion_protection: false` (a view holds no data) |
| routines | `routine_type: SCALAR_FUNCTION` |
| `time_partitioning` | `type: DAY` |
| external tables | `autodetect: true` when no schema is given, otherwise `false`; CSV `quote: '"'` |
| `biglake_configuration` | `file_format: PARQUET`, `table_format: ICEBERG` |
| authorized datasets | `target_types: [VIEWS]` |

Tables and materialized views keep the provider default `deletion_protection: true`. Set `defaults.tables.deletion_protection: false` in development configurations that you intend to destroy.

## Locations

| Resource | Location, first one set wins |
|---|---|
| datasets | `location` → `defaults.datasets.location` → `defaults.location` → provider default (US) |
| connections | `location` → `defaults.connections.location` → `defaults.location` → provider default |
| transfers | `location` → the destination dataset's location (when the dataset is in this file) → `defaults.transfers.location` → `defaults.location` → provider default (US) |
| tables, views, routines | their dataset's location |

## Labels

Datasets, tables, views and materialized views get labels merged from, lowest to highest priority:

1. the module's `labels` variable
2. `defaults.labels`
3. `defaults.<type>.labels`
4. the resource's own `labels`

Tables do not inherit their dataset's labels. Numbers and booleans are converted to strings.

## Empty values

A key with no value (`description:`) counts as not set: the default applies, if there is one. This lets templates leave values empty. To send an explicit empty string, quote it (`default_collation: ""`).

## References

Several settings refer to other resources. They accept keys from this file, and the module turns them into real IDs:

| Setting | Accepts |
|---|---|
| `connection_id` (external/BigLake tables), `connection` (remote functions, Spark, external datasets) | a connection key, or a full ID: `project.location.id` / `projects/P/locations/L/connections/C` |
| `authorized_views`, `authorized_routines`, `table_constraints.foreign_keys[].referenced_table` | `"dataset.name"`, `"project.dataset.name"` or `{project_id, dataset_id, table_id / routine_id}` |
| `authorized_datasets` | `"dataset"`, `"project.dataset"` or `{project_id, dataset_id, target_types}` |
| `transfers.*.destination_dataset_id` | a dataset key, or a dataset ID |

For `"dataset.name"` references, the module first looks for a view, routine or table with that key in this file and uses its real IDs. Otherwise, if `dataset` is a dataset key, it uses that dataset's real IDs. Otherwise it uses the reference as written, in the project of the dataset that contains it. Domain-scoped projects (`example.com:my-project.dataset.view`) work.

## Files referenced from the YAML

| Setting | File contents |
|---|---|
| `schema_file` | A table schema: a JSON or YAML list of fields |
| `query_file` | View, materialized view or transfer SQL |
| `definition_file` | Routine body (SQL, JavaScript, ...) |

Relative paths are resolved against the directory of `config_file`, or `base_path` when set (required when you use `config_yaml` and the files are not under `path.root`).

Files are used verbatim, except files whose name ends in **`.tftpl`**. Those are rendered with `templatefile()` and can use `${project_id}`, `${datasets.<key>}` (the dataset's real ID) and every `template_vars` entry. See [templating.md](templating.md).

## Secrets

Credentials never belong in YAML. Pass them in the `secrets` variable (marked sensitive) and reference them by name:

```hcl
secrets = {
  orders_db_password = var.orders_db_password
}
```

```yaml
connections:
  orders_db:
    cloud_sql:
      credential:
        username: bq_reader
        password_secret: orders_db_password
```

| YAML setting | Used for |
|---|---|
| `connections.*.cloud_sql.credential.password_secret` | Cloud SQL password |
| `connections.*.configuration.authentication.username_password.password_secret` | Connector framework password |
| `transfers.*.sensitive_params.secret_access_key_secret` | AWS secret access key (Amazon S3 transfers) |

The values are sent to the provider as sensitive arguments and are stored in Terraform state, as with any provider secret. Protect your state accordingly.

## IAM bindings

Tables, views, materialized views, routines and connections accept an `iam` list. Each entry grants one role to one or more members:

```yaml
iam:
  - role: roles/bigquery.dataViewer
    members:
      - group:analysts@example.com
      - serviceAccount:reporting@my-project.iam.gserviceaccount.com
    condition:                    # optional IAM condition
      title: until-2027
      expression: request.time < timestamp("2027-01-01T00:00:00Z")
      description: Temporary access
```

| Key | Required | Description |
|---|---|---|
| `role` | yes | IAM role |
| `members` | yes | IAM members: `user:`, `group:`, `serviceAccount:`, `domain:`, `principal://`, `principalSet://`, `allUsers`, `allAuthenticatedUsers` |
| `condition` | no | `title` and `expression` are required; `description` is optional |

Each role and member pair becomes one `google_bigquery_*_iam_member` resource, so bindings are **non-authoritative**: members granted outside this configuration are kept.

Datasets use `access` instead, which has the same shape. See [datasets.md](datasets.md#access-grants).

## Editor support

[`schemas/bigquery-config.schema.json`](../schemas/bigquery-config.schema.json) describes the file format (JSON Schema draft-07). Reference it from the first line of your YAML file:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/dsbip/terraform-google-bigquery-yaml/v1.0.0/schemas/bigquery-config.schema.json
```

VS Code (with the Red Hat YAML extension) and JetBrains IDEs then offer completion, show descriptions on hover and underline unknown keys and invalid values. Template placeholders such as `${protect}` are accepted in boolean, number and enum fields.

The module reads the same schema file to decide which keys are allowed, so the editor and `terraform plan` never disagree.
