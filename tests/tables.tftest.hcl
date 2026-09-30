# Tables: schemas, partitioning, clustering, constraints, external and BigLake
# tables, deletion protection and table IAM.

mock_provider "google" {}

variables {
  project_id = "test-project"
  base_path  = "tests/fixtures"
}

run "schema_sources" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          tables:
            inline:
              schema:
                - { name: order_id, type: STRING, mode: REQUIRED, description: The ID }
                - name: tags
                  type: RECORD
                  mode: REPEATED
                  fields:
                    - { name: key, type: STRING }
            json_string:
              schema: '[{"name":"x","type":"INT64"}]'
            from_json_file:
              schema_file: schemas/orders.json
            from_yaml_file:
              schema_file: schemas/orders.yaml
            no_schema: {}
    EOT
  }

  assert {
    condition = jsondecode(google_bigquery_table.table["sales.inline"].schema) == [
      { name = "order_id", type = "STRING", mode = "REQUIRED", description = "The ID" },
      { name = "tags", type = "RECORD", mode = "REPEATED", fields = [{ name = "key", type = "STRING" }] },
    ]
    error_message = "Inline schema was not encoded correctly: ${google_bigquery_table.table["sales.inline"].schema}"
  }
  assert {
    condition     = google_bigquery_table.table["sales.json_string"].schema == "[{\"name\":\"x\",\"type\":\"INT64\"}]"
    error_message = "A JSON string schema should be used as written."
  }
  assert {
    condition     = jsondecode(google_bigquery_table.table["sales.from_json_file"].schema) == jsondecode(google_bigquery_table.table["sales.from_yaml_file"].schema)
    error_message = "JSON and YAML schema files with the same fields should produce the same schema."
  }
  assert {
    condition     = length(jsondecode(google_bigquery_table.table["sales.from_json_file"].schema)) == 2
    error_message = "The JSON schema file was not read."
  }
}

run "partitioning_and_clustering" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        events:
          tables:
            by_day:
              time_partitioning:
                field: ts
              clustering: [user_id, page]
              require_partition_filter: true
            by_hour:
              time_partitioning:
                type: HOUR
                field: ts
                expiration_ms: 3600000
            ingestion_time:
              time_partitioning: {}
            by_range:
              range_partitioning:
                field: customer_id
                range: { start: 0, end: 100, interval: 10 }
            unpartitioned:
              clustering: []
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.table["events.by_day"].time_partitioning[0].type == "DAY" &&
      google_bigquery_table.table["events.by_day"].time_partitioning[0].field == "ts" &&
      google_bigquery_table.table["events.by_day"].clustering == tolist(["user_id", "page"]) &&
      google_bigquery_table.table["events.by_day"].require_partition_filter == true
    )
    error_message = "Daily partitioning should default the type to DAY."
  }
  assert {
    condition = (
      google_bigquery_table.table["events.by_hour"].time_partitioning[0].type == "HOUR" &&
      google_bigquery_table.table["events.by_hour"].time_partitioning[0].expiration_ms == 3600000
    )
    error_message = "Hourly partitioning is wrong."
  }
  assert {
    condition = (
      google_bigquery_table.table["events.ingestion_time"].time_partitioning[0].type == "DAY" &&
      google_bigquery_table.table["events.ingestion_time"].time_partitioning[0].field == null
    )
    error_message = "An empty time_partitioning should mean ingestion-time DAY partitioning."
  }
  assert {
    condition = (
      google_bigquery_table.table["events.by_range"].range_partitioning[0].field == "customer_id" &&
      google_bigquery_table.table["events.by_range"].range_partitioning[0].range[0].start == 0 &&
      google_bigquery_table.table["events.by_range"].range_partitioning[0].range[0].end == 100 &&
      google_bigquery_table.table["events.by_range"].range_partitioning[0].range[0].interval == 10
    )
    error_message = "Range partitioning is wrong."
  }
  assert {
    condition = (
      length(google_bigquery_table.table["events.unpartitioned"].time_partitioning) == 0 &&
      google_bigquery_table.table["events.unpartitioned"].clustering == null
    )
    error_message = "An empty clustering list should not be sent."
  }
}

