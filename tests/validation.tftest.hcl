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
          dataset: sales
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
      "tables.orders: unknown key \"shema\" (did you mean ignore_auto_generated_schema or schema?)",
      "tables.orders.time_partitioning: unknown key \"feild\" (did you mean field?)",
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
          dataset: sales
          clustering: customer_id
          time_partitioning: DAY

      transfers: [a, b]
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "transfers: must be a mapping (key: value pairs)",
      "tables.orders.time_partitioning: must be a mapping (key: value pairs)",
      "datasets.sales.access: must be a list",
      "tables.orders.clustering: must be a list",
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
        t: { dataset: a }
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
          dataset: sales
          schema:
            - { name: n, type: STRING }
            - name: nested
              type: RECORD
              fields:
                - { name: "on", type: STRING }
                - { name: off, type: STRING }

      routines:
        f:
          dataset: sales
          arguments: [{ name: y, data_type: STRING }]
          definition_body: "1"
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.true: YAML read this key as a boolean; quote it (e.g. \"on\":) or pick another key and set the ID explicitly",
      "tables.orders.schema[0].name: YAML read this name as the boolean false; quote it (e.g. name: \"n\" or name: \"on\")",
      "tables.orders.schema[1].fields[1].name: YAML read this name as the boolean false; quote it (e.g. name: \"n\" or name: \"on\")",
      "routines.f.arguments[0].name: YAML read this name as the boolean true; quote it (e.g. name: \"n\" or name: \"on\")",
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
          dataset: sales
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
      "tables.orders.iam[0].members[0]: \"bob\" is not an IAM member (use user:, group:, serviceAccount:, domain:, principal://, principalSet://, allUsers or allAuthenticatedUsers)",
      "tables.orders.iam[0].condition.title: is required for IAM conditions",
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
      "datasets.private.authorized_views[0]: cannot resolve \"just_one_part\"; use a view key, \"dataset.view\", \"project.dataset.view\" or {project_id, dataset_id, table_id}",
      "datasets.private.authorized_views[1]: cannot resolve {\"dataset_id\":\"d\"}; use a view key, \"dataset.view\", \"project.dataset.view\" or {project_id, dataset_id, table_id}",
      "datasets.private.authorized_datasets[0]: cannot resolve {\"project_id\":\"p\"}; use \"dataset\", \"project.dataset\" or {project_id, dataset_id}",
      "datasets.private.authorized_routines[0]: cannot resolve \"no_dot\"; use a routine key, \"dataset.routine\", \"project.dataset.routine\" or {project_id, dataset_id, routine_id}",
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
          dataset: sales
          schema: [{ name: a, type: STRING }]
          schema_file: schemas/orders.json
        missing_file:
          dataset: sales
          schema_file: schemas/nope.json
        broken_file:
          dataset: sales
          schema_file: schemas/broken.json
        bad_schema:
          dataset: sales
          schema: 42
        both_partitionings:
          dataset: sales
          time_partitioning: { field: ts }
          range_partitioning: { field: id, range: { start: 0, end: 10, interval: 1 } }
        incomplete_range:
          dataset: sales
          range_partitioning: { field: id, range: { start: 0 } }
        both_external:
          dataset: sales
          external_data_configuration: { source_format: CSV }
          biglake_configuration: { connection_id: a.b.c }
        bad_fk:
          dataset: sales
          table_constraints:
            foreign_keys:
              - referenced_table: nodot
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "tables.both_schemas: set schema or schema_file, not both",
      "tables.missing_file.schema_file: file not found: tests/fixtures/schemas/nope.json",
      "tables.broken_file.schema_file: tests/fixtures/schemas/broken.json is not a JSON or YAML list of fields",
      "tables.bad_schema.schema: must be a list of fields or a JSON string",
      "tables.both_partitionings: set time_partitioning or range_partitioning, not both",
      "tables.incomplete_range.range_partitioning: field and range.start, range.end, range.interval are required",
      "tables.both_external: set external_data_configuration or biglake_configuration, not both",
      "tables.both_external.external_data_configuration.source_uris: is required",
      "tables.both_external.biglake_configuration: connection_id and storage_uri are required",
      "tables.bad_fk.table_constraints.foreign_keys[0].referenced_table: cannot resolve; use a table key, \"dataset.table\", \"project.dataset.table\" or {project_id, dataset_id, table_id}",
      "tables.bad_fk.table_constraints.foreign_keys[0].column_references: referencing_column and referenced_column are required",
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
        orders: { dataset: sales }
        orders_v2:
          dataset: sales
          table_id: orders_new
        clash:
          dataset: sales
          table_id: orders_new

      views:
        orders:
          dataset: sales
          query: SELECT 1
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "tables.orders and views.orders: tables, views and materialized views in one dataset need distinct keys",
      "tables.clash and tables.orders_v2: resolve to the same table test-project.sales.orders_new",
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
          dataset: reporting
          query: SELECT 1
          query_file: sql/static.sql
        neither: { dataset: reporting }
        missing:
          dataset: reporting
          query_file: sql/nope.sql
        not_a_path:
          dataset: reporting
          query_file: [a]

      materialized_views:
        mv_neither:
          dataset: reporting
          time_partitioning: { field: d }
          range_partitioning: { field: id, range: { start: 0, end: 1, interval: 1 } }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "views.both: set query or query_file, not both",
      "views.neither: query or query_file is required",
      "materialized_views.mv_neither: query or query_file is required",
      "materialized_views.mv_neither: set time_partitioning or range_partitioning, not both",
      "views.missing.query_file: file not found: tests/fixtures/sql/nope.sql",
      "views.not_a_path.query_file: must be a file path",
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
          dataset: udfs
          definition_body: "1"
          definition_file: sql/procedure.sql
        neither:
          dataset: udfs
          arguments: [{ name: x }]
        bad_table_type:
          dataset: udfs
          routine_type: TABLE_VALUED_FUNCTION
          definition_body: SELECT 1
          return_table_type: { columns: [{ type: STRING }] }
        missing_file:
          dataset: udfs
          definition_file: sql/nope.sql
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "routines.both: set definition_body or definition_file, not both",
      "routines.neither: definition_body or definition_file is required",
      "routines.neither.arguments[0].data_type: is required unless argument_kind is ANY_TYPE or FIXED_TABLE",
      "routines.bad_table_type.return_table_type: must be {columns: [{name, type}]} or a JSON string",
      "routines.missing_file.definition_file: file not found: tests/fixtures/sql/nope.sql",
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
          dataset: lake
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
      "tables.t.external_data_configuration.connection_id: \"nolake\" is not a key under connections; use a key from this file, project.location.connection_id or projects/P/locations/L/connections/C",
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

run "dataset_references" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales: {}
        marketing: {}
        "x.y": {}

      tables:
        no_dataset:
          description: forgot the dataset
        null_entry:
        list_dataset:
          dataset: [sales]
        typo:
          dataset: salse
        prefix:
          dataset: market
        unknown:
          dataset: finance
        fine:
          dataset: sales

      views:
        "a.b":
          dataset: sales
          query: SELECT 1

      routines:
        r:
          definition_body: SELECT 1
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.x.y: keys cannot contain \".\" (it separates the dataset key from the key in references)",
      "views.a.b: keys cannot contain \".\" (it separates the dataset key from the key in references)",
      "tables.no_dataset.dataset: is required (the key of a dataset under datasets)",
      "tables.null_entry.dataset: is required (the key of a dataset under datasets)",
      "tables.list_dataset.dataset: must be the key of a dataset under datasets",
      "tables.typo.dataset: \"salse\" is not a key under datasets (did you mean sales?); declare a dataset managed elsewhere with create: false",
      "tables.prefix.dataset: \"market\" is not a key under datasets (did you mean marketing?); declare a dataset managed elsewhere with create: false",
      "tables.unknown.dataset: \"finance\" is not a key under datasets; declare a dataset managed elsewhere with create: false",
      "routines.r.dataset: is required (the key of a dataset under datasets)",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "v1_nesting_is_explained" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          description: Still in the v1 layout
          tables:
            orders: {}
          materialized_views:
            daily: { query: SELECT 1 }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.sales.tables: tables are not nested in datasets; move each entry to the top-level tables section and add dataset: sales to it (see docs/upgrading.md)",
      "datasets.sales.materialized_views: materialized_views are not nested in datasets; move each entry to the top-level materialized_views section and add dataset: sales to it (see docs/upgrading.md)",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "dataset_cannot_be_a_default" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        tables:
          dataset: sales
      datasets:
        sales: {}
      tables:
        t: {}
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "defaults.tables.dataset: cannot be a default because it identifies or defines a single resource",
      "tables.t.dataset: is required (the key of a dataset under datasets)",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "ambiguous_view_key" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        a: {}
        b: {}
        private:
          authorized_views: [x, a.x]
      views:
        x: { dataset: a, query: SELECT 1 }
      materialized_views:
        x: { dataset: b, query: SELECT 1 }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.private.authorized_views[0]: \"x\" is the key of both a view and a materialized view; write \"<dataset key>.x\"",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "tab_indentation_is_explained" {
  command = plan

  variables {
    config_yaml = "datasets:\n\tsales: {}\ntables:\n  t:\n\t  dataset: sales\n"
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "The YAML cannot be parsed: tabs are used for indentation on lines 2, 5. YAML allows only spaces; replace the tabs with spaces.",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "many_tab_lines_are_summarised" {
  command = plan

  variables {
    config_yaml = "datasets:\n\ta: {}\n\tb: {}\n\tc: {}\n\td: {}\n\te: {}\n\tf: {}\n\tg: {}\n"
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "The YAML cannot be parsed: tabs are used for indentation on lines 2, 3, 4, 5, 6 and 2 more. YAML allows only spaces; replace the tabs with spaces.",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "duplicate_keys_are_reported" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        raw: {}
        staging: {}
      tables:
        orders:
          dataset: raw
        customers: { dataset: raw }
        orders:
          dataset: staging
          description: |
            orders:
            a line in a block scalar that looks like a key
      views:
        v: { dataset: raw, query: SELECT 1 }
      views:
        w: { dataset: raw, query: SELECT 1 }
    EOT
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "(root): \"views\" appears on lines 13 and 15; YAML keeps only the last one, so merge them into one section",
      "tables.orders: defined on lines 5 and 8; YAML keeps only the last one. Keys must be unique within tables; rename the others (table_id sets the BigQuery ID independently of the key)",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "duplicate_keys_with_windows_line_endings" {
  command = plan

  variables {
    config_yaml = "datasets:\r\n  \"a\": {}\r\n  a: {}\r\n"
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.a: defined on lines 2 and 3; YAML keeps only the last one. Keys must be unique within datasets; rename the others (dataset_id sets the BigQuery ID independently of the key)",
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}
