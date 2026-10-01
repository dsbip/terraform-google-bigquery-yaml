# Troubleshooting

- [YAML pitfalls](#yaml-pitfalls)
- [Templating errors](#templating-errors)
- [Plan errors](#plan-errors)
- [Apply errors](#apply-errors)
- [Destroy errors](#destroy-errors)
- [Unexpected changes in plans](#unexpected-changes-in-plans)

## YAML pitfalls

### YAML booleans

Terraform's YAML parser follows YAML 1.1, where these unquoted words are booleans: `y`, `n`, `yes`, `no`, `on`, `off`, `true`, `false`. Editors use YAML 1.2 and show them as strings, so the problem is invisible there.

```yaml
datasets:
  on: {}                         # becomes the key "true"
  sales:

tables:
  t:
    dataset: sales
    schema:
      - { name: n, type: STRING }   # column name becomes false
```

The module rejects keys and names that became booleans:

```
datasets.true: YAML read this key as a boolean; quote it (e.g. "on":) ...
tables.t.schema[0].name: YAML read this name as the boolean false; quote it ...
```

Quote them: `"on": {}`, `name: "n"`. Values elsewhere, such as descriptions and labels, are converted back to `"true"` / `"false"` strings, which may not be what you meant. Quote those too.

### Tabs

YAML allows only spaces for indentation. Text pasted from some editors, chats or spreadsheets is indented with tabs, and the file then fails to parse. The module names the lines:

```
The YAML cannot be parsed: tabs are used for indentation on lines 12, 13, 14. YAML allows only spaces; replace the tabs with spaces.
```

In VS Code, *Convert Indentation to Spaces* in the command palette fixes the whole file. Tabs inside a block scalar (for example in SQL under `query: |`) are content and are fine.

### Duplicate keys

Terraform's YAML parser keeps only the last of two equal keys and drops the other without a word. This is easy to hit when two datasets have tables with the same name:

```yaml
tables:
  orders:
    dataset: raw
  orders:              # replaces the raw table above
    dataset: staging
```

The module checks the file for duplicate keys before using it, and fails the plan instead:

```
tables.orders: defined on lines 2 and 4; YAML keeps only the last one. Keys must be unique within tables; rename the others (table_id sets the BigQuery ID independently of the key)
```

Give the second one its own key and keep the table name with `table_id`:

```yaml
tables:
  orders:
    dataset: raw
  staging_orders:
    dataset: staging
    table_id: orders
```

The check covers top-level sections and the entries of `datasets`, `tables`, `views`, `materialized_views`, `routines`, `connections` and `transfers` written in block style. Line numbers refer to the file after template rendering.

### Braces

`{` and `}` start a mapping in *flow* style. A value that begins with `{`, or a value inside `[ ]` or `{ }`, must be quoted when it contains braces:

```yaml
params:
  destination_table_name_template: daily_{run_date}       # fine: block style, does not start with {
params: { destination_table_name_template: "daily_{run_date}" }   # quoted inside { }
```

The error for an unquoted value is `did not find expected ',' or '}'`, with the line and column.

### Multi-line SQL

Use a block scalar and indent the SQL under it:

```yaml
query: |
  SELECT ...
  FROM `project.dataset.table`
```

## Templating errors

| Error | Cause | Fix |
|---|---|---|
| `vars map does not contain key "x"` | `${x}` in the YAML, or in a `.tftpl` file, has no value | Pass `x` in `template_vars`, or write `$${x}` for a literal |
| `Invalid expression ... found an invalid expression token` | `${...}` with something that is not an expression, often in a comment | Write `$${...}` |
| `Invalid template interpolation value ... null` | A template variable is `null` (e.g. `project_id` not set) | Set the variable |
| `The "for_each" map includes keys derived from resource attributes that cannot be determined until apply` | A `template_vars` value comes from a resource created in the same apply | Use a value known at plan time, or apply that resource first |

Comments are rendered too, and JavaScript template literals in the YAML need `$${...}`. See [templating.md](templating.md#syntax-and-escaping).

## Plan errors

**`The BigQuery YAML configuration has N problem(s)`.** The configuration is invalid. Each line starts with the YAML path; see [validation.md](validation.md).

**`datasets.<key>.tables: tables are not nested in datasets`** (or `views`, `materialized_views`, `routines`). The file uses the v1 layout. Move each entry to the top-level section and add `dataset: <key>`; see [upgrading.md](upgrading.md).

**`tables.<key>.dataset: is required`.** Every table, view, materialized view and routine names its dataset. `defaults` cannot supply it.

**`Invalid value for variable ... config_file must point to an existing file`.** Relative paths in `config_file` are relative to the directory Terraform runs in. Use `"${path.module}/config.yaml"`.

**`Unsupported argument` or `Invalid block type` inside the module.** The Google provider is older than 7.42. Run `terraform init -upgrade` with a constraint that allows `>= 7.42.0`.

**`Unsupported Terraform Core version`.** Terraform must be 1.5 or newer.

## Apply errors

**`Not found: Table my-project:reporting.base_view` when creating a view.** The view selects from another view created in the same apply. Views in one configuration are created in parallel, so put the dependent views in a second module call with `depends_on` ([views.md](views.md#views-on-views)).

**`Not found: Dataset` or `Table` for a view, routine or scheduled query.** The SQL refers to a dataset by its key instead of its real ID (after a `dataset_id` override), or to the wrong project. Use `${project_id}.${datasets.<key>}` in a `.tftpl` file.

**`Access Denied: ... bigquery.datasets.update` on an authorization.** The source dataset belongs to another project or team, and your identity cannot change its access list. Ask its owner, or have them add the authorization.

**`SERVICE_DISABLED` / `API has not been used in project`.** Enable `bigqueryconnection.googleapis.com` for connections or `bigquerydatatransfer.googleapis.com` for transfers.

**BigLake or object table queries fail with `Permission denied` on Cloud Storage.** Grant the connection's service account (`connections.<key>.service_account_id` output) read access to the bucket ([connections.md](connections.md#granting-access-to-the-connection)).

**Scheduled query creation fails with a permission error.** The identity creating it must be able to run the query. With `service_account_name`, you need `roles/iam.serviceAccountUser` on that service account, and the service account needs access to the data.

**`Location ... does not match`.** The transfer's location differs from its destination dataset. Set `destination_dataset_id` to the dataset's key so the location is taken from it, or set `location` explicitly.

## Destroy errors

**`cannot destroy table ... without setting deletion_protection=false`.** Tables and materialized views are protected by default:
1. Set `deletion_protection: false` on the table, or in `defaults.tables`.
2. Apply.
3. Destroy.

**`Dataset ... is still in use`.** The dataset contains tables that Terraform does not manage. Set `delete_contents_on_destroy: true` if they may be deleted.

**`deletion_policy is set to PREVENT`.** Intended protection. Change it to `DELETE` and apply first.

## Unexpected changes in plans

**A schema diff on every plan.** Write the schema the way BigQuery returns it:
- `RECORD`, not `STRUCT`; `NUMERIC`, not `DECIMAL`;
- `maxLength`, `precision` and `scale` as quoted strings;
- only field keys that BigQuery keeps.

**Access grants replaced after changing a role's spelling.** `roles/bigquery.dataViewer` and `READER` are the same grant and share one key, but changing to a role that is really different (e.g. `READER` → `WRITER`) replaces the grant.

**A resource destroyed and recreated after renaming a key.** Keys are Terraform addresses. Add a `moved` block, e.g.:

```hcl
moved {
  from = module.bigquery.google_bigquery_table.table["sales.orders"]
  to   = module.bigquery.google_bigquery_table.table["sales.orders_v2"]
}
```

**Labels added outside Terraform are kept.** Label fields are non-authoritative in the Google provider: only the labels in your configuration are managed.

**The editor flags `${...}` placeholders.** Reload the window after updating the schema. Placeholders are accepted in boolean, number and enum fields; elsewhere they are plain strings.
