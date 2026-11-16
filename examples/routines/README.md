# Routines

Every kind of routine in one `udfs` dataset. Each body is a file in `routines/`, referenced with `definition_file`: `.sql` for SQL, `.sql.tftpl` for SQL that uses `${project_id}`, `.js` for JavaScript.

| Routine | Kind | Shows |
|---|---|---|
| `normalize_email` | SQL scalar function | Simple type names (`data_type: STRING`) |
| `split_tags` | SQL scalar function | An `ARRAY<STRING>` return type as a mapping |
| `order_summary` | SQL scalar function | A `STRUCT` return type |
| `title_case` | JavaScript function | Body from `routines/title_case.js` (JavaScript template literals stay untouched), `determinism_level` |
| `orders_above` | Table-valued function | `return_table_type` columns |
| `archive_cancelled_orders` | Procedure | `IN` and `OUT` arguments, body from `routines/archive_cancelled_orders.sql.tftpl`, routine IAM |
| `mask_email` | SQL function | `data_governance_type: DATA_MASKING` |
| `detect_language` | Remote function | Calls a Cloud Run service through the `remote` connection, referenced by key |

## Run

```bash
terraform init
terraform apply -var project_id=my-project \
  -var language_service_url=https://detect-language-xyz-uc.a.run.app
```

Prerequisites:

- The BigQuery Connection API is enabled, for the `remote` connection.
- The Cloud Run service exists. After apply, grant the connection's service account (output `remote_connection_service_account`) `roles/run.invoker` on it.
- The routine IAM grant goes to `group:data-engineers@example.com`; change it to a group that exists.

## Try it

```sql
SELECT udfs.normalize_email('  Jane@Example.COM ');           -- jane@example.com
SELECT udfs.split_tags('a, b,,a');                             -- [a, b]
SELECT * FROM udfs.orders_above(100);
DECLARE n INT64; CALL udfs.archive_cancelled_orders(30, n); SELECT n;
```
