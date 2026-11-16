# Files referenced from the YAML: tables take their schema from JSON (or YAML)
# files with schema_file, views and materialized views their SQL from SQL files
# with query_file, and routines their body with definition_file. Paths are
# relative to the configuration file.

mock_provider "google" {}

variables {
  project_id    = "test-project"
  config_file   = "tests/fixtures/project/config.yaml"
  template_vars = { env = "dev" }
}

run "tables_take_their_schema_from_files" {
  command = plan

  assert {
    condition = jsondecode(google_bigquery_table.table["sales.orders"].schema) == [
      { name = "order_id", type = "STRING", mode = "REQUIRED", description = "Primary key" },
      { name = "amount", type = "NUMERIC", precision = "12", scale = "2" },
      { name = "items", type = "RECORD", mode = "REPEATED", fields = [
        { name = "sku", type = "STRING" },
        { name = "quantity", type = "INT64" },
      ] },
      { name = "ordered_at", type = "TIMESTAMP", mode = "REQUIRED" },
    ]
    error_message = "The JSON schema file was not used as written: ${google_bigquery_table.table["sales.orders"].schema}"
  }
  assert {
    condition = jsondecode(google_bigquery_table.table["sales.customers"].schema) == [
      { name = "customer_id", type = "STRING", mode = "REQUIRED" },
      { name = "email", type = "STRING", policyTags = { names = ["projects/p/locations/eu/taxonomies/1/policyTags/2"] } },
    ]
    error_message = "A {\"fields\": [...]} schema file should give its list of fields."
  }
  assert {
    condition     = jsondecode(google_bigquery_table.table["sales.events"].schema)[0].description == "Event time in dev"
    error_message = "A .json.tftpl schema file should be rendered with template_vars."
  }
  assert {
    condition     = jsondecode(google_bigquery_table.table["sales.products"].schema) == [{ name = "sku", type = "STRING", mode = "REQUIRED" }, { name = "price", type = "NUMERIC" }]
    error_message = "A YAML schema file should be read."
  }
  assert {
    condition     = google_bigquery_table.table["sales.orders"].dataset_id == "sales_dev"
    error_message = "The table should be created in its dataset."
  }
}

run "views_take_their_sql_from_files" {
  command = plan

  assert {
    condition     = google_bigquery_table.view["reporting.revenue"].view[0].query == "SELECT DATE(ordered_at) AS day, SUM(amount) AS revenue\nFROM `test-project.sales_dev.orders`\nGROUP BY day\n"
    error_message = "A .sql.tftpl file should be rendered with project_id and the real dataset IDs: ${google_bigquery_table.view["reporting.revenue"].view[0].query}"
  }
  assert {
    condition     = google_bigquery_table.view["reporting.constant"].view[0].query == "SELECT '$${kept_as_written}' AS literal\n"
    error_message = "A .sql file should be used as written."
  }
  assert {
    condition     = google_bigquery_table.materialized_view["sales.daily_orders"].materialized_view[0].query == "SELECT DATE(ordered_at) AS day, COUNT(*) AS orders\nFROM `test-project.sales_dev.orders`\nGROUP BY day\n"
    error_message = "A materialized view should take its SQL from its file."
  }
  assert {
    condition     = google_bigquery_table.view["reporting.revenue"].view[0].use_legacy_sql == false
    error_message = "Views from files keep the view defaults."
  }
}

run "routines_take_their_body_from_files" {
  command = plan

  assert {
    condition     = google_bigquery_routine.this["sales.normalize_email"].definition_body == "LOWER(TRIM(email))\n"
    error_message = "A .sql routine file should be used as written."
  }
  assert {
    condition     = google_bigquery_routine.this["sales.orders_above"].definition_body == "SELECT order_id, amount\nFROM `test-project.sales_dev.orders`\nWHERE amount > min_amount\n"
    error_message = "A .sql.tftpl routine file should be rendered: ${google_bigquery_routine.this["sales.orders_above"].definition_body}"
  }
  assert {
    condition = (
      google_bigquery_routine.this["sales.title_case"].definition_body == "return words.map(w => `$${w[0].toUpperCase()}$${w.slice(1)}`).join(\" \");\n" &&
      google_bigquery_routine.this["sales.title_case"].language == "JAVASCRIPT"
    )
    error_message = "A .js file should be used as written, template literals included."
  }
  assert {
    condition = (
      google_bigquery_routine.this["sales.clean_orders"].routine_type == "PROCEDURE" &&
      google_bigquery_routine.this["sales.clean_orders"].definition_body == "BEGIN\n  DELETE FROM `test-project.sales_dev.orders` WHERE amount IS NULL;\nEND\n"
    )
    error_message = "A procedure body should come from its file."
  }
}

run "base_path_locates_the_files_for_config_yaml" {
  command = plan

  variables {
    config_file = null
    base_path   = "tests/fixtures/project"
    config_yaml = <<-EOT
      datasets:
        sales: {}
      tables:
        orders: { dataset: sales, schema_file: schemas/orders.json }
      views:
        constant: { dataset: sales, query_file: sql/constant.sql }
    EOT
  }

  assert {
    condition = (
      length(jsondecode(google_bigquery_table.table["sales.orders"].schema)) == 4 &&
      google_bigquery_table.view["sales.constant"].view[0].query == "SELECT '$${kept_as_written}' AS literal\n"
    )
    error_message = "With config_yaml, files should be found relative to base_path."
  }
}