run "table_settings_and_deletion_protection" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        tables:
          deletion_protection: false
          labels: { tier: gold }
      datasets:
        sales:
          tables:
            defaulted:
              friendly_name: Defaulted
              description: Uses the defaults
            protected:
              deletion_protection: true
              deletion_policy: PREVENT
              expiration_time: 1893456000000
              max_staleness: "0-0 0 4:0:0"
              labels: { pii: "true" }
              resource_tags:
                "123/env": prod
              encryption_configuration:
                kms_key_name: projects/p/locations/us/keyRings/r/cryptoKeys/k
              ignore_auto_generated_schema: true
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.table["sales.defaulted"].deletion_protection == false &&
      google_bigquery_table.table["sales.defaulted"].friendly_name == "Defaulted" &&
      google_bigquery_table.table["sales.defaulted"].labels == tomap({ tier = "gold" })
    )
    error_message = "defaults.tables were not applied."
  }
  assert {
    condition = (
      google_bigquery_table.table["sales.protected"].deletion_protection == true &&
      google_bigquery_table.table["sales.protected"].deletion_policy == "PREVENT" &&
      google_bigquery_table.table["sales.protected"].expiration_time == 1893456000000 &&
      google_bigquery_table.table["sales.protected"].max_staleness == "0-0 0 4:0:0" &&
      google_bigquery_table.table["sales.protected"].resource_tags["123/env"] == "prod" &&
      google_bigquery_table.table["sales.protected"].encryption_configuration[0].kms_key_name == "projects/p/locations/us/keyRings/r/cryptoKeys/k" &&
      google_bigquery_table.table["sales.protected"].ignore_auto_generated_schema == true
    )
    error_message = "Table settings were not passed through."
  }
  assert {
    condition     = google_bigquery_table.table["sales.protected"].labels == tomap({ tier = "gold", pii = "true" })
    error_message = "Table labels should merge with defaults.tables.labels."
  }
}

run "tables_keep_the_provider_deletion_protection_default" {
  command = plan

  variables {
    config_yaml = "datasets:\n  a:\n    tables:\n      t: {}\n"
  }

  assert {
    condition     = google_bigquery_table.table["a.t"].deletion_protection == null
    error_message = "Without defaults, deletion_protection should be left to the provider (true)."
  }
}

run "table_id_override" {
  command = plan

  variables {
    config_yaml = "datasets:\n  a:\n    dataset_id: sales_prod\n    tables:\n      orders:\n        table_id: orders_v2\n"
  }

  assert {
    condition = (
      google_bigquery_table.table["a.orders"].table_id == "orders_v2" &&
      google_bigquery_table.table["a.orders"].dataset_id == "sales_prod"
    )
    error_message = "table_id and the parent dataset_id should be used."
  }
}

run "primary_and_foreign_keys" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        core:
          dataset_id: core_prod
          tables:
            customers:
              table_id: dim_customer
              table_constraints:
                primary_key: { columns: [customer_id] }
            orders:
              table_constraints:
                primary_key: { columns: [order_id] }
                foreign_keys:
                  - name: fk_managed
                    referenced_table: core.customers
                    column_references: { referencing_column: customer_id, referenced_column: customer_id }
                  - name: fk_dataset_key
                    referenced_table: core.products
                    column_references: { referencing_column: product_id, referenced_column: product_id }
                  - name: fk_other_dataset
                    referenced_table: reference.countries
                    column_references: { referencing_column: country, referenced_column: code }
                  - name: fk_other_project
                    referenced_table: shared-project.reference.currencies
                    column_references: { referencing_column: currency, referenced_column: code }
                  - referenced_table: { project_id: p2, dataset_id: d2, table_id: t2 }
                    column_references: { referencing_column: a, referenced_column: b }
    EOT
  }

  assert {
    condition     = google_bigquery_table.table["core.customers"].table_constraints[0].primary_key[0].columns == tolist(["customer_id"])
    error_message = "Primary key is wrong."
  }
  assert {
    condition = [
      for fk in google_bigquery_table.table["core.orders"].table_constraints[0].foreign_keys :
      "${fk.referenced_table[0].project_id}.${fk.referenced_table[0].dataset_id}.${fk.referenced_table[0].table_id}"
      ] == [
      "test-project.core_prod.dim_customer",
      "test-project.core_prod.products",
      "test-project.reference.countries",
      "shared-project.reference.currencies",
      "p2.d2.t2",
    ]
    error_message = "Foreign key references resolved incorrectly."
  }
  assert {
    condition = (
      google_bigquery_table.table["core.orders"].table_constraints[0].foreign_keys[0].name == "fk_managed" &&
      google_bigquery_table.table["core.orders"].table_constraints[0].foreign_keys[0].column_references[0].referencing_column == "customer_id" &&
      google_bigquery_table.table["core.orders"].table_constraints[0].foreign_keys[4].name == null
    )
    error_message = "Foreign key names and columns are wrong."
  }
}

