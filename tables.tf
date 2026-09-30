# -----------------------------------------------------------------------------
# Tables, views and materialized views
#
# The three kinds are separate resources so that Terraform creates them in
# dependency order: tables -> materialized views -> routines -> views.
# -----------------------------------------------------------------------------

locals {
  tables_merged = {
    for k, c in local.children.tables : k => merge(local.builtin_defaults.tables, local.type_defaults.tables, c.raw)
  }
  views_merged = {
    for k, c in local.children.views : k => merge(local.builtin_defaults.views, local.type_defaults.views, c.raw)
  }
  materialized_views_merged = {
    for k, c in local.children.materialized_views : k => merge(local.builtin_defaults.materialized_views, local.type_defaults.materialized_views, c.raw)
  }

  # Real IDs of every table, keyed like the YAML ("dataset_key.table_key").
  table_ids = {
    for k, m in local.tables_merged : k => {
      project_id = local.datasets[local.children.tables[k].ds_key].project
      dataset_id = local.datasets[local.children.tables[k].ds_key].dataset_id
      table_id   = try(tostring(m.table_id), local.children.tables[k].key)
    }
  }

  # Schema JSON from schema_file (JSON or YAML) or from an inline schema (a list
  # of fields or a JSON string).
  table_schema_candidates = {
    for k, m in local.tables_merged : k => (
      contains(keys(local.file_contents), "tables|${k}|schema_file")
      ? (
        can(regex("(?i)\\.ya?ml(\\.tftpl)?$", local.file_paths["tables|${k}|schema_file"]))
        ? try(jsonencode(yamldecode(local.file_contents["tables|${k}|schema_file"])), null)
        : try(jsonencode(jsondecode(local.file_contents["tables|${k}|schema_file"])), null)
      )
      : try(can(tostring(m.schema)) ? tostring(m.schema) : jsonencode(m.schema), null)
    )
  }

  # Only a list of fields is a schema; anything else (unreadable file, a number,
  # a mapping) becomes null and is reported by validation.tf.
  table_schemas = {
    for k, s in local.table_schema_candidates : k => can(concat(jsondecode(s), [])) ? s : null
  }

  tables = {
    for k, m in local.tables_merged : k => {
      path          = local.children.tables[k].path
      ds_key        = local.children.tables[k].ds_key
      project       = local.table_ids[k].project_id
      dataset_id    = local.table_ids[k].dataset_id
      table_id      = local.table_ids[k].table_id
      friendly_name = try(m.friendly_name, null)
      description   = try(m.description, null)
      labels        = try(merge(local.default_labels, try(local.type_defaults.tables.labels, {}), try(local.children.tables[k].raw.labels, {})), local.default_labels)

      # The provider wants the schema of an external table without a connection
      # inside external_data_configuration, and at the top level otherwise.
      schema = (
        can(m.external_data_configuration) && try(m.external_data_configuration.connection_id, null) == null
        ? null
        : local.table_schemas[k]
      )

      clustering                   = try(length(m.clustering) > 0 ? m.clustering : null, null)
      require_partition_filter     = try(m.require_partition_filter, null)
      expiration_time              = try(m.expiration_time, null)
      deletion_protection          = try(m.deletion_protection, null)
      deletion_policy              = try(m.deletion_policy, null)
      max_staleness                = try(m.max_staleness, null)
      resource_tags                = try(m.resource_tags, null)
      ignore_auto_generated_schema = try(m.ignore_auto_generated_schema, null)
      ignore_schema_changes        = try(m.ignore_schema_changes, null)

      time_partitioning = [
        for p in try([merge({}, m.time_partitioning)], []) : {
          type          = try(coalesce(p.type, "DAY"), "DAY")
          field         = try(p.field, null)
          expiration_ms = try(p.expiration_ms, null)
        }
      ]
      range_partitioning = [
        for p in try([merge({}, m.range_partitioning)], []) : {
          field    = try(p.field, null)
          start    = try(p.range.start, null)
          end      = try(p.range.end, null)
          interval = try(p.range.interval, null)
        }
      ]
      encryption_configuration = [
        for c in try([merge({}, m.encryption_configuration)], []) : {
          kms_key_name = try(c.kms_key_name, null)
        }
      ]

      table_constraints = [
        for c in try([merge({}, m.table_constraints)], []) : {
          primary_key = [for p in try([merge({}, c.primary_key)], []) : try(p.columns, [])]
          foreign_keys = [
            for fk in try(concat(c.foreign_keys, []), []) : {
              name               = try(fk.name, null)
              referencing_column = try(fk.column_references.referencing_column, null)
              referenced_column  = try(fk.column_references.referenced_column, null)
              # Same resolution rules as authorized views (see datasets.tf).
              referenced_table = (
                try(fk.referenced_table, null) == null ? { project_id = "", dataset_id = "", table_id = "" } :
                !can(tostring(fk.referenced_table)) ? {
                  project_id = try(coalesce(tostring(fk.referenced_table.project_id), local.table_ids[k].project_id), local.table_ids[k].project_id)
                  dataset_id = try(coalesce(tostring(fk.referenced_table.dataset_id), ""), "")
                  table_id   = try(coalesce(tostring(fk.referenced_table.table_id), ""), "")
                } :
                contains(keys(local.table_ids), fk.referenced_table) ? local.table_ids[fk.referenced_table] :
                length(split(".", fk.referenced_table)) == 2 ? {
                  project_id = try(local.datasets[split(".", fk.referenced_table)[0]].project, local.table_ids[k].project_id)
                  dataset_id = try(local.datasets[split(".", fk.referenced_table)[0]].dataset_id, split(".", fk.referenced_table)[0])
                  table_id   = split(".", fk.referenced_table)[1]
                } :
                length(split(".", fk.referenced_table)) > 2 ? {
                  project_id = join(".", slice(split(".", fk.referenced_table), 0, length(split(".", fk.referenced_table)) - 2))
                  dataset_id = split(".", fk.referenced_table)[length(split(".", fk.referenced_table)) - 2]
                  table_id   = split(".", fk.referenced_table)[length(split(".", fk.referenced_table)) - 1]
                } :
                { project_id = "", dataset_id = "", table_id = "" }
              )
            }
          ]
        }
      ]

      external_data_configuration = [
        for e in try([merge({}, m.external_data_configuration)], []) : {
          # Autodetect unless a schema is given.
          autodetect                = try(tobool(e.autodetect), local.table_schemas[k] == null)
          source_uris               = try(e.source_uris, null)
          source_format             = try(e.source_format, null)
          compression               = try(e.compression, null)
          connection_id             = try(e.connection_id, null)
          ignore_unknown_values     = try(e.ignore_unknown_values, null)
          max_bad_records           = try(e.max_bad_records, null)
          json_extension            = try(e.json_extension, null)
          metadata_cache_mode       = try(e.metadata_cache_mode, null)
          object_metadata           = try(e.object_metadata, null)
          reference_file_schema_uri = try(e.reference_file_schema_uri, null)
          file_set_spec_type        = try(e.file_set_spec_type, null)
          decimal_target_types      = try(e.decimal_target_types, null)
          schema                    = try(e.connection_id, null) == null ? local.table_schemas[k] : null

          csv_options = [
            for o in try([merge({}, e.csv_options)], []) : {
              quote                 = try(o.quote != null ? o.quote : "\"", "\"")
              allow_jagged_rows     = try(o.allow_jagged_rows, null)
              allow_quoted_newlines = try(o.allow_quoted_newlines, null)
              encoding              = try(o.encoding, null)
              field_delimiter       = try(o.field_delimiter, null)
              skip_leading_rows     = try(o.skip_leading_rows, null)
              source_column_match   = try(o.source_column_match, null)
            }
          ]
          json_options = [
            for o in try([merge({}, e.json_options)], []) : {
              encoding = try(o.encoding, null)
            }
          ]
          parquet_options = [
            for o in try([merge({}, e.parquet_options)], []) : {
              enum_as_string        = try(o.enum_as_string, null)
              enable_list_inference = try(o.enable_list_inference, null)
            }
          ]
          avro_options = [
            for o in try([merge({}, e.avro_options)], []) : {
              use_avro_logical_types = try(tobool(o.use_avro_logical_types), false)
            }
          ]
          google_sheets_options = [
            for o in try([merge({}, e.google_sheets_options)], []) : {
              range             = try(o.range, null)
              skip_leading_rows = try(o.skip_leading_rows, null)
            }
          ]
          hive_partitioning_options = [
            for o in try([merge({}, e.hive_partitioning_options)], []) : {
              mode                     = try(o.mode, null)
              require_partition_filter = try(o.require_partition_filter, null)
              source_uri_prefix        = try(o.source_uri_prefix, null)
            }
          ]
          bigtable_options = [
            for o in try([merge({}, e.bigtable_options)], []) : {
              ignore_unspecified_column_families = try(o.ignore_unspecified_column_families, null)
              read_rowkey_as_string              = try(o.read_rowkey_as_string, null)
              output_column_families_as_json     = try(o.output_column_families_as_json, null)
              column_family = [
                for f in try(concat(o.column_family, []), []) : {
                  family_id        = try(f.family_id, null)
                  type             = try(f.type, null)
                  encoding         = try(f.encoding, null)
                  only_read_latest = try(f.only_read_latest, null)
                  column = [
                    for col in try(concat(f.column, []), []) : {
                      qualifier_encoded = try(col.qualifier_encoded, null)
                      qualifier_string  = try(col.qualifier_string, null)
                      field_name        = try(col.field_name, null)
                      type              = try(col.type, null)
                      encoding          = try(col.encoding, null)
                      only_read_latest  = try(col.only_read_latest, null)
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]

      biglake_configuration = [
        for b in try([merge({}, m.biglake_configuration)], []) : {
          connection_id = try(b.connection_id, null)
          storage_uri   = try(b.storage_uri, null)
          file_format   = try(coalesce(b.file_format, "PARQUET"), "PARQUET")
          table_format  = try(coalesce(b.table_format, "ICEBERG"), "ICEBERG")
        }
      ]

      iam = try(concat(m.iam, []), [])
    }
  }

  views = {
    for k, m in local.views_merged : k => {
      path                = local.children.views[k].path
      ds_key              = local.children.views[k].ds_key
      project             = local.datasets[local.children.views[k].ds_key].project
      dataset_id          = local.datasets[local.children.views[k].ds_key].dataset_id
      table_id            = try(tostring(m.table_id), local.children.views[k].key)
      friendly_name       = try(m.friendly_name, null)
      description         = try(m.description, null)
      labels              = try(merge(local.default_labels, try(local.type_defaults.views.labels, {}), try(local.children.views[k].raw.labels, {})), local.default_labels)
      query               = try(local.file_contents["views|${k}|query_file"], tostring(m.query), null)
      use_legacy_sql      = try(tobool(m.use_legacy_sql), false)
      expiration_time     = try(m.expiration_time, null)
      deletion_protection = try(tobool(m.deletion_protection), false)
      deletion_policy     = try(m.deletion_policy, null)
      resource_tags       = try(m.resource_tags, null)
      iam                 = try(concat(m.iam, []), [])
    }
  }

  materialized_views = {
    for k, m in local.materialized_views_merged : k => {
      path                             = local.children.materialized_views[k].path
      ds_key                           = local.children.materialized_views[k].ds_key
      project                          = local.datasets[local.children.materialized_views[k].ds_key].project
      dataset_id                       = local.datasets[local.children.materialized_views[k].ds_key].dataset_id
      table_id                         = try(tostring(m.table_id), local.children.materialized_views[k].key)
      friendly_name                    = try(m.friendly_name, null)
      description                      = try(m.description, null)
      labels                           = try(merge(local.default_labels, try(local.type_defaults.materialized_views.labels, {}), try(local.children.materialized_views[k].raw.labels, {})), local.default_labels)
      query                            = try(local.file_contents["materialized_views|${k}|query_file"], tostring(m.query), null)
      enable_refresh                   = try(m.enable_refresh, null)
      refresh_interval_ms              = try(m.refresh_interval_ms, null)
      allow_non_incremental_definition = try(m.allow_non_incremental_definition, null)
      clustering                       = try(length(m.clustering) > 0 ? m.clustering : null, null)
      expiration_time                  = try(m.expiration_time, null)
      max_staleness                    = try(m.max_staleness, null)
      deletion_protection              = try(m.deletion_protection, null)
      deletion_policy                  = try(m.deletion_policy, null)
      resource_tags                    = try(m.resource_tags, null)

      time_partitioning = [
        for p in try([merge({}, m.time_partitioning)], []) : {
          type          = try(coalesce(p.type, "DAY"), "DAY")
          field         = try(p.field, null)
          expiration_ms = try(p.expiration_ms, null)
        }
      ]
      range_partitioning = [
        for p in try([merge({}, m.range_partitioning)], []) : {
          field    = try(p.field, null)
          start    = try(p.range.start, null)
          end      = try(p.range.end, null)
          interval = try(p.range.interval, null)
        }
      ]
      encryption_configuration = [
        for c in try([merge({}, m.encryption_configuration)], []) : {
          kms_key_name = try(c.kms_key_name, null)
        }
      ]

      iam = try(concat(m.iam, []), [])
    }
  }
}

resource "google_bigquery_table" "table" {
  for_each = { for k, v in local.tables : k => v if local.config_valid }

  project                      = each.value.project
  dataset_id                   = each.value.dataset_id
  table_id                     = each.value.table_id
  friendly_name                = each.value.friendly_name
  description                  = each.value.description
  labels                       = each.value.labels
  schema                       = each.value.schema
  clustering                   = each.value.clustering
  require_partition_filter     = each.value.require_partition_filter
  expiration_time              = each.value.expiration_time
  deletion_protection          = each.value.deletion_protection
  deletion_policy              = each.value.deletion_policy
  max_staleness                = each.value.max_staleness
  resource_tags                = each.value.resource_tags
  ignore_auto_generated_schema = each.value.ignore_auto_generated_schema
  ignore_schema_changes        = each.value.ignore_schema_changes

  dynamic "time_partitioning" {
    for_each = each.value.time_partitioning
    content {
      type          = time_partitioning.value.type
      field         = time_partitioning.value.field
      expiration_ms = time_partitioning.value.expiration_ms
    }
  }

  dynamic "range_partitioning" {
    for_each = each.value.range_partitioning
    content {
      field = range_partitioning.value.field
      range {
        start    = range_partitioning.value.start
        end      = range_partitioning.value.end
        interval = range_partitioning.value.interval
      }
    }
  }

  dynamic "encryption_configuration" {
    for_each = each.value.encryption_configuration
    content {
      kms_key_name = encryption_configuration.value.kms_key_name
    }
  }

  dynamic "table_constraints" {
    for_each = each.value.table_constraints
    content {
      dynamic "primary_key" {
        for_each = table_constraints.value.primary_key
        content {
          columns = primary_key.value
        }
      }

      dynamic "foreign_keys" {
        for_each = table_constraints.value.foreign_keys
        content {
          name = foreign_keys.value.name
          referenced_table {
            project_id = foreign_keys.value.referenced_table.project_id
            dataset_id = foreign_keys.value.referenced_table.dataset_id
            table_id   = foreign_keys.value.referenced_table.table_id
          }
          column_references {
            referencing_column = foreign_keys.value.referencing_column
            referenced_column  = foreign_keys.value.referenced_column
          }
        }
      }
    }
  }

  dynamic "external_data_configuration" {
    for_each = each.value.external_data_configuration
    iterator = edc
    content {
      autodetect                = edc.value.autodetect
      source_uris               = edc.value.source_uris
      source_format             = edc.value.source_format
      compression               = edc.value.compression
      connection_id             = try(google_bigquery_connection.this[edc.value.connection_id].name, edc.value.connection_id)
      ignore_unknown_values     = edc.value.ignore_unknown_values
      max_bad_records           = edc.value.max_bad_records
      json_extension            = edc.value.json_extension
      metadata_cache_mode       = edc.value.metadata_cache_mode
      object_metadata           = edc.value.object_metadata
      reference_file_schema_uri = edc.value.reference_file_schema_uri
      file_set_spec_type        = edc.value.file_set_spec_type
      decimal_target_types      = edc.value.decimal_target_types
      schema                    = edc.value.schema

      dynamic "csv_options" {
        for_each = edc.value.csv_options
        content {
          quote                 = csv_options.value.quote
          allow_jagged_rows     = csv_options.value.allow_jagged_rows
          allow_quoted_newlines = csv_options.value.allow_quoted_newlines
          encoding              = csv_options.value.encoding
          field_delimiter       = csv_options.value.field_delimiter
          skip_leading_rows     = csv_options.value.skip_leading_rows
          source_column_match   = csv_options.value.source_column_match
        }
      }

      dynamic "json_options" {
        for_each = edc.value.json_options
        content {
          encoding = json_options.value.encoding
        }
      }

      dynamic "parquet_options" {
        for_each = edc.value.parquet_options
        content {
          enum_as_string        = parquet_options.value.enum_as_string
          enable_list_inference = parquet_options.value.enable_list_inference
        }
      }

      dynamic "avro_options" {
        for_each = edc.value.avro_options
        content {
          use_avro_logical_types = avro_options.value.use_avro_logical_types
        }
      }

      dynamic "google_sheets_options" {
        for_each = edc.value.google_sheets_options
        content {
          range             = google_sheets_options.value.range
          skip_leading_rows = google_sheets_options.value.skip_leading_rows
        }
      }

      dynamic "hive_partitioning_options" {
        for_each = edc.value.hive_partitioning_options
        content {
          mode                     = hive_partitioning_options.value.mode
          require_partition_filter = hive_partitioning_options.value.require_partition_filter
          source_uri_prefix        = hive_partitioning_options.value.source_uri_prefix
        }
      }

      dynamic "bigtable_options" {
        for_each = edc.value.bigtable_options
        content {
          ignore_unspecified_column_families = bigtable_options.value.ignore_unspecified_column_families
          read_rowkey_as_string              = bigtable_options.value.read_rowkey_as_string
          output_column_families_as_json     = bigtable_options.value.output_column_families_as_json

          dynamic "column_family" {
            for_each = bigtable_options.value.column_family
            content {
              family_id        = column_family.value.family_id
              type             = column_family.value.type
              encoding         = column_family.value.encoding
              only_read_latest = column_family.value.only_read_latest

              dynamic "column" {
                for_each = column_family.value.column
                content {
                  qualifier_encoded = column.value.qualifier_encoded
                  qualifier_string  = column.value.qualifier_string
                  field_name        = column.value.field_name
                  type              = column.value.type
                  encoding          = column.value.encoding
                  only_read_latest  = column.value.only_read_latest
                }
              }
            }
          }
        }
      }
    }
  }

  dynamic "biglake_configuration" {
    for_each = each.value.biglake_configuration
    content {
      connection_id = try(google_bigquery_connection.this[biglake_configuration.value.connection_id].name, biglake_configuration.value.connection_id)
      storage_uri   = biglake_configuration.value.storage_uri
      file_format   = biglake_configuration.value.file_format
      table_format  = biglake_configuration.value.table_format
    }
  }

  depends_on = [terraform_data.validation, google_bigquery_dataset.this]
}

resource "google_bigquery_table" "materialized_view" {
  for_each = { for k, v in local.materialized_views : k => v if local.config_valid }

  project             = each.value.project
  dataset_id          = each.value.dataset_id
  table_id            = each.value.table_id
  friendly_name       = each.value.friendly_name
  description         = each.value.description
  labels              = each.value.labels
  clustering          = each.value.clustering
  expiration_time     = each.value.expiration_time
  max_staleness       = each.value.max_staleness
  deletion_protection = each.value.deletion_protection
  deletion_policy     = each.value.deletion_policy
  resource_tags       = each.value.resource_tags

  materialized_view {
    query                            = each.value.query
    enable_refresh                   = each.value.enable_refresh
    refresh_interval_ms              = each.value.refresh_interval_ms
    allow_non_incremental_definition = each.value.allow_non_incremental_definition
  }

  dynamic "time_partitioning" {
    for_each = each.value.time_partitioning
    content {
      type          = time_partitioning.value.type
      field         = time_partitioning.value.field
      expiration_ms = time_partitioning.value.expiration_ms
    }
  }

  dynamic "range_partitioning" {
    for_each = each.value.range_partitioning
    content {
      field = range_partitioning.value.field
      range {
        start    = range_partitioning.value.start
        end      = range_partitioning.value.end
        interval = range_partitioning.value.interval
      }
    }
  }

  dynamic "encryption_configuration" {
    for_each = each.value.encryption_configuration
    content {
      kms_key_name = encryption_configuration.value.kms_key_name
    }
  }

  depends_on = [terraform_data.validation, google_bigquery_dataset.this, google_bigquery_table.table]
}

resource "google_bigquery_table" "view" {
  for_each = { for k, v in local.views : k => v if local.config_valid }

  project             = each.value.project
  dataset_id          = each.value.dataset_id
  table_id            = each.value.table_id
  friendly_name       = each.value.friendly_name
  description         = each.value.description
  labels              = each.value.labels
  expiration_time     = each.value.expiration_time
  deletion_protection = each.value.deletion_protection
  deletion_policy     = each.value.deletion_policy
  resource_tags       = each.value.resource_tags

  view {
    query          = each.value.query
    use_legacy_sql = each.value.use_legacy_sql
  }

  # Views are validated by BigQuery on creation, so everything they may select
  # from (tables, materialized views, UDFs) must exist first.
  depends_on = [
    terraform_data.validation,
    google_bigquery_dataset.this,
    google_bigquery_table.table,
    google_bigquery_table.materialized_view,
    google_bigquery_routine.this,
  ]
}

# -----------------------------------------------------------------------------
# Table / view IAM (tables.*.iam, views.*.iam, materialized_views.*.iam)
# -----------------------------------------------------------------------------

locals {
  table_iam_list = flatten([
    for k, t in merge(local.tables, local.materialized_views, local.views) : [
      for binding in t.iam : [
        for member in try(concat(binding.members, []), []) : {
          table_key  = k
          project    = t.project
          dataset_id = t.dataset_id
          table_id   = t.table_id
          role       = try(coalesce(tostring(binding.role), ""), "")
          member     = try(coalesce(tostring(member), ""), "")
          condition  = try(merge({}, binding.condition), null)
        }
      ]
    ]
  ])

  table_iam = {
    for e in local.table_iam_list : "${e.table_key}|${e.role}|${e.member}" => e...
  }
}

resource "google_bigquery_table_iam_member" "this" {
  for_each = { for k, v in local.table_iam : k => v[0] if local.config_valid }

  project    = each.value.project
  dataset_id = each.value.dataset_id
  table_id   = each.value.table_id
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

  depends_on = [
    terraform_data.validation,
    google_bigquery_table.table,
    google_bigquery_table.materialized_view,
    google_bigquery_table.view,
  ]
}
