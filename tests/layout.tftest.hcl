# Layout: tables, views, materialized views and routines are top-level sections
# whose entries name their dataset (dataset: <key>), and other entries can
# reference them by key.

mock_provider "google" {}

variables {
  project_id = "test-project"
}

run "children_take_project_and_dataset_from_their_dataset" {
  command = plan

  variables {
    config_yaml = <<-EOT
      # Sections may appear in any order, before or after datasets.
      tables:
        events:
          dataset: raw
        raw_orders:
          dataset: raw
          table_id: orders
        orders:
          dataset: mart

      datasets:
        raw:
          project_id: ingest-project
          dataset_id: raw_prod
        mart: {}
        legacy:
          create: false
          dataset_id: legacy_ds

      views:
        orders_v:
          dataset: mart
          query: SELECT 1
        legacy_v:
          dataset: legacy
          query: SELECT 1

      materialized_views:
        daily:
          dataset: mart
          query: SELECT 1

      routines:
        clean:
          dataset: raw
          definition_body: x
    EOT
  }

  assert {
    condition     = toset(keys(google_bigquery_table.table)) == toset(["raw.events", "raw.raw_orders", "mart.orders"])
    error_message = "Tables should be keyed \"<dataset key>.<key>\": ${jsonencode(keys(google_bigquery_table.table))}"
  }
  assert {
    condition = (
      google_bigquery_table.table["raw.raw_orders"].project == "ingest-project" &&
      google_bigquery_table.table["raw.raw_orders"].dataset_id == "raw_prod" &&
      google_bigquery_table.table["raw.raw_orders"].table_id == "orders" &&
      google_bigquery_table.table["mart.orders"].project == "test-project" &&
      google_bigquery_table.table["mart.orders"].dataset_id == "mart" &&
      google_bigquery_table.table["mart.orders"].table_id == "orders"
    )
    error_message = "Tables should take project and dataset ID from their dataset; two datasets may both have an orders table."
  }
  assert {
    condition = (
      google_bigquery_table.view["mart.orders_v"].dataset_id == "mart" &&
      google_bigquery_table.view["legacy.legacy_v"].dataset_id == "legacy_ds" &&
      google_bigquery_table.materialized_view["mart.daily"].dataset_id == "mart" &&
      google_bigquery_routine.this["raw.clean"].project == "ingest-project" &&
      google_bigquery_routine.this["raw.clean"].dataset_id == "raw_prod"
    )
    error_message = "Views, materialized views and routines should take their IDs from their dataset (including create: false datasets)."
  }
  assert {
    condition     = toset(keys(google_bigquery_dataset.this)) == toset(["raw", "mart"])
    error_message = "Only datasets with create: true should be created."
  }
  assert {
    condition = (
      toset(keys(output.tables)) == toset(["raw.events", "raw.raw_orders", "mart.orders"]) &&
      toset(keys(output.views)) == toset(["mart.orders_v", "legacy.legacy_v"]) &&
      toset(keys(output.materialized_views)) == toset(["mart.daily"]) &&
      toset(keys(output.routines)) == toset(["raw.clean"])
    )
    error_message = "Outputs should use the same keys as the resources."
  }
}

run "references_by_key" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        shop:
          dataset_id: shop_prod
        private:
          authorized_views:
            - orders_v        # view key
            - daily_mv        # materialized view key
            - shop.orders_v   # the same view as "<dataset key>.<key>"
          authorized_routines:
            - top_customers   # routine key

      tables:
        customers:
          dataset: shop
          table_id: customers_v2
          table_constraints:
            primary_key: { columns: [id] }
        orders:
          dataset: shop
          table_constraints:
            foreign_keys:
              - referenced_table: customers   # table key
                column_references: { referencing_column: customer_id, referenced_column: id }

      views:
        orders_v:
          dataset: shop
          table_id: orders_view
          query: SELECT 1

      materialized_views:
        daily_mv:
          dataset: shop
          query: SELECT 1

      routines:
        top_customers:
          dataset: shop
          routine_type: TABLE_VALUED_FUNCTION
          definition_body: SELECT 1 AS x
    EOT
  }

  assert {
    condition = toset(keys(google_bigquery_dataset_access.authorized_view)) == toset([
      "private|test-project.shop_prod.orders_view",
      "private|test-project.shop_prod.daily_mv",
    ])
    error_message = "View keys should resolve to real IDs, and duplicates collapse: ${jsonencode(keys(google_bigquery_dataset_access.authorized_view))}"
  }
  assert {
    condition     = toset(keys(google_bigquery_dataset_access.authorized_routine)) == toset(["private|test-project.shop_prod.top_customers"])
    error_message = "A routine key should resolve to its real IDs."
  }
  assert {
    condition = (
      google_bigquery_table.table["shop.orders"].table_constraints[0].foreign_keys[0].referenced_table[0].project_id == "test-project" &&
      google_bigquery_table.table["shop.orders"].table_constraints[0].foreign_keys[0].referenced_table[0].dataset_id == "shop_prod" &&
      google_bigquery_table.table["shop.orders"].table_constraints[0].foreign_keys[0].referenced_table[0].table_id == "customers_v2"
    )
    error_message = "A table key in referenced_table should resolve to the table's real IDs."
  }
}

run "a_view_and_a_materialized_view_may_share_a_key_across_datasets" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        a: {}
        b: {}
        private:
          authorized_views: [a.x, b.x]
      views:
        x: { dataset: a, query: SELECT 1 }
      materialized_views:
        x: { dataset: b, query: SELECT 1 }
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.view["a.x"].dataset_id == "a" &&
      google_bigquery_table.materialized_view["b.x"].dataset_id == "b" &&
      toset(keys(google_bigquery_dataset_access.authorized_view)) == toset(["private|test-project.a.x", "private|test-project.b.x"])
    )
    error_message = "\"<dataset key>.<key>\" references should tell a view and a materialized view with the same key apart."
  }
}

run "tabs_inside_block_scalars_are_content" {
  command = plan

  variables {
    # Spaces indent the YAML; the tab is part of the SQL.
    config_yaml = "datasets:\n  sales: {}\nviews:\n  v:\n    dataset: sales\n    query: |\n      SELECT\n      \tx\n"
  }

  assert {
    condition     = google_bigquery_table.view["sales.v"].view[0].query == "SELECT\n\tx\n"
    error_message = "A tab inside a block scalar is content, not indentation."
  }
}