run "external_tables_route_the_schema" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        landing:
          tables:
            csv_with_schema:
              schema_file: schemas/orders.json
              external_data_configuration:
                source_format: CSV
                source_uris: ["gs://b/orders/*.csv"]
                csv_options: { skip_leading_rows: 1 }
            parquet_autodetect:
              external_data_configuration:
                source_format: PARQUET
                source_uris: ["gs://b/p/*"]
                hive_partitioning_options:
                  mode: AUTO
                  source_uri_prefix: gs://b/p/
                  require_partition_filter: true
                parquet_options: { enable_list_inference: true, enum_as_string: true }
            biglake_with_connection:
              schema: [{ name: a, type: STRING }]
              external_data_configuration:
                source_format: PARQUET
                source_uris: ["gs://b/l/*"]
                connection_id: test-project.us.lake
                metadata_cache_mode: AUTOMATIC
            json_options:
              external_data_configuration:
                source_format: NEWLINE_DELIMITED_JSON
                source_uris: ["gs://b/j/*"]
                autodetect: true
                compression: GZIP
                ignore_unknown_values: true
                max_bad_records: 5
                json_options: { encoding: UTF-8 }
            avro:
              external_data_configuration:
                source_format: AVRO
                source_uris: ["gs://b/a/*"]
                avro_options: { use_avro_logical_types: true }
            sheet:
              schema: [{ name: a, type: STRING }]
              external_data_configuration:
                source_format: GOOGLE_SHEETS
                source_uris: ["https://docs.google.com/spreadsheets/d/abc"]
                google_sheets_options: { range: "Sheet1!A1:B20", skip_leading_rows: 1 }
    EOT
  }

  # schema is optional+computed, so a null value shows as unknown in the plan;
  # the module's decision is checked on its normalised locals instead.
  assert {
    condition = (
      local.tables["landing.csv_with_schema"].schema == null &&
      jsondecode(google_bigquery_table.table["landing.csv_with_schema"].external_data_configuration[0].schema)[0].name == "order_id" &&
      google_bigquery_table.table["landing.csv_with_schema"].external_data_configuration[0].autodetect == false
    )
    error_message = "Without a connection the schema belongs in external_data_configuration and autodetect is off."
  }
  assert {
    condition = (
      google_bigquery_table.table["landing.csv_with_schema"].external_data_configuration[0].csv_options[0].quote == "\"" &&
      google_bigquery_table.table["landing.csv_with_schema"].external_data_configuration[0].csv_options[0].skip_leading_rows == 1
    )
    error_message = "csv_options should default quote to a double quote."
  }
  assert {
    condition = (
      google_bigquery_table.table["landing.parquet_autodetect"].external_data_configuration[0].autodetect == true &&
      google_bigquery_table.table["landing.parquet_autodetect"].external_data_configuration[0].hive_partitioning_options[0].mode == "AUTO" &&
      google_bigquery_table.table["landing.parquet_autodetect"].external_data_configuration[0].hive_partitioning_options[0].require_partition_filter == true &&
      google_bigquery_table.table["landing.parquet_autodetect"].external_data_configuration[0].parquet_options[0].enum_as_string == true
    )
    error_message = "Without a schema autodetect should be on, and hive/parquet options passed through."
  }
  assert {
    condition = (
      jsondecode(google_bigquery_table.table["landing.biglake_with_connection"].schema)[0].name == "a" &&
      local.tables["landing.biglake_with_connection"].external_data_configuration[0].schema == null &&
      google_bigquery_table.table["landing.biglake_with_connection"].external_data_configuration[0].connection_id == "test-project.us.lake" &&
      google_bigquery_table.table["landing.biglake_with_connection"].external_data_configuration[0].metadata_cache_mode == "AUTOMATIC"
    )
    error_message = "With a connection the schema belongs at the top level."
  }
  assert {
    condition = (
      google_bigquery_table.table["landing.json_options"].external_data_configuration[0].compression == "GZIP" &&
      google_bigquery_table.table["landing.json_options"].external_data_configuration[0].max_bad_records == 5 &&
      google_bigquery_table.table["landing.json_options"].external_data_configuration[0].json_options[0].encoding == "UTF-8" &&
      google_bigquery_table.table["landing.avro"].external_data_configuration[0].avro_options[0].use_avro_logical_types == true &&
      google_bigquery_table.table["landing.sheet"].external_data_configuration[0].google_sheets_options[0].range == "Sheet1!A1:B20"
    )
    error_message = "External data options were not passed through."
  }
}

