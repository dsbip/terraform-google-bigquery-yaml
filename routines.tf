# -----------------------------------------------------------------------------
# Routines: UDFs, table-valued functions and stored procedures
#
# Data types accept three spellings, all converted to StandardSqlDataType JSON:
#   data_type: INT64                                  -> {"typeKind":"INT64"}
#   data_type: {typeKind: ARRAY, arrayElementType: {typeKind: STRING}}
#   data_type: '{"typeKind":"STRING"}'                -> used as written
# Legacy names (INTEGER, FLOAT, BOOLEAN, ...) are mapped to GoogleSQL ones.
# -----------------------------------------------------------------------------

locals {
  sql_type_aliases = {
    INTEGER    = "INT64"
    INT        = "INT64"
    FLOAT      = "FLOAT64"
    BOOLEAN    = "BOOL"
    DECIMAL    = "NUMERIC"
    BIGDECIMAL = "BIGNUMERIC"
  }

  routines_merged = {
    for k, c in local.children.routines : k => merge(local.builtin_defaults.routines, local.type_defaults.routines, c.raw)
  }

  routines = {
    for k, m in local.routines_merged : k => {
      path                 = local.children.routines[k].path
      ds_key               = local.children.routines[k].ds_key
      project              = local.datasets[local.children.routines[k].ds_key].project
      dataset_id           = local.datasets[local.children.routines[k].ds_key].dataset_id
      routine_id           = try(tostring(m.routine_id), local.children.routines[k].key)
      routine_type         = try(upper(tostring(m.routine_type)), "SCALAR_FUNCTION")
      language             = try(upper(tostring(m.language)), null)
      description          = try(m.description, null)
      imported_libraries   = try(m.imported_libraries, null)
      determinism_level    = try(m.determinism_level, null)
      data_governance_type = try(m.data_governance_type, null)
      security_mode        = try(m.security_mode, null)
      deletion_policy      = try(m.deletion_policy, null)

      # Remote functions and Spark procedures may have an empty body.
      definition_body = try(local.file_contents["routines|${k}|definition_file"], tostring(m.definition_body), "")

      return_type = try(
        can(tostring(m.return_type))
        ? (startswith(trimspace(m.return_type), "{") ? trimspace(m.return_type) : jsonencode({ typeKind = lookup(local.sql_type_aliases, upper(trimspace(m.return_type)), upper(trimspace(m.return_type))) }))
        : jsonencode(m.return_type),
        null
      )

      return_table_type = try(
        can(tostring(m.return_table_type))
        ? trimspace(m.return_table_type)
        : jsonencode({
          columns = [
            for col in m.return_table_type.columns : {
              name = col.name
              type = jsondecode(
                can(tostring(col.type))
                ? (startswith(trimspace(col.type), "{") ? trimspace(col.type) : jsonencode({ typeKind = lookup(local.sql_type_aliases, upper(trimspace(col.type)), upper(trimspace(col.type))) }))
                : jsonencode(col.type)
              )
            }
          ]
        }),
        null
      )

      arguments = [
        for a in try(concat(m.arguments, []), []) : {
          name          = try(a.name, null)
          argument_kind = try(a.argument_kind, null)
          mode          = try(a.mode, null)
          data_type = try(
            can(tostring(a.data_type))
            ? (startswith(trimspace(a.data_type), "{") ? trimspace(a.data_type) : jsonencode({ typeKind = lookup(local.sql_type_aliases, upper(trimspace(a.data_type)), upper(trimspace(a.data_type))) }))
            : jsonencode(a.data_type),
            null
          )
          table_type = [
            for tt in try([merge({}, a.table_type)], []) : [
              for col in try(concat(tt.columns, []), []) : {
                name = try(col.name, null)
                type = try(
                  can(tostring(col.type))
                  ? (startswith(trimspace(col.type), "{") ? trimspace(col.type) : jsonencode({ typeKind = lookup(local.sql_type_aliases, upper(trimspace(col.type)), upper(trimspace(col.type))) }))
                  : jsonencode(col.type),
                  null
                )
              }
            ]
          ]
        }
      ]

      remote_function_options = [
        for r in try([merge({}, m.remote_function_options)], []) : {
          endpoint             = try(r.endpoint, null)
          connection           = try(r.connection, null)
          max_batching_rows    = try(tostring(r.max_batching_rows), null)
          user_defined_context = try(r.user_defined_context, null)
        }
      ]

      spark_options = [
        for s in try([merge({}, m.spark_options)], []) : {
          connection      = try(s.connection, null)
          runtime_version = try(s.runtime_version, null)
          container_image = try(s.container_image, null)
          properties      = try(s.properties, null)
          main_file_uri   = try(s.main_file_uri, null)
          main_class      = try(s.main_class, null)
          py_file_uris    = try(s.py_file_uris, null)
          jar_uris        = try(s.jar_uris, null)
          file_uris       = try(s.file_uris, null)
          archive_uris    = try(s.archive_uris, null)
        }
      ]

      iam = try(concat(m.iam, []), [])
    }
  }
}

