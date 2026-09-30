# Views and materialized views

```yaml
datasets:
  reporting:
    views:
      revenue_by_country:
        description: Revenue per country.
        query: |
          SELECT country, SUM(amount) AS revenue
          FROM `${project_id}.sales.orders`
          GROUP BY country
      customers:
        query_file: sql/customers.sql.tftpl
    materialized_views:
      daily_revenue:
        query: |
          SELECT DATE(ordered_at) AS day, SUM(amount) AS revenue
          FROM `${project_id}.sales.orders`
          GROUP BY day
        refresh_interval_ms: 1800000
```

## View keys

| Key | Type | Default | Description |
|---|---|---|---|
| `table_id` | string | map key | View ID. |
| `query` | string | | GoogleSQL query. Exactly one of `query` / `query_file`. |
| `query_file` | path | | SQL file; `*.tftpl` files are template-rendered ([templating.md](templating.md)). |
| `use_legacy_sql` | bool | `false` | Use legacy SQL. |
| `friendly_name`, `description` | string | | |
| `labels` | map | | Merged with the default labels. |
| `expiration_time` | number | | Expiry time in milliseconds since the epoch. |
| `deletion_protection` | bool | `false` | Views hold no data, so the module does not protect them by default. |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | | Provider deletion policy. |
| `resource_tags` | map | | Resource Manager tags. |
| `iam` | list | | [IAM bindings](configuration.md#iam-bindings) on the view. |

Changing a view's query is an in-place update.

## Materialized view keys

| Key | Type | Default | Description |
|---|---|---|---|
| `table_id` | string | map key | Materialized view ID. |
| `query` / `query_file` | string / path | | Exactly one is required. |
| `enable_refresh` | bool | `true` (BigQuery) | Refresh automatically when base tables change. |
| `refresh_interval_ms` | number | 1800000 (BigQuery) | Maximum refresh frequency. |
| `allow_non_incremental_definition` | bool | | Allow queries that cannot refresh incrementally (requires `max_staleness`). |
| `max_staleness` | string | | INTERVAL literal, e.g. `"0-0 0 4:0:0"`. |
| `time_partitioning`, `range_partitioning`, `clustering` | | | As for [tables](tables.md#partitioning-and-clustering); partition on a base-table partitioning column. |
| `encryption_configuration` | `{kms_key_name}` | | |
| `friendly_name`, `description`, `labels`, `expiration_time`, `resource_tags` | | | As for views. |
| `deletion_protection` | bool | provider default (`true`) | A rebuild costs a full scan, so materialized views are protected like tables. |
| `deletion_policy` | | | |
| `iam` | list | | IAM bindings. |

## Creation order

BigQuery checks a view's query when the view is created, so everything it selects from must exist first. The module creates resources in this order:

1. datasets
2. tables
3. materialized views (they read tables)
4. routines (UDFs and table functions may read tables and materialized views)
5. views (may read tables, materialized views and call routines)
6. authorized views, datasets and routines
7. transfers

So views may use tables, materialized views and UDFs from the same configuration in any dataset.

## Views on views

Views inside one configuration are created in parallel, so a view that selects from **another view in the same configuration** may be created first and rejected by BigQuery (`Not found: Table ...`).

Put each layer in its own YAML file and module call, chained with `depends_on`:

```hcl
module "base" {
  source      = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v1.0.0"
  project_id  = var.project_id
  config_file = "${path.module}/base.yaml"      # tables and first-level views
}

module "marts" {
  source      = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v1.0.0"
  project_id  = var.project_id
  config_file = "${path.module}/marts.yaml"     # views over base views
  depends_on  = [module.base]
}
```

The second file can still reference datasets from the first with `create: false`, for example to authorize its views on them. See the [layered-views example](../examples/layered-views).

## SQL tips

- Refer to tables with fully qualified names (`` `project.dataset.table` ``). With templating, write `` `${project_id}.sales.orders` `` in the YAML, or `` `${project_id}.${datasets.sales}.orders` `` in a `.tftpl` file so dataset ID overrides are followed.
- Use YAML block scalars (`query: |`) for multi-line SQL; no escaping is needed.
- A `query_file` that is not a `.tftpl` file is sent verbatim, including any `${...}` it contains.
