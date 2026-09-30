# Multiple environments

One `config.yaml`, deployed to a dev and a prod project with `for_each` on the module. The differences between environments live in `var.environments` and the `template_vars` derived from it:

| Setting | dev | prod |
|---|---|---|
| Dataset IDs | `raw_dev`, `curated_dev` | `raw_prod`, `curated_prod` |
| Table deletion protection | off | on |
| `delete_contents_on_destroy` | true | false |
| Dataset `deletion_policy` | `DELETE` | `PREVENT` |
| Raw partition retention | 7 days | 400 days |
| Analyst group | `analysts-dev@...` | `analysts@...` |

Within each environment, the `curated.customers` view reads `raw.customers` through `${project_id}.${datasets.raw}` in `sql/customers_latest.sql.tftpl`. The `raw` dataset authorizes the whole `curated` dataset, so analysts need no access to raw data.

## Run

```bash
terraform init
terraform apply -var 'environments={
  dev  = { project_id = "my-dev-project",  location = "US", protect = false, raw_retention_days = 7,   analysts_group = "analysts-dev@your-domain.com" }
  prod = { project_id = "my-prod-project", location = "US", protect = true,  raw_retention_days = 400, analysts_group = "analysts@your-domain.com" }
}'
```

or put the map in a `terraform.tfvars` file. The credentials need access to both projects.

Destroying prod fails by design (`deletion_policy: PREVENT`, deletion protection on tables). Set `protect = false` and apply before destroying.

See [docs/templating.md](../../docs/templating.md).
