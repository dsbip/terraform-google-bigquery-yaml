# -----------------------------------------------------------------------------
# Configuration loading
#
# The YAML is decoded into plain objects and normalised into one map per
# resource type (datasets.tf, tables.tf, ...). Normalisation never fails on bad
# input: every lookup is wrapped in try() so that validation.tf can report all
# problems at once with YAML paths instead of Terraform stack traces.
# -----------------------------------------------------------------------------

locals {
  # JSON Schema of the configuration file. validation.tf reads the allowed keys
  # of every object from it, so IDE validation and the module cannot disagree.
  schema = jsondecode(file("${path.module}/schemas/bigquery-config.schema.json"))

  # The schema revision these .tf files need ("x-schema-revision" in the file).
  # Bump both whenever the code starts to depend on new content of the schema,
  # so that a copy of the module with an older schema file is reported as such.
  schema_revision = 2

  config_template_vars = try(merge({ project_id = var.project_id }, var.template_vars), { project_id = var.project_id })

  config_text = (
    var.config_yaml != null ? var.config_yaml :
    var.config_file != null ? templatefile(var.config_file, local.config_template_vars) :
    ""
  )

  # yamldecode() rejects documents that are empty or contain only comments.
  config_is_blank = length(regexall("(?m)^[ \\t]*[^#\\s]", local.config_text)) == 0

  # YAML forbids tabs in indentation, and yamldecode() then reports only "found
  # character that cannot start any token". When the file does not parse and
  # has tab-indented lines, validation.tf names those lines instead; any other
  # parse error is left to yamldecode().
  config_tab_lines = [
    for i, line in split("\n", local.config_text) : i + 1 if length(regexall("^[ ]*\\t", line)) > 0
  ]
  config_parses     = local.config_is_blank || can(yamldecode(local.config_text))
  config_tab_failed = !local.config_parses && length(local.config_tab_lines) > 0
  config_decoded    = local.config_is_blank || local.config_tab_failed ? null : yamldecode(local.config_text)
  config            = try(merge({}, local.config_decoded), {})

  project_id = try(coalesce(try(tostring(local.config.project_id), null), var.project_id), null)

  # Relative paths inside the YAML are resolved against this directory.
  base_path = coalesce(var.base_path, var.config_file != null ? dirname(var.config_file) : path.root)

  # -----------------------------------------------------------------------------
  # Defaults
  # -----------------------------------------------------------------------------

  defaults         = try(merge({}, local.config.defaults), {})
  default_location = try(tostring(local.defaults.location), null)
  default_labels   = try(merge(var.labels, local.defaults.labels), var.labels)

  # defaults.<type> key => the schema definition its values are checked against.
  type_definitions = {
    datasets           = "dataset"
    tables             = "table"
    views              = "view"
    materialized_views = "materialized_view"
    routines           = "routine"
    connections        = "connection"
    transfers          = "transfer"
  }

  # Per-type defaults from the YAML. Explicit nulls are dropped so that an empty
  # `key:` line never overrides anything, and keys that cannot be defaults
  # (reported by validation.tf) are ignored so they cannot cause knock-on errors.
  type_defaults = {
    for type in keys(local.type_definitions) : type => {
      for k, v in try(merge({}, local.defaults[type]), {}) : k => v
      if v != null && !contains(local.defaults_forbidden_keys[type], k)
    }
  }

  # Module defaults, applied underneath the YAML defaults.
  builtin_defaults = {
    datasets           = {}
    tables             = {}
    views              = { use_legacy_sql = false, deletion_protection = false }
    materialized_views = {}
    routines           = { routine_type = "SCALAR_FUNCTION" }
    connections        = {}
    transfers          = {}
  }

  # -----------------------------------------------------------------------------
  # Dataset children (tables, views, materialized views, routines)
  #
  # Each is a top-level section whose entries name their dataset with
  # `dataset: <key under datasets>`. Entries are keyed "<dataset key>.<key>",
  # which is also the resource instance key and the output key. `value` is the
  # YAML value as written (for validation); `raw` has explicit nulls removed.
  # -----------------------------------------------------------------------------

  datasets_input = try(merge({}, local.config.datasets), {})

  child_types = ["tables", "views", "materialized_views", "routines"]

  # Grouping (...) keeps a key containing a dot (reported by validation.tf)
  # from colliding with another entry and failing the plan with a Terraform
  # error; the first entry wins.
  children_grouped = {
    for type in local.child_types : type => {
      for key, value in try(merge({}, local.config[type]), {}) :
      "${try(coalesce(tostring(value.dataset), ""), "")}.${key}" => {
        ds_key = try(coalesce(tostring(value.dataset), ""), "")
        key    = key
        path   = "${type}.${key}"
        value  = value
        raw    = { for k, v in try(merge({}, value), {}) : k => v if v != null }
      }...
    }
  }

  children = {
    for type, entries in local.children_grouped : type => { for id, list in entries : id => list[0] }
  }

  # -----------------------------------------------------------------------------
  # Files referenced from the YAML
  # -----------------------------------------------------------------------------

  # Variables for *.tftpl files referenced from the YAML (*_file keys).
  sql_template_vars = try(
    merge(
      {
        project_id = local.project_id
        datasets   = { for k, d in local.datasets : k => d.dataset_id }
      },
      var.template_vars
    ),
    { project_id = local.project_id }
  )

  # "<type>|<key>|<attribute>" => path resolved against base_path, for every
  # *_file attribute of a dataset child (transfers.tf adds transfer query files).
  file_paths = merge(
    [
      for type, attribute in {
        tables             = "schema_file"
        views              = "query_file"
        materialized_views = "query_file"
        routines           = "definition_file"
        } : {
        for key, child in local.children[type] :
        "${type}|${key}|${attribute}" => (
          startswith(child.raw[attribute], "/") || can(regex("^[A-Za-z]:", child.raw[attribute]))
          ? child.raw[attribute]
          : "${local.base_path}/${child.raw[attribute]}"
        )
        if can(tostring(child.raw[attribute]))
      }
    ]...
  )

  # Text of every existing referenced file; *.tftpl files are rendered first.
  # Missing files are left out and reported by validation.tf.
  file_contents = {
    for id, path in merge(local.file_paths, local.transfer_file_paths) :
    id => endswith(path, ".tftpl") ? templatefile(path, local.sql_template_vars) : file(path)
    if try(fileexists(path), false)
  }
}
