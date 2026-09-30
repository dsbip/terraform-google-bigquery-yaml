# Validation: every run plants specific mistakes and checks that the plan fails
# with exactly the expected messages (no more, no less).

mock_provider "google" {}

variables {
  project_id = "test-project"
  base_path  = "tests/fixtures"
}

run "unknown_keys_with_suggestions" {
  command = plan

  variables {
    config_yaml = <<-EOT
      dataset:
        oops: {}
      datasets:
        sales:
          descripton: typo
          zzz: no suggestion
          tables:
            orders:
              shema: []
              time_partitioning: { type: DAY, feild: ts }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "(root): unknown key \"dataset\" (did you mean datasets?)",
      "datasets.sales: unknown key \"descripton\" (did you mean description?)",
      "datasets.sales: unknown key \"zzz\"",
      "datasets.sales.tables.orders: unknown key \"shema\" (did you mean ignore_auto_generated_schema or schema?)",
      "datasets.sales.tables.orders.time_partitioning: unknown key \"feild\" (did you mean field?)",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "wrong_shapes" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          access:
            role: READER
          tables:
            orders:
              clustering: customer_id
              time_partitioning: DAY
      transfers: [a, b]
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "transfers: must be a mapping (key: value pairs)",
      "datasets.sales.tables.orders.time_partitioning: must be a mapping (key: value pairs)",
      "datasets.sales.access: must be a list",
      "datasets.sales.tables.orders.clustering: must be a list",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "defaults_rules" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        locaton: EU
        tables:
          table_id: shared
          descripton: typo
        views:
          query: SELECT 1
      datasets:
        a:
          tables:
            t: {}
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "defaults: unknown key \"locaton\" (did you mean location?)",
      "defaults.tables: unknown key \"descripton\" (did you mean description?)",
      "defaults.tables.table_id: cannot be a default because it identifies or defines a single resource",
      "defaults.views.query: cannot be a default because it identifies or defines a single resource",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
  # The forbidden default must not leak into the tables.
  assert {
    condition     = local.tables["a.t"].table_id == "t"
    error_message = "A forbidden default was applied."
  }
}

run "yaml_booleans_in_keys_and_names" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        yes: {}
        sales:
          tables:
            orders:
              schema:
                - { name: n, type: STRING }
                - name: nested
                  type: RECORD
                  fields:
                    - { name: "on", type: STRING }
                    - { name: off, type: STRING }
          routines:
            f:
              arguments: [{ name: y, data_type: STRING }]
              definition_body: "1"
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.true: YAML read this key as a boolean; quote it (e.g. \"on\":) or pick another key and set the ID explicitly",
      "datasets.sales.tables.orders.schema[0].name: YAML read this name as the boolean false; quote it (e.g. name: \"n\" or name: \"on\")",
      "datasets.sales.tables.orders.schema[1].fields[1].name: YAML read this name as the boolean false; quote it (e.g. name: \"n\" or name: \"on\")",
      "datasets.sales.routines.f.arguments[0].name: YAML read this name as the boolean true; quote it (e.g. name: \"n\" or name: \"on\")",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "access_and_iam_entries" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          access:
            - members: [user:a@example.com]
            - role: READER
              members: []
            - role: READER
              members: [jane@example.com, specialGroup:everyone, group:ok@example.com]
            - role: READER
              members: [group:c@example.com]
              condition: { title: no expression }
          tables:
            orders:
              iam:
                - role: roles/bigquery.dataViewer
                  members: [bob]
                  condition: { expression: "true" }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.sales.access[0].role: is required",
      "datasets.sales.access[1].members: must be a non-empty list",
      "datasets.sales.access[3].condition.expression: is required",
      "datasets.sales.access[2].members[0]: \"jane@example.com\" is not a dataset access member (use user:, serviceAccount:, group:, domain:, specialGroup:, iamMember:, principal://, principalSet://, projectOwners, projectWriters, projectReaders, allAuthenticatedUsers or allUsers)",
      "datasets.sales.access[2].members[1]: \"specialGroup:everyone\" is not a dataset access member (use user:, serviceAccount:, group:, domain:, specialGroup:, iamMember:, principal://, principalSet://, projectOwners, projectWriters, projectReaders, allAuthenticatedUsers or allUsers)",
      "datasets.sales.tables.orders.iam[0].members[0]: \"bob\" is not an IAM member (use user:, group:, serviceAccount:, domain:, principal://, principalSet://, allUsers or allAuthenticatedUsers)",
      "datasets.sales.tables.orders.iam[0].condition.title: is required for IAM conditions",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "existing_datasets_and_duplicates" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        legacy:
          create: false
          description: not allowed
          labels: { a: b }
        maybe:
          create: sometimes
        sales: {}
        sales_copy:
          dataset_id: sales
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.legacy.description: has no effect because create is false (the dataset itself is managed elsewhere)",
      "datasets.legacy.labels: has no effect because create is false (the dataset itself is managed elsewhere)",
      "datasets.maybe.create: must be true or false",
      "datasets.sales and datasets.sales_copy: resolve to the same dataset test-project.sales",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "unresolvable_authorizations" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        private:
          authorized_views:
            - just_one_part
            - { dataset_id: d }
          authorized_datasets:
            - { project_id: p }
          authorized_routines:
            - no_dot
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.private.authorized_views[0]: cannot resolve \"just_one_part\"; use \"dataset.view\", \"project.dataset.view\" or {project_id, dataset_id, table_id}",
      "datasets.private.authorized_views[1]: cannot resolve {\"dataset_id\":\"d\"}; use \"dataset.view\", \"project.dataset.view\" or {project_id, dataset_id, table_id}",
      "datasets.private.authorized_datasets[0]: cannot resolve {\"project_id\":\"p\"}; use \"dataset\", \"project.dataset\" or {project_id, dataset_id}",
      "datasets.private.authorized_routines[0]: cannot resolve \"no_dot\"; use \"dataset.routine\", \"project.dataset.routine\" or {project_id, dataset_id, routine_id}",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "table_rules" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          tables:
            both_schemas:
              schema: [{ name: a, type: STRING }]
              schema_file: schemas/orders.json
            missing_file:
              schema_file: schemas/nope.json
            broken_file:
              schema_file: schemas/broken.json
            bad_schema:
              schema: 42
            both_partitionings:
              time_partitioning: { field: ts }
              range_partitioning: { field: id, range: { start: 0, end: 10, interval: 1 } }
            incomplete_range:
              range_partitioning: { field: id, range: { start: 0 } }
            both_external:
              external_data_configuration: { source_format: CSV }
              biglake_configuration: { connection_id: a.b.c }
            bad_fk:
              table_constraints:
                foreign_keys:
                  - referenced_table: nodot
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.sales.tables.both_schemas: set schema or schema_file, not both",
      "datasets.sales.tables.missing_file.schema_file: file not found: tests/fixtures/schemas/nope.json",
      "datasets.sales.tables.broken_file.schema_file: tests/fixtures/schemas/broken.json is not a JSON or YAML list of fields",
      "datasets.sales.tables.bad_schema.schema: must be a list of fields or a JSON string",
      "datasets.sales.tables.both_partitionings: set time_partitioning or range_partitioning, not both",
      "datasets.sales.tables.incomplete_range.range_partitioning: field and range.start, range.end, range.interval are required",
      "datasets.sales.tables.both_external: set external_data_configuration or biglake_configuration, not both",
      "datasets.sales.tables.both_external.external_data_configuration.source_uris: is required",
      "datasets.sales.tables.both_external.biglake_configuration: connection_id and storage_uri are required",
      "datasets.sales.tables.bad_fk.table_constraints.foreign_keys[0].referenced_table: cannot resolve; use \"dataset.table\", \"project.dataset.table\" or {project_id, dataset_id, table_id}",
      "datasets.sales.tables.bad_fk.table_constraints.foreign_keys[0].column_references: referencing_column and referenced_column are required",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "duplicate_tables" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          tables:
            orders: {}
            orders_v2:
              table_id: orders_new
            clash:
              table_id: orders_new
          views:
            orders:
              query: SELECT 1
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.sales.tables.orders and datasets.sales.views.orders: tables, views and materialized views in one dataset need distinct keys",
      "datasets.sales.tables.clash and datasets.sales.tables.orders_v2: resolve to the same table test-project.sales.orders_new",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "view_and_materialized_view_rules" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        reporting:
          views:
            both:
              query: SELECT 1
              query_file: sql/static.sql
            neither: {}
            missing:
              query_file: sql/nope.sql
            not_a_path:
              query_file: [a]
          materialized_views:
            mv_neither:
              time_partitioning: { field: d }
              range_partitioning: { field: id, range: { start: 0, end: 1, interval: 1 } }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.reporting.views.both: set query or query_file, not both",
      "datasets.reporting.views.neither: query or query_file is required",
      "datasets.reporting.materialized_views.mv_neither: query or query_file is required",
      "datasets.reporting.materialized_views.mv_neither: set time_partitioning or range_partitioning, not both",
      "datasets.reporting.views.missing.query_file: file not found: tests/fixtures/sql/nope.sql",
      "datasets.reporting.views.not_a_path.query_file: must be a file path",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "routine_rules" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        udfs:
          routines:
            both:
              definition_body: "1"
              definition_file: sql/procedure.sql
            neither:
              arguments: [{ name: x }]
            bad_table_type:
              routine_type: TABLE_VALUED_FUNCTION
              definition_body: SELECT 1
              return_table_type: { columns: [{ type: STRING }] }
            missing_file:
              definition_file: sql/nope.sql
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.udfs.routines.both: set definition_body or definition_file, not both",
      "datasets.udfs.routines.neither: definition_body or definition_file is required",
      "datasets.udfs.routines.neither.arguments[0].data_type: is required unless argument_kind is ANY_TYPE or FIXED_TABLE",
      "datasets.udfs.routines.bad_table_type.return_table_type: must be {columns: [{name, type}]} or a JSON string",
      "datasets.udfs.routines.missing_file.definition_file: file not found: tests/fixtures/sql/nope.sql",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

# Also proves that resources are not planned for an invalid file: the provider
# itself rejects a connection with two types, so had connections.two been
# planned, the provider error would have failed this run.
run "connection_rules" {
  command = plan

  variables {
    secrets     = { present = "x" }
    config_yaml = <<-EOT
      connections:
        none:
          description: no type
        two:
          cloud_resource: {}
          spark: {}
        sql:
          cloud_sql:
            instance_id: p:r:i
            database: db
            type: POSTGRES
            credential: { username: u, password_secret: absent }
        sql_incomplete:
          cloud_sql:
            credential: { username: u }
        connector:
          configuration:
            asset: { database: d }
            authentication:
              username_password: { username: u }
        dup:
          connection_id: sql
          location: null
          cloud_resource: {}
      datasets:
        lake:
          tables:
            t:
              schema: [{ name: a, type: STRING }]
              external_data_configuration:
                source_uris: ["gs://b/*"]
                connection_id: nolake
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "connections.none: set exactly one connection type (cloud_resource, cloud_sql, aws, azure, cloud_spanner, spark, configuration); found none",
      "connections.two: set exactly one connection type (cloud_resource, cloud_sql, aws, azure, cloud_spanner, spark, configuration); found cloud_resource, spark",
      "connections.sql.cloud_sql.credential.password_secret: \"absent\" is not a key of the secrets variable",
      "connections.sql_incomplete.cloud_sql: instance_id, database, type, credential.username and credential.password_secret are required",
      "connections.connector.configuration: connector_id is required, and authentication.username_password needs both username and password_secret",
      "connections.dup and connections.sql: resolve to the same connection test-project.<default location>.sql",
      "datasets.lake.tables.t.external_data_configuration.connection_id: \"nolake\" is not a key under connections; use a key from this file, project.location.connection_id or projects/P/locations/L/connections/C",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "transfer_rules" {
  command = plan

  variables {
    config_yaml = <<-EOT
      transfers:
        no_source:
          query: SELECT 1
        too_many_queries:
          data_source_id: scheduled_query
          query: SELECT 1
          params: { query: SELECT 2 }
        nested_param:
          data_source_id: google_cloud_storage
          params:
            nested: { a: 1 }
        missing_secret:
          data_source_id: amazon_s3
          sensitive_params: { secret_access_key_secret: nope }
        missing_file:
          data_source_id: scheduled_query
          query_file: sql/nope.sql
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "transfers.no_source.data_source_id: is required (e.g. scheduled_query, google_cloud_storage)",
      "transfers.too_many_queries: set only one of query, query_file and params.query",
      "transfers.nested_param.params.nested: must be a string, number or boolean",
      "transfers.missing_secret.sensitive_params.secret_access_key_secret: \"nope\" is not a key of the secrets variable",
      "transfers.missing_file.query_file: file not found: tests/fixtures/sql/nope.sql",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}
