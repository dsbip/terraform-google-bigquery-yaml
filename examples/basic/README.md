# Basic

The smallest useful configuration: dataset `sales` with a `customers` table, a daily-partitioned and clustered `orders` table, a `revenue_by_country` view, and read access for the project's readers.

It also shows templating: the view SQL uses `${project_id}`, which the module fills in from its `project_id` variable.

## Run

```bash
terraform init
terraform apply -var project_id=my-project
```

Needs only the BigQuery API. Everything is destroyable (`terraform destroy -var project_id=my-project`), because the configuration turns off table deletion protection.

## Files

| File | Contents |
|---|---|
| `main.tf` | Provider and module call |
| `config.yaml` | The BigQuery configuration |

## Creates

| Resource | Name |
|---|---|
| Dataset | `sales` |
| Tables | `sales.customers`, `sales.orders` (partitioned by `ordered_at`, clustered by `customer_id`) |
| View | `sales.revenue_by_country` |
| Access grant | `READER` for `projectReaders` on `sales` |