resource "google_bigquery_routine" "this" {
  for_each = { for k, v in local.routines : k => v if local.config_valid }

  project              = each.value.project
  dataset_id           = each.value.dataset_id
  routine_id           = each.value.routine_id
  routine_type         = each.value.routine_type
  language             = each.value.language
  definition_body      = each.value.definition_body
  description          = each.value.description
  return_type          = each.value.return_type
  return_table_type    = each.value.return_table_type
  imported_libraries   = each.value.imported_libraries
  determinism_level    = each.value.determinism_level
  data_governance_type = each.value.data_governance_type
  security_mode        = each.value.security_mode
  deletion_policy      = each.value.deletion_policy

  dynamic "arguments" {
    for_each = each.value.arguments
    content {
      name          = arguments.value.name
      argument_kind = arguments.value.argument_kind
      mode          = arguments.value.mode
      data_type     = arguments.value.data_type

      dynamic "table_type" {
        for_each = arguments.value.table_type
        content {
          dynamic "columns" {
            for_each = table_type.value
            content {
              name = columns.value.name
              type = columns.value.type
            }
          }
        }
      }
    }
  }

  dynamic "remote_function_options" {
    for_each = each.value.remote_function_options
    content {
      endpoint             = remote_function_options.value.endpoint
      connection           = try(google_bigquery_connection.this[remote_function_options.value.connection].name, remote_function_options.value.connection)
      max_batching_rows    = remote_function_options.value.max_batching_rows
      user_defined_context = remote_function_options.value.user_defined_context
    }
  }

  dynamic "spark_options" {
    for_each = each.value.spark_options
    content {
      connection      = try(google_bigquery_connection.this[spark_options.value.connection].name, spark_options.value.connection)
      runtime_version = spark_options.value.runtime_version
      container_image = spark_options.value.container_image
      properties      = spark_options.value.properties
      main_file_uri   = spark_options.value.main_file_uri
      main_class      = spark_options.value.main_class
      py_file_uris    = spark_options.value.py_file_uris
      jar_uris        = spark_options.value.jar_uris
      file_uris       = spark_options.value.file_uris
      archive_uris    = spark_options.value.archive_uris
    }
  }

  # Functions and procedures can select from tables and materialized views.
  depends_on = [
    terraform_data.validation,
    google_bigquery_dataset.this,
    google_bigquery_table.table,
    google_bigquery_table.materialized_view,
  ]
}

# -----------------------------------------------------------------------------
# Routine IAM (routines.*.iam)
# -----------------------------------------------------------------------------

locals {
  routine_iam_list = flatten([
    for k, r in local.routines : [
      for binding in r.iam : [
        for member in try(concat(binding.members, []), []) : {
          routine_key = k
          role        = try(coalesce(tostring(binding.role), ""), "")
          member      = try(coalesce(tostring(member), ""), "")
          condition   = try(merge({}, binding.condition), null)
        }
      ]
    ]
  ])

  routine_iam = {
    for e in local.routine_iam_list : "${e.routine_key}|${e.role}|${e.member}" => e...
  }
}

resource "google_bigquery_routine_iam_member" "this" {
  for_each = { for k, v in local.routine_iam : k => v[0] if local.config_valid }

  project    = google_bigquery_routine.this[each.value.routine_key].project
  dataset_id = google_bigquery_routine.this[each.value.routine_key].dataset_id
  routine_id = google_bigquery_routine.this[each.value.routine_key].routine_id
  role       = each.value.role
  member     = each.value.member

  dynamic "condition" {
    for_each = each.value.condition == null ? [] : [each.value.condition]
    content {
      title       = try(condition.value.title, null)
      expression  = try(condition.value.expression, null)
      description = try(condition.value.description, null)
    }
  }
}
