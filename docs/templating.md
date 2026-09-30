# Templating and multiple environments

The module renders configuration with Terraform's [`templatefile()`](https://developer.hashicorp.com/terraform/language/functions/templatefile), so one YAML file can serve several environments, projects or teams.

## What is rendered

| Source | Rendered? | Variables available |
|---|---|---|
| `config_file` | always | `project_id` (the module's `project_id` variable) and every `template_vars` entry |
| `query_file`, `definition_file`, `schema_file` ending in **`.tftpl`** | yes | `project_id` (the resolved default project), `datasets` (dataset key → real dataset ID) and every `template_vars` entry |
| other referenced files (`.sql`, `.js`, `.json`, ...) | no, used verbatim | |
| `config_yaml` | no, used verbatim | |

A `template_vars` entry with the same name as a built-in (`project_id`, `datasets`) takes precedence.

```hcl
module "bigquery" {
  source      = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v1.0.0"
  project_id  = "analytics-prod"
  config_file = "${path.module}/bigquery.yaml"

  template_vars = {
    env            = "prod"
    protect        = true
    retention_ms   = 400 * 24 * 60 * 60 * 1000
    analysts_group = "analysts@example.com"
  }
}
```

```yaml
defaults:
  labels:
    environment: ${env}
  tables:
    deletion_protection: ${protect}        # renders to true: a YAML boolean

datasets:
  raw:
    dataset_id: raw_${env}
    default_partition_expiration_ms: ${retention_ms}
    access:
      - role: READER
        members:
          - group:${analysts_group}
```

Rendering happens before the YAML is parsed, so a placeholder can produce any YAML value: strings, numbers, booleans. `template_vars` values must be known at plan time. They decide which resources exist, so they cannot come from attributes of resources that are not created yet.

## SQL templates

A `.tftpl` file can refer to datasets by key, and gets the real, environment-specific ID:

```sql
-- sql/customers_latest.sql.tftpl
SELECT * EXCEPT (row_num)
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ingested_at DESC) AS row_num
  FROM `${project_id}.${datasets.raw}.customers`
)
WHERE row_num = 1
```

With `dataset_id: raw_${env}`, `${datasets.raw}` becomes `raw_prod` in production and `raw_dev` in development.

## Syntax and escaping

Templates support `${expression}` interpolation (any Terraform expression, e.g. `${upper(env)}` or `${retention_days * 86400000}`) and `%{ if }` / `%{ for }` directives.

| Write | To get |
|---|---|
| `$${` | a literal `${` |
| `%%{` | a literal `%{` |

This matters in three places:

- **YAML comments are rendered too.** `# uses ${env}` works, but `# see ${...}` fails to render. Write `$${...}` in comments that mention placeholders.
- **Inline JavaScript** in the YAML: template literals become `` `$${name}` ``. JavaScript in a `definition_file` without the `.tftpl` suffix needs no escaping.
- **BigQuery syntax is safe.** `@run_date`, `{run_date}` and `{run_time|"%Y%m%d"}` contain neither `${` nor `%{`.

If the template references a variable you did not pass, the plan stops with the file and line: `vars map does not contain key "env", referenced at ./bigquery.yaml:5,19-22`.

## Keep the raw file valid YAML

Editors and linters read the file *before* rendering. Placeholders stay valid YAML in these positions:

```yaml
dataset_id: raw_${env}                  # part of a plain string
deletion_protection: ${protect}         # a whole value
source_uris: ["gs://${bucket}/*.csv"]   # inside a quoted string
members:
  - group:${analysts_group}             # block-style list item
```

Avoid unquoted placeholders inside flow collections (`[ ]` and `{ }`), where `{` and `}` are syntax: write `members: [group:${g}]` in block style, or quote the item (`["group:${g}"]`). Avoid `%{ if }` directives if you want editor validation: a line starting with `%` is not valid YAML.

The [JSON Schema](../schemas/bigquery-config.schema.json) accepts `${...}` in boolean, number and enum fields, so `deletion_protection: ${protect}` is not flagged in the editor.

## One file, several environments

Use `for_each` on the module and derive the per-environment values in HCL:

```hcl
module "bigquery" {
  source   = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v1.0.0"
  for_each = var.environments                       # { dev = {...}, prod = {...} }

  project_id  = each.value.project_id
  config_file = "${path.module}/config.yaml"
  template_vars = {
    env             = each.key
    protect         = each.value.protect
    deletion_policy = each.value.protect ? "PREVENT" : "DELETE"
  }
}
```

Keep computed logic in HCL and plain `${name}` placeholders in the YAML. The file stays readable and valid YAML, and each environment's inputs are visible in one place. The [multi-environment example](../examples/multi-environment) shows the full pattern.

Alternatives:

- **One file per environment** with shared parts in YAML anchors, when environments differ structurally.
- **Generate YAML in HCL** and pass it as `config_yaml = yamlencode(local.bigquery_config)`, when the configuration is computed.
