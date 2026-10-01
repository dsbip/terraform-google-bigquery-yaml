# Routines: UDFs, table-valued functions, procedures, remote and Spark routines.

mock_provider "google" {}

variables {
  project_id = "test-project"
  base_path  = "tests/fixtures"
}

run "scalar_sql_function_and_type_spellings" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        udfs:

      routines:
        f:
          dataset: udfs
          description: Adds one
          arguments:
            - { name: simple, data_type: int64 }
            - { name: alias, data_type: INTEGER }
            - { name: legacy_float, data_type: FLOAT }
            - { name: raw_json, data_type: '{"typeKind":"STRING"}' }
            - name: nested
              data_type:
                typeKind: ARRAY
                arrayElementType: { typeKind: STRING }
            - { name: anything, argument_kind: ANY_TYPE }
          return_type: BOOLEAN
          definition_body: simple + 1 > 0
    EOT
  }

  assert {
    condition = (
      google_bigquery_routine.this["udfs.f"].routine_type == "SCALAR_FUNCTION" &&
      google_bigquery_routine.this["udfs.f"].routine_id == "f" &&
      google_bigquery_routine.this["udfs.f"].definition_body == "simple + 1 > 0" &&
      google_bigquery_routine.this["udfs.f"].description == "Adds one"
    )
    error_message = "routine_type should default to SCALAR_FUNCTION."
  }
  assert {
    condition = jsonencode([for a in google_bigquery_routine.this["udfs.f"].arguments : a.data_type]) == jsonencode([
      "{\"typeKind\":\"INT64\"}",
      "{\"typeKind\":\"INT64\"}",
      "{\"typeKind\":\"FLOAT64\"}",
      "{\"typeKind\":\"STRING\"}",
      "{\"arrayElementType\":{\"typeKind\":\"STRING\"},\"typeKind\":\"ARRAY\"}",
      null,
    ])
    error_message = "Argument types converted incorrectly: ${jsonencode([for a in google_bigquery_routine.this["udfs.f"].arguments : a.data_type])}"
  }
  assert {
    condition     = google_bigquery_routine.this["udfs.f"].arguments[5].argument_kind == "ANY_TYPE"
    error_message = "argument_kind was not passed through."
  }
  assert {
    condition     = google_bigquery_routine.this["udfs.f"].return_type == "{\"typeKind\":\"BOOL\"}"
    error_message = "return_type BOOLEAN should map to BOOL."
  }
}

run "struct_return_type" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        udfs:

      routines:
        s:
          dataset: udfs
          arguments: [{ name: id, data_type: STRING }]
          return_type:
            typeKind: STRUCT
            structType:
              fields:
                - { name: id, type: { typeKind: STRING } }
          definition_body: STRUCT(id AS id)
    EOT
  }

  assert {
    condition     = jsondecode(google_bigquery_routine.this["udfs.s"].return_type).structType.fields[0].name == "id"
    error_message = "A mapping return_type should be JSON-encoded."
  }
}

run "table_valued_function" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        udfs:

      routines:
        tvf:
          dataset: udfs
          routine_type: TABLE_VALUED_FUNCTION
          arguments: [{ name: min_amount, data_type: NUMERIC }]
          definition_body: SELECT order_id, amount FROM `p.d.orders` WHERE amount > min_amount
          return_table_type:
            columns:
              - { name: order_id, type: STRING }
              - { name: amount, type: numeric }
              - name: tags
                type: { typeKind: ARRAY, arrayElementType: { typeKind: STRING } }
        tvf_json:
          dataset: udfs
          routine_type: TABLE_VALUED_FUNCTION
          definition_body: SELECT 1 AS x
          return_table_type: '{"columns":[{"name":"x","type":{"typeKind":"INT64"}}]}'
        tvf_table_arg:
          dataset: udfs
          routine_type: TABLE_VALUED_FUNCTION
          definition_body: SELECT * FROM t
          arguments:
            - name: t
              argument_kind: FIXED_TABLE
              table_type:
                columns:
                  - { name: id, type: STRING }
                  - { name: "n", type: INT64 } # unquoted, YAML would read n as false
    EOT
  }

  assert {
    condition = jsondecode(google_bigquery_routine.this["udfs.tvf"].return_table_type) == {
      columns = [
        { name = "order_id", type = { typeKind = "STRING" } },
        { name = "amount", type = { typeKind = "NUMERIC" } },
        { name = "tags", type = { typeKind = "ARRAY", arrayElementType = { typeKind = "STRING" } } },
      ]
    }
    error_message = "return_table_type was not built correctly: ${google_bigquery_routine.this["udfs.tvf"].return_table_type}"
  }
  assert {
    condition     = google_bigquery_routine.this["udfs.tvf_json"].return_table_type == "{\"columns\":[{\"name\":\"x\",\"type\":{\"typeKind\":\"INT64\"}}]}"
    error_message = "A JSON string return_table_type should be used as written."
  }
  assert {
    condition = (
      google_bigquery_routine.this["udfs.tvf_table_arg"].arguments[0].argument_kind == "FIXED_TABLE" &&
      google_bigquery_routine.this["udfs.tvf_table_arg"].arguments[0].table_type[0].columns[1].name == "n" &&
      google_bigquery_routine.this["udfs.tvf_table_arg"].arguments[0].table_type[0].columns[1].type == "{\"typeKind\":\"INT64\"}"
    )
    error_message = "FIXED_TABLE argument table_type is wrong."
  }
}