run "bigtable_external_table" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        landing:
          tables:
            bt:
              external_data_configuration:
                source_format: BIGTABLE
                source_uris: ["https://googleapis.com/bigtable/projects/p/instances/i/tables/t"]
                bigtable_options:
                  read_rowkey_as_string: true
                  column_family:
                    - family_id: cf1
                      type: STRING
                      column:
                        - { qualifier_string: name, field_name: name_col }
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.table["landing.bt"].external_data_configuration[0].bigtable_options[0].read_rowkey_as_string == true &&
      google_bigquery_table.table["landing.bt"].external_data_configuration[0].bigtable_options[0].column_family[0].family_id == "cf1" &&
      google_bigquery_table.table["landing.bt"].external_data_configuration[0].bigtable_options[0].column_family[0].column[0].field_name == "name_col"
    )
    error_message = "Bigtable options were not passed through."
  }
}

run "biglake_managed_table_defaults" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        lake:
          tables:
            iceberg:
              schema: [{ name: id, type: STRING }]
              biglake_configuration:
                connection_id: projects/test-project/locations/us/connections/lake
                storage_uri: gs://b/iceberg/
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.table["lake.iceberg"].biglake_configuration[0].file_format == "PARQUET" &&
      google_bigquery_table.table["lake.iceberg"].biglake_configuration[0].table_format == "ICEBERG" &&
      google_bigquery_table.table["lake.iceberg"].biglake_configuration[0].storage_uri == "gs://b/iceberg/" &&
      google_bigquery_table.table["lake.iceberg"].biglake_configuration[0].connection_id == "projects/test-project/locations/us/connections/lake"
    )
    error_message = "BigLake defaults (PARQUET / ICEBERG) or pass-through are wrong."
  }
}

run "connection_keys_resolve_to_connection_names" {
  # Apply with the mock provider so the connection gets a (fake) name.
  command = apply

  variables {
    config_yaml = <<-EOT
      connections:
        lake:
          location: US
          cloud_resource: {}
      datasets:
        lake:
          tables:
            ext:
              schema: [{ name: id, type: STRING }]
              external_data_configuration:
                source_format: PARQUET
                source_uris: ["gs://b/x/*"]
                connection_id: lake
            iceberg:
              schema: [{ name: id, type: STRING }]
              biglake_configuration:
                connection_id: lake
                storage_uri: gs://b/iceberg/
    EOT
  }

  assert {
    condition     = google_bigquery_table.table["lake.ext"].external_data_configuration[0].connection_id == google_bigquery_connection.this["lake"].name
    error_message = "external_data_configuration.connection_id should resolve a connection key."
  }
  assert {
    condition     = google_bigquery_table.table["lake.iceberg"].biglake_configuration[0].connection_id == google_bigquery_connection.this["lake"].name
    error_message = "biglake_configuration.connection_id should resolve a connection key."
  }
}

run "table_iam_members" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          tables:
            orders:
              iam:
                - role: roles/bigquery.dataViewer
                  members: [group:a@example.com, user:b@example.com]
                - role: roles/bigquery.dataEditor
                  members: [serviceAccount:etl@test-project.iam.gserviceaccount.com]
                  condition:
                    title: business hours
                    expression: request.time.getHours("Europe/Berlin") < 18
    EOT
  }

  assert {
    condition     = length(google_bigquery_table_iam_member.this) == 3
    error_message = "Expected one IAM member resource per role and member."
  }
  assert {
    condition = (
      google_bigquery_table_iam_member.this["sales.orders|roles/bigquery.dataViewer|group:a@example.com"].table_id == "orders" &&
      google_bigquery_table_iam_member.this["sales.orders|roles/bigquery.dataViewer|group:a@example.com"].member == "group:a@example.com"
    )
    error_message = "Table IAM member is wrong."
  }
  assert {
    condition     = google_bigquery_table_iam_member.this["sales.orders|roles/bigquery.dataEditor|serviceAccount:etl@test-project.iam.gserviceaccount.com"].condition[0].title == "business hours"
    error_message = "IAM condition was not passed through."
  }
}