run "procedure_and_javascript_from_files" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        routines:
          security_mode: INVOKER
      datasets:
        ops:

      routines:
        proc:
          dataset: ops
          routine_type: PROCEDURE
          arguments:
            - { name: days, data_type: INT64, mode: IN }
            - { name: removed, data_type: INT64, mode: OUT }
          definition_file: sql/procedure.sql
          deletion_policy: PREVENT
        greet:
          dataset: ops
          language: javascript
          determinism_level: DETERMINISTIC
          imported_libraries: [gs://libs/lodash.min.js]
          arguments: [{ name: name, data_type: STRING }]
          return_type: STRING
          definition_file: js/greet.js
    EOT
  }

  assert {
    condition = (
      google_bigquery_routine.this["ops.proc"].routine_type == "PROCEDURE" &&
      trimspace(google_bigquery_routine.this["ops.proc"].definition_body) == "BEGIN\n  SELECT 1;\nEND" &&
      google_bigquery_routine.this["ops.proc"].arguments[1].mode == "OUT" &&
      google_bigquery_routine.this["ops.proc"].deletion_policy == "PREVENT" &&
      google_bigquery_routine.this["ops.proc"].security_mode == "INVOKER"
    )
    error_message = "The procedure is wrong."
  }
  assert {
    condition = (
      google_bigquery_routine.this["ops.greet"].language == "JAVASCRIPT" &&
      trimspace(google_bigquery_routine.this["ops.greet"].definition_body) == "return `Hello, $${name}!`;" &&
      google_bigquery_routine.this["ops.greet"].imported_libraries == tolist(["gs://libs/lodash.min.js"]) &&
      google_bigquery_routine.this["ops.greet"].determinism_level == "DETERMINISTIC"
    )
    error_message = "The JavaScript UDF is wrong (template literals must not be rendered)."
  }
}

run "masking_remote_and_spark_routines" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        udfs:

      routines:
        mask:
          dataset: udfs
          data_governance_type: DATA_MASKING
          arguments: [{ name: s, data_type: STRING }]
          return_type: STRING
          definition_body: SHA256(s)
        remote:
          dataset: udfs
          arguments: [{ name: s, data_type: STRING }]
          return_type: STRING
          remote_function_options:
            endpoint: https://svc.run.app
            connection: projects/test-project/locations/us/connections/remote
            max_batching_rows: 50
            user_defined_context: { mode: fast }
        spark_proc:
          dataset: udfs
          routine_type: PROCEDURE
          language: PYTHON
          spark_options:
            connection: projects/test-project/locations/us/connections/spark
            runtime_version: "2.1"
            main_file_uri: gs://b/job.py
            py_file_uris: [gs://b/lib.py]
            properties: { spark.executor.instances: "2" }
    EOT
  }

  assert {
    condition     = google_bigquery_routine.this["udfs.mask"].data_governance_type == "DATA_MASKING"
    error_message = "data_governance_type was not passed through."
  }
  assert {
    condition = (
      google_bigquery_routine.this["udfs.remote"].definition_body == "" &&
      google_bigquery_routine.this["udfs.remote"].remote_function_options[0].endpoint == "https://svc.run.app" &&
      google_bigquery_routine.this["udfs.remote"].remote_function_options[0].connection == "projects/test-project/locations/us/connections/remote" &&
      google_bigquery_routine.this["udfs.remote"].remote_function_options[0].max_batching_rows == "50" &&
      google_bigquery_routine.this["udfs.remote"].remote_function_options[0].user_defined_context["mode"] == "fast"
    )
    error_message = "The remote function is wrong."
  }
  assert {
    condition = (
      google_bigquery_routine.this["udfs.spark_proc"].definition_body == "" &&
      google_bigquery_routine.this["udfs.spark_proc"].spark_options[0].main_file_uri == "gs://b/job.py" &&
      google_bigquery_routine.this["udfs.spark_proc"].spark_options[0].runtime_version == "2.1" &&
      google_bigquery_routine.this["udfs.spark_proc"].spark_options[0].properties["spark.executor.instances"] == "2"
    )
    error_message = "The Spark procedure is wrong."
  }
}

run "remote_function_connection_key_resolves" {
  command = apply

  variables {
    config_yaml = <<-EOT
      connections:
        remote:
          location: US
          cloud_resource: {}
      datasets:
        udfs:

      routines:
        remote:
          dataset: udfs
          arguments: [{ name: s, data_type: STRING }]
          return_type: STRING
          remote_function_options:
            endpoint: https://svc.run.app
            connection: remote
    EOT
  }

  assert {
    condition     = google_bigquery_routine.this["udfs.remote"].remote_function_options[0].connection == google_bigquery_connection.this["remote"].name
    error_message = "remote_function_options.connection should resolve a connection key."
  }
}

run "routine_iam" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        udfs:

      routines:
        f:
          dataset: udfs
          definition_body: "1"
          iam:
            - role: roles/bigquery.dataViewer
              members: [group:users@example.com]
    EOT
  }

  assert {
    condition = (
      length(google_bigquery_routine_iam_member.this) == 1 &&
      google_bigquery_routine_iam_member.this["udfs.f|roles/bigquery.dataViewer|group:users@example.com"].member == "group:users@example.com"
    )
    error_message = "Routine IAM member is wrong."
  }
}
