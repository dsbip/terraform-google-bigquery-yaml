# -----------------------------------------------------------------------------
# Validation
#
# Every problem in the configuration is collected into local.validation_errors
# (as "<yaml path>: <problem>") and reported by the precondition at the end of
# this file. While there are problems, every resource's for_each is empty
# (local.config_valid), so the plan fails with that list and nothing else.
#
# Rules for code in this file:
# - && and || do not short-circuit in Terraform < 1.12, so conditions that could
#   fail on unexpected input are wrapped in try().
# - contains() with a null value returns an unknown result, which would make
#   config_valid unknown; test `x == null` first (see binding_errors).
# -----------------------------------------------------------------------------

locals {
  # Allowed keys of each schema definition; "root" is the top-level mapping.
  schema_keys = merge(
    { for name, def in local.schema.definitions : name => keys(try(def.properties, {})) },
    { root = keys(local.schema.properties) },
  )

  # Keys that identify or define a single resource and so cannot be defaults.
  defaults_forbidden_keys = {
    for type in keys(local.type_definitions) :
    type => try(local.schema.definitions.defaults.properties[type].allOf[1].propertyNames.not.enum, [])
  }

  # Keys that are meaningful on a dataset with create: false.
  existing_dataset_keys = [
    "dataset_id", "project_id", "create", "location", "access",
    "authorized_views", "authorized_datasets", "authorized_routines",
    "tables", "views", "materialized_views", "routines",
  ]

  secret_names = try(nonsensitive(keys(var.secrets)), keys(var.secrets))

  # ---------------------------------------------------------------------------
  # Mappings: each { path, value, def } is checked to be a mapping whose keys
  # are all properties of schema definition `def` (def = null: any keys).
  # ---------------------------------------------------------------------------

  table_like_children = concat(values(local.children.tables), values(local.children.views), values(local.children.materialized_views))

  mapping_checks = concat(
    [
      { path = "(root)", value = local.config_decoded, def = "root" },
      { path = "defaults", value = try(local.config.defaults, null), def = "defaults" },
      { path = "defaults.labels", value = try(local.defaults.labels, null), def = null },
      { path = "datasets", value = try(local.config.datasets, null), def = null },
      { path = "connections", value = try(local.config.connections, null), def = null },
      { path = "transfers", value = try(local.config.transfers, null), def = null },
    ],
    [for type, def in local.type_definitions : { path = "defaults.${type}", value = try(local.defaults[type], null), def = def }],

    # Datasets
    flatten([
      for k, v in local.datasets_input : [
        { path = "datasets.${k}", value = v, def = "dataset" },
        { path = "datasets.${k}.labels", value = try(v.labels, null), def = null },
        { path = "datasets.${k}.resource_tags", value = try(v.resource_tags, null), def = null },
        { path = "datasets.${k}.default_encryption_configuration", value = try(v.default_encryption_configuration, null), def = "encryption_configuration" },
        { path = "datasets.${k}.external_dataset_reference", value = try(v.external_dataset_reference, null), def = "external_dataset_reference" },
        { path = "datasets.${k}.external_catalog_dataset_options", value = try(v.external_catalog_dataset_options, null), def = "external_catalog_dataset_options" },
        { path = "datasets.${k}.tables", value = try(v.tables, null), def = null },
        { path = "datasets.${k}.views", value = try(v.views, null), def = null },
        { path = "datasets.${k}.materialized_views", value = try(v.materialized_views, null), def = null },
        { path = "datasets.${k}.routines", value = try(v.routines, null), def = null },
      ]
    ]),
    [for ref in local.dataset_ref_items : { path = ref.path, value = ref.value, def = ref.def } if !can(tostring(ref.value))],

    # Tables, views and materialized views
    [for c in values(local.children.tables) : { path = c.path, value = c.value, def = "table" }],
    [for c in values(local.children.views) : { path = c.path, value = c.value, def = "view" }],
    [for c in values(local.children.materialized_views) : { path = c.path, value = c.value, def = "materialized_view" }],
    flatten([
      for c in local.table_like_children : [
        { path = "${c.path}.labels", value = try(c.value.labels, null), def = null },
        { path = "${c.path}.resource_tags", value = try(c.value.resource_tags, null), def = null },
        { path = "${c.path}.time_partitioning", value = try(c.value.time_partitioning, null), def = "time_partitioning" },
        { path = "${c.path}.range_partitioning", value = try(c.value.range_partitioning, null), def = "range_partitioning" },
        { path = "${c.path}.range_partitioning.range", value = try(c.value.range_partitioning.range, null), def = "range" },
        { path = "${c.path}.encryption_configuration", value = try(c.value.encryption_configuration, null), def = "encryption_configuration" },
      ]
    ]),
    flatten([
      for c in values(local.children.tables) : concat(
        [
          { path = "${c.path}.table_constraints", value = try(c.value.table_constraints, null), def = "table_constraints" },
          { path = "${c.path}.table_constraints.primary_key", value = try(c.value.table_constraints.primary_key, null), def = "primary_key" },
          { path = "${c.path}.biglake_configuration", value = try(c.value.biglake_configuration, null), def = "biglake_configuration" },
          { path = "${c.path}.external_data_configuration", value = try(c.value.external_data_configuration, null), def = "external_data_configuration" },
        ],
        [
          for opt, def in {
            csv_options               = "csv_options"
            json_options              = "json_options"
            parquet_options           = "parquet_options"
            avro_options              = "avro_options"
            google_sheets_options     = "google_sheets_options"
            hive_partitioning_options = "hive_partitioning_options"
            bigtable_options          = "bigtable_options"
          } :
          { path = "${c.path}.external_data_configuration.${opt}", value = try(c.value.external_data_configuration[opt], null), def = def }
        ],
        flatten([
          for i, fk in try(concat(c.value.table_constraints.foreign_keys, []), []) : [
            { path = "${c.path}.table_constraints.foreign_keys[${i}]", value = fk, def = "foreign_key" },
            { path = "${c.path}.table_constraints.foreign_keys[${i}].column_references", value = try(fk.column_references, null), def = "column_references" },
            { path = "${c.path}.table_constraints.foreign_keys[${i}].referenced_table", value = can(tostring(try(fk.referenced_table, null))) ? null : try(fk.referenced_table, null), def = "table_ref_object" },
          ]
        ]),
        flatten([
          for i, f in try(concat(c.value.external_data_configuration.bigtable_options.column_family, []), []) : concat(
            [{ path = "${c.path}.external_data_configuration.bigtable_options.column_family[${i}]", value = f, def = "bigtable_column_family" }],
            [for j, col in try(concat(f.column, []), []) : { path = "${c.path}.external_data_configuration.bigtable_options.column_family[${i}].column[${j}]", value = col, def = "bigtable_column" }],
          )
        ]),
      )
    ]),

    # Routines
    flatten([
      for c in values(local.children.routines) : concat(
        [
          { path = c.path, value = c.value, def = "routine" },
          { path = "${c.path}.remote_function_options", value = try(c.value.remote_function_options, null), def = "remote_function_options" },
          { path = "${c.path}.remote_function_options.user_defined_context", value = try(c.value.remote_function_options.user_defined_context, null), def = null },
          { path = "${c.path}.spark_options", value = try(c.value.spark_options, null), def = "spark_options" },
          { path = "${c.path}.spark_options.properties", value = try(c.value.spark_options.properties, null), def = null },
          { path = "${c.path}.return_table_type", value = can(tostring(try(c.value.return_table_type, null))) ? null : try(c.value.return_table_type, null), def = "return_table_type" },
        ],
        [for i, col in try(concat(c.value.return_table_type.columns, []), []) : { path = "${c.path}.return_table_type.columns[${i}]", value = col, def = "table_type_column" }],
        flatten([
          for i, a in try(concat(c.value.arguments, []), []) : concat(
            [
              { path = "${c.path}.arguments[${i}]", value = a, def = "routine_argument" },
              { path = "${c.path}.arguments[${i}].table_type", value = try(a.table_type, null), def = "argument_table_type" },
            ],
            [for j, col in try(concat(a.table_type.columns, []), []) : { path = "${c.path}.arguments[${i}].table_type.columns[${j}]", value = col, def = "table_type_column" }],
          )
        ]),
      )
    ]),

    # Connections
    flatten([
      for k, v in local.connections_input : [
        { path = "connections.${k}", value = v, def = "connection" },
        { path = "connections.${k}.cloud_resource", value = try(v.cloud_resource, null), def = "cloud_resource" },
        { path = "connections.${k}.cloud_sql", value = try(v.cloud_sql, null), def = "cloud_sql" },
        { path = "connections.${k}.cloud_sql.credential", value = try(v.cloud_sql.credential, null), def = "cloud_sql_credential" },
        { path = "connections.${k}.aws", value = try(v.aws, null), def = "aws" },
        { path = "connections.${k}.aws.access_role", value = try(v.aws.access_role, null), def = "aws_access_role" },
        { path = "connections.${k}.azure", value = try(v.azure, null), def = "azure" },
        { path = "connections.${k}.cloud_spanner", value = try(v.cloud_spanner, null), def = "cloud_spanner" },
        { path = "connections.${k}.spark", value = try(v.spark, null), def = "spark" },
        { path = "connections.${k}.spark.metastore_service_config", value = try(v.spark.metastore_service_config, null), def = "spark_metastore_service_config" },
        { path = "connections.${k}.spark.spark_history_server_config", value = try(v.spark.spark_history_server_config, null), def = "spark_history_server_config" },
        { path = "connections.${k}.configuration", value = try(v.configuration, null), def = "connector_configuration" },
        { path = "connections.${k}.configuration.asset", value = try(v.configuration.asset, null), def = "connector_asset" },
        { path = "connections.${k}.configuration.authentication", value = try(v.configuration.authentication, null), def = "connector_authentication" },
        { path = "connections.${k}.configuration.authentication.username_password", value = try(v.configuration.authentication.username_password, null), def = "connector_username_password" },
        { path = "connections.${k}.configuration.endpoint", value = try(v.configuration.endpoint, null), def = "connector_endpoint" },
        { path = "connections.${k}.configuration.network", value = try(v.configuration.network, null), def = "connector_network" },
        { path = "connections.${k}.configuration.network.private_service_connect", value = try(v.configuration.network.private_service_connect, null), def = "connector_private_service_connect" },
      ]
    ]),

    # Transfers
    flatten([
      for k, v in local.transfers_input : [
        { path = "transfers.${k}", value = v, def = "transfer" },
        { path = "transfers.${k}.params", value = try(v.params, null), def = null },
        { path = "transfers.${k}.schedule_options", value = try(v.schedule_options, null), def = "schedule_options" },
        { path = "transfers.${k}.email_preferences", value = try(v.email_preferences, null), def = "email_preferences" },
        { path = "transfers.${k}.encryption_configuration", value = try(v.encryption_configuration, null), def = "encryption_configuration" },
        { path = "transfers.${k}.sensitive_params", value = try(v.sensitive_params, null), def = "sensitive_params" },
      ]
    ]),

    # IAM bindings and dataset access entries
    flatten([
      for e in local.iam_entries : [
        { path = e.path, value = e.value, def = "iam_binding" },
        { path = "${e.path}.condition", value = try(e.value.condition, null), def = "iam_condition" },
      ]
    ]),
    flatten([
      for e in local.access_entries : [
        { path = e.path, value = e.value, def = "access_entry" },
        { path = "${e.path}.condition", value = try(e.value.condition, null), def = "access_condition" },
      ]
    ]),
  )

  unknown_keys = flatten([
    for c in local.mapping_checks : [
      for key in try(keys(c.value), []) : {
        path = c.path
        key  = key
        # Likely intended keys: same letters in another order (transposed
        # typos), or the same first or last three characters.
        suggestions = length(key) < 3 ? [] : [
          for a in local.schema_keys[c.def] : a
          if length(a) >= 3 && (
            join("", sort(split("", a))) == join("", sort(split("", key))) ||
            substr(a, 0, 3) == substr(key, 0, 3) ||
            substr(a, length(a) - 3, 3) == substr(key, length(key) - 3, 3)
          )
        ]
      }
      if !contains(local.schema_keys[c.def], key)
    ]
    if c.def != null
  ])

  mapping_errors = concat(
    [for c in local.mapping_checks : "${c.path}: must be a mapping (key: value pairs)" if c.value != null && !can(keys(c.value))],
    [
      for u in local.unknown_keys : "${u.path}: unknown key \"${u.key}\"${
        length(u.suggestions) == 0 ? "" : " (did you mean ${join(" or ", slice(u.suggestions, 0, min(3, length(u.suggestions))))}?)"
      }"
    ],
  )

  # ---------------------------------------------------------------------------
  # Lists that must be YAML sequences when present
  # ---------------------------------------------------------------------------

  list_checks = concat(
    flatten([
      for k, v in local.datasets_input : [
        for attr in ["access", "authorized_views", "authorized_datasets", "authorized_routines"] :
        { path = "datasets.${k}.${attr}", value = try(v[attr], null) }
      ]
    ]),
    [{ path = "defaults.datasets.access", value = try(local.defaults.datasets.access, null) }],
    [for c in local.table_like_children : { path = "${c.path}.clustering", value = try(c.value.clustering, null) }],
    [for c in local.table_like_children : { path = "${c.path}.iam", value = try(c.value.iam, null) }],
    [for c in values(local.children.tables) : { path = "${c.path}.table_constraints.foreign_keys", value = try(c.value.table_constraints.foreign_keys, null) }],
    [for c in values(local.children.tables) : { path = "${c.path}.external_data_configuration.source_uris", value = try(c.value.external_data_configuration.source_uris, null) }],
    [for c in values(local.children.routines) : { path = "${c.path}.arguments", value = try(c.value.arguments, null) }],
    [for c in values(local.children.routines) : { path = "${c.path}.iam", value = try(c.value.iam, null) }],
    [for c in values(local.children.routines) : { path = "${c.path}.imported_libraries", value = try(c.value.imported_libraries, null) }],
    [for k, v in local.connections_input : { path = "connections.${k}.iam", value = try(v.iam, null) }],
    [for type in ["tables", "views", "materialized_views", "routines", "connections"] : { path = "defaults.${type}.iam", value = try(local.defaults[type].iam, null) }],
  )

  list_errors = [
    for c in local.list_checks : "${c.path}: must be a list" if c.value != null && !can(concat(c.value, []))
  ]

  # ---------------------------------------------------------------------------
  # IAM bindings ({role, members, condition}) and dataset access entries
  # ---------------------------------------------------------------------------

  iam_entries = flatten([
    for l in local.list_checks : [
      for i, b in try(concat(l.value, []), []) : { path = "${l.path}[${i}]", value = b }
    ]
    if endswith(l.path, ".iam")
  ])

  access_entries = flatten([
    for l in local.list_checks : [
      for i, b in try(concat(l.value, []), []) : { path = "${l.path}[${i}]", value = b }
    ]
    if endswith(l.path, ".access")
  ])

  # contains() with a null value returns an unknown result, which would make
  # config_valid unknown; values that may be null are checked with
  # `x == null ? ... : ...` first (a conditional evaluates only the chosen branch's
  # result).
  binding_errors = flatten([
    for e in concat(local.iam_entries, local.access_entries) : concat(
      try(tostring(e.value.role), null) != null ? [] : ["${e.path}.role: is required"],
      try(length(concat(e.value.members, [])) > 0, false) ? [] : ["${e.path}.members: must be a non-empty list"],
      try(e.value.condition, null) != null && try(tostring(e.value.condition.expression), null) == null ? ["${e.path}.condition.expression: is required"] : [],
    )
  ])

  iam_member_errors = flatten([
    for e in local.iam_entries : [
      for i, m in try(concat(e.value.members, []), []) :
      "${e.path}.members[${i}]: \"${try(tostring(m), "?")}\" is not an IAM member (use user:, group:, serviceAccount:, domain:, principal://, principalSet://, allUsers or allAuthenticatedUsers)"
      if m == null ? true : !try(length(regexall(":", m)) > 0 || contains(["allUsers", "allAuthenticatedUsers"], m), false)
    ]
  ])

  iam_condition_errors = [
    for e in local.iam_entries : "${e.path}.condition.title: is required for IAM conditions"
    if try(e.value.condition, null) != null && try(tostring(e.value.condition.title), null) == null
  ]

  access_member_errors = flatten([
    for e in local.access_entries : [
      for i, m in try(concat(e.value.members, []), []) :
      "${e.path}.members[${i}]: \"${try(tostring(m), "?")}\" is not a dataset access member (use user:, serviceAccount:, group:, domain:, specialGroup:, iamMember:, principal://, principalSet://, projectOwners, projectWriters, projectReaders, allAuthenticatedUsers or allUsers)"
      if m == null ? true : !try(
        contains(concat(local.access_special_groups, ["allUsers"]), m) ||
        startswith(m, "principal://") || startswith(m, "principalSet://") ||
        (
          contains(keys(local.access_email_prefixes), split(":", m)[0]) &&
          length(split(":", m)) > 1 &&
          (split(":", m)[0] != "specialGroup" || contains(local.access_special_groups, join(":", slice(split(":", m), 1, length(split(":", m))))))
        ),
        false
      )
    ]
  ])

  # ---------------------------------------------------------------------------
  # Configuration and datasets
  # ---------------------------------------------------------------------------

  resources_without_project = concat(
    [for k, d in local.datasets : d.path if d.project == null],
    [for k, c in local.connections : c.path if c.project == null],
    [for k, t in local.transfers : t.path if t.project == null],
  )

  config_errors = concat(
    var.config_file == null && var.config_yaml == null ? ["Set the config_file or the config_yaml variable."] : [],
    var.config_file != null && var.config_yaml != null ? ["Set only one of the config_file and config_yaml variables."] : [],
    length(local.resources_without_project) > 0 ? [
      "No project ID for ${join(", ", local.resources_without_project)}: set project_id at the top of the YAML file (or on the resource), or pass the module's project_id variable."
    ] : [],
    # Unquoted yes/no/on/off keys are booleans in YAML 1.1 and silently become "true"/"false".
    [
      for path in concat(
        [for k in keys(local.datasets_input) : "datasets.${k}"],
        flatten([for type in local.child_types : [for c in values(local.children[type]) : c.path]]),
        [for k in keys(local.connections_input) : "connections.${k}"],
        [for k in keys(local.transfers_input) : "transfers.${k}"],
      ) : "${path}: YAML read this key as a boolean; quote it (e.g. \"on\":) or pick another key and set the ID explicitly"
      if contains(["true", "false"], element(split(".", path), length(split(".", path)) - 1))
    ],
  )

  dataset_errors = flatten([
    for k, d in local.datasets : concat(
      can(tobool(try(local.datasets_raw[k].create, true))) ? [] : ["${d.path}.create: must be true or false"],
      d.create ? [] : [
        for key in keys(local.datasets_raw[k]) :
        "${d.path}.${key}: has no effect because create is false (the dataset itself is managed elsewhere)"
        if !contains(local.existing_dataset_keys, key)
      ],
      [for e in d.external_dataset_reference : "${d.path}.external_dataset_reference: external_source and connection are required" if e.external_source == null || e.connection == null],
    )
  ])

  duplicate_dataset_errors = [
    for id, paths in { for k, d in local.datasets : "${coalesce(d.project, "<no project>")}.${d.dataset_id}" => d.path... } :
    "${join(" and ", paths)}: resolve to the same dataset ${id}"
    if length(paths) > 1
  ]

  # Authorized views / datasets / routines: every reference must resolve.
  dataset_ref_items = flatten([
    for k, v in local.datasets_input : concat(
      [for i, r in try(concat(v.authorized_views, []), []) : { path = "datasets.${k}.authorized_views[${i}]", value = r, def = "table_ref_object" }],
      [for i, r in try(concat(v.authorized_datasets, []), []) : { path = "datasets.${k}.authorized_datasets[${i}]", value = r, def = "dataset_ref_object" }],
      [for i, r in try(concat(v.authorized_routines, []), []) : { path = "datasets.${k}.authorized_routines[${i}]", value = r, def = "routine_ref_object" }],
    )
  ])

  authorization_errors = concat(
    [
      for e in local.authorized_view_list : "datasets.${e.ds_key}.authorized_views[${e.index}]: cannot resolve ${try(jsonencode(e.ref), "the reference")}; use \"dataset.view\", \"project.dataset.view\" or {project_id, dataset_id, table_id}"
      if e.target.dataset_id == "" || e.target.table_id == ""
    ],
    [
      for e in local.authorized_dataset_list : "datasets.${e.ds_key}.authorized_datasets[${e.index}]: cannot resolve ${try(jsonencode(e.ref), "the reference")}; use \"dataset\", \"project.dataset\" or {project_id, dataset_id}"
      if e.target.dataset_id == ""
    ],
    [
      for e in local.authorized_routine_list : "datasets.${e.ds_key}.authorized_routines[${e.index}]: cannot resolve ${try(jsonencode(e.ref), "the reference")}; use \"dataset.routine\", \"project.dataset.routine\" or {project_id, dataset_id, routine_id}"
      if e.target.dataset_id == "" || e.target.routine_id == ""
    ],
  )

  # ---------------------------------------------------------------------------
  # Tables, views and materialized views
  # ---------------------------------------------------------------------------

  table_errors = flatten([
    for k, t in local.tables : concat(
      can(local.tables_merged[k].schema) && can(local.tables_merged[k].schema_file) ? ["${t.path}: set schema or schema_file, not both"] : [],
      contains(keys(local.file_contents), "tables|${k}|schema_file") && local.table_schemas[k] == null ? ["${t.path}.schema_file: ${local.file_paths["tables|${k}|schema_file"]} is not a JSON or YAML list of fields"] : [],
      !can(local.tables_merged[k].schema_file) && can(local.tables_merged[k].schema) && local.table_schemas[k] == null ? ["${t.path}.schema: must be a list of fields or a JSON string"] : [],
      length(t.time_partitioning) > 0 && length(t.range_partitioning) > 0 ? ["${t.path}: set time_partitioning or range_partitioning, not both"] : [],
      length(t.external_data_configuration) > 0 && length(t.biglake_configuration) > 0 ? ["${t.path}: set external_data_configuration or biglake_configuration, not both"] : [],
      [for p in t.range_partitioning : "${t.path}.range_partitioning: field and range.start, range.end, range.interval are required" if p.field == null || p.start == null || p.end == null || p.interval == null],
      [for e in t.external_data_configuration : "${t.path}.external_data_configuration.source_uris: is required" if try(length(e.source_uris), 0) == 0],
      [for b in t.biglake_configuration : "${t.path}.biglake_configuration: connection_id and storage_uri are required" if b.connection_id == null || b.storage_uri == null],
      flatten([
        for c in t.table_constraints : concat(
          [for i, fk in c.foreign_keys : "${t.path}.table_constraints.foreign_keys[${i}].referenced_table: cannot resolve; use \"dataset.table\", \"project.dataset.table\" or {project_id, dataset_id, table_id}" if fk.referenced_table.dataset_id == "" || fk.referenced_table.table_id == ""],
          [for i, fk in c.foreign_keys : "${t.path}.table_constraints.foreign_keys[${i}].column_references: referencing_column and referenced_column are required" if fk.referencing_column == null || fk.referenced_column == null],
        )
      ]),
    )
  ])

  query_errors = flatten([
    for type, merged in { views = local.views_merged, materialized_views = local.materialized_views_merged } : [
      for k, m in merged : (
        can(m.query) && can(m.query_file) ? "${local.children[type][k].path}: set query or query_file, not both" :
        !can(m.query) && !can(m.query_file) ? "${local.children[type][k].path}: query or query_file is required" :
        ""
      )
    ]
  ])

  materialized_view_errors = flatten([
    for k, v in local.materialized_views : concat(
      length(v.time_partitioning) > 0 && length(v.range_partitioning) > 0 ? ["${v.path}: set time_partitioning or range_partitioning, not both"] : [],
    )
  ])

  duplicate_table_errors = concat(
    # Logical keys must be unique across tables, views and materialized views of a dataset.
    [
      for key, paths in { for c in local.table_like_children : "${c.ds_key}.${c.key}" => c.path... } :
      "${join(" and ", paths)}: tables, views and materialized views in one dataset need distinct keys"
      if length(paths) > 1
    ],
    # Different keys can still resolve to one table through table_id overrides.
    [
      for id, items in {
        for t in concat(values(local.tables), values(local.views), values(local.materialized_views)) :
        "${coalesce(t.project, "<no project>")}.${t.dataset_id}.${t.table_id}" => { path = t.path, key = "${t.ds_key}.${element(split(".", t.path), length(split(".", t.path)) - 1)}" }...
      } :
      "${join(" and ", [for i in items : i.path])}: resolve to the same table ${id}"
      if length(distinct([for i in items : i.key])) > 1
    ],
  )

  # ---------------------------------------------------------------------------
  # Files referenced from the YAML
  # ---------------------------------------------------------------------------

  file_refs = concat(
    flatten([
      for type, attribute in {
        tables             = "schema_file"
        views              = "query_file"
        materialized_views = "query_file"
        routines           = "definition_file"
        } : [
        for k, c in local.children[type] :
        { path = "${c.path}.${attribute}", value = c.raw[attribute], id = "${type}|${k}|${attribute}" }
        if can(c.raw[attribute])
      ]
    ]),
    [
      for k, m in local.transfers_merged :
      { path = "transfers.${k}.query_file", value = m.query_file, id = "transfers|${k}|query_file" }
      if can(m.query_file)
    ],
  )

  all_file_paths = merge(local.file_paths, local.transfer_file_paths)

  file_errors = concat(
    [for f in local.file_refs : "${f.path}: must be a file path" if !can(tostring(f.value))],
    [
      for f in local.file_refs : "${f.path}: file not found: ${local.all_file_paths[f.id]}"
      if can(tostring(f.value)) && !contains(keys(local.file_contents), f.id)
    ],
  )

  # ---------------------------------------------------------------------------
  # Routines
  # ---------------------------------------------------------------------------

  routine_errors = flatten([
    for k, r in local.routines : concat(
      can(local.routines_merged[k].definition_body) && can(local.routines_merged[k].definition_file) ? ["${r.path}: set definition_body or definition_file, not both"] : [],
      !can(local.routines_merged[k].definition_body) && !can(local.routines_merged[k].definition_file) && length(r.remote_function_options) == 0 && length(r.spark_options) == 0 ? ["${r.path}: definition_body or definition_file is required"] : [],
      can(local.routines_merged[k].return_type) && r.return_type == null ? ["${r.path}.return_type: must be a type name, a JSON string or a mapping"] : [],
      can(local.routines_merged[k].return_table_type) && r.return_table_type == null ? ["${r.path}.return_table_type: must be {columns: [{name, type}]} or a JSON string"] : [],
      [
        for i, a in r.arguments : "${r.path}.arguments[${i}].data_type: is required unless argument_kind is ANY_TYPE or FIXED_TABLE"
        if a.data_type == null && (a.argument_kind == null ? true : !try(contains(["ANY_TYPE", "FIXED_TABLE"], a.argument_kind), false))
      ],
    )
  ])

  # ---------------------------------------------------------------------------
  # Names that YAML read as booleans
  #
  # Terraform parses YAML 1.1, where unquoted y, n, yes, no, on, off, true and
  # false are booleans, so a column called n silently becomes "false". Editors
  # use YAML 1.2 and do not flag it, so the module does.
  # ---------------------------------------------------------------------------

  named_items = concat(
    # Table schema fields, three levels deep (inline schemas and schema files).
    flatten([
      for k, s in local.table_schemas : [
        for i, f in try(concat(jsondecode(s), []), []) : concat(
          [{ path = "${local.tables[k].path}.schema[${i}].name", name = try(f.name, null) }],
          flatten([
            for j, g in try(concat(f.fields, []), []) : concat(
              [{ path = "${local.tables[k].path}.schema[${i}].fields[${j}].name", name = try(g.name, null) }],
              [for l, h in try(concat(g.fields, []), []) : { path = "${local.tables[k].path}.schema[${i}].fields[${j}].fields[${l}].name", name = try(h.name, null) }],
            )
          ]),
        )
      ]
      if s != null
    ]),
    # Routine arguments and table-type columns.
    flatten([
      for c in values(local.children.routines) : concat(
        [for i, a in try(concat(c.raw.arguments, []), []) : { path = "${c.path}.arguments[${i}].name", name = try(a.name, null) }],
        [for i, col in try(concat(c.raw.return_table_type.columns, []), []) : { path = "${c.path}.return_table_type.columns[${i}].name", name = try(col.name, null) }],
        flatten([
          for i, a in try(concat(c.raw.arguments, []), []) : [
            for j, col in try(concat(a.table_type.columns, []), []) : { path = "${c.path}.arguments[${i}].table_type.columns[${j}].name", name = try(col.name, null) }
          ]
        ]),
      )
    ]),
  )

  boolean_name_errors = [
    for n in local.named_items : "${n.path}: YAML read this name as the boolean ${n.name}; quote it (e.g. name: \"n\" or name: \"on\")"
    if try(n.name == true || n.name == false, false)
  ]

  # ---------------------------------------------------------------------------
  # Connections (types, secrets) and references to them
  # ---------------------------------------------------------------------------

  connection_errors = flatten([
    for k, c in local.connections : concat(
      length(c.types) == 1 ? [] : [
        "${c.path}: set exactly one connection type (${join(", ", local.connection_types)}); found ${length(c.types) == 0 ? "none" : join(", ", c.types)}"
      ],
      [
        for s in c.cloud_sql : "${c.path}.cloud_sql.credential.password_secret: \"${s.password_secret}\" is not a key of the secrets variable"
        if s.password_secret == null ? false : try(!contains(local.secret_names, s.password_secret), false)
      ],
      [
        for s in c.cloud_sql : "${c.path}.cloud_sql: instance_id, database, type, credential.username and credential.password_secret are required"
        if s.instance_id == null || s.database == null || s.type == null || s.username == null || s.password_secret == null
      ],
      [
        for s in c.configuration : "${c.path}.configuration.authentication.username_password.password_secret: \"${s.password_secret}\" is not a key of the secrets variable"
        if s.password_secret == null ? false : try(!contains(local.secret_names, s.password_secret), false)
      ],
      [
        for s in c.configuration : "${c.path}.configuration: connector_id is required, and authentication.username_password needs both username and password_secret"
        if s.connector_id == null || (s.username == null) != (s.password_secret == null)
      ],
      [for s in c.aws : "${c.path}.aws.access_role.iam_role_id: is required" if s.iam_role_id == null],
    )
  ])

  connection_duplicate_errors = [
    for id, paths in { for k, c in local.connections : "${coalesce(c.project, "<no project>")}.${coalesce(c.location, "<default location>")}.${c.connection_id}" => c.path... } :
    "${join(" and ", paths)}: resolve to the same connection ${id}"
    if length(paths) > 1
  ]

  connection_refs = concat(
    flatten([for k, d in local.datasets : [for e in d.external_dataset_reference : { path = "${d.path}.external_dataset_reference.connection", value = e.connection }]]),
    flatten([for k, t in local.tables : [for e in t.external_data_configuration : { path = "${t.path}.external_data_configuration.connection_id", value = e.connection_id }]]),
    flatten([for k, t in local.tables : [for b in t.biglake_configuration : { path = "${t.path}.biglake_configuration.connection_id", value = b.connection_id }]]),
    flatten([for k, r in local.routines : [for o in r.remote_function_options : { path = "${r.path}.remote_function_options.connection", value = o.connection }]]),
    flatten([for k, r in local.routines : [for o in r.spark_options : { path = "${r.path}.spark_options.connection", value = o.connection }]]),
  )

  # A bare name must be a connection key; qualified IDs are passed through.
  connection_ref_errors = [
    for c in local.connection_refs :
    "${c.path}: \"${c.value}\" is not a key under connections; use a key from this file, project.location.connection_id or projects/P/locations/L/connections/C"
    if c.value == null ? false : try(!contains(keys(local.connections), c.value) && length(regexall("[./]", c.value)) == 0, false)
  ]

  # ---------------------------------------------------------------------------
  # Transfers
  # ---------------------------------------------------------------------------

  transfer_errors = flatten([
    for k, t in local.transfers : concat(
      t.data_source_id == null ? ["${t.path}.data_source_id: is required (e.g. scheduled_query, google_cloud_storage)"] : [],
      length([
        for present in [
          can(local.transfers_merged[k].query),
          can(local.transfers_merged[k].query_file),
          can(local.transfers_merged[k].params.query),
        ] : present if present
      ]) > 1 ? ["${t.path}: set only one of query, query_file and params.query"] : [],
      [
        for pk, pv in try(merge({}, local.transfers_merged[k].params), {}) : "${t.path}.params.${pk}: must be a string, number or boolean"
        if pv != null && !can(tostring(pv))
      ],
      [
        for s in t.sensitive_params : "${t.path}.sensitive_params.secret_access_key_secret: \"${s.secret_access_key_secret}\" is not a key of the secrets variable"
        if s.secret_access_key_secret == null ? false : try(!contains(local.secret_names, s.secret_access_key_secret), false)
      ],
      [for s in t.sensitive_params : "${t.path}.sensitive_params.secret_access_key_secret: is required" if s.secret_access_key_secret == null],
    )
  ])

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  defaults_errors = flatten([
    for type, forbidden in local.defaults_forbidden_keys : [
      for key in try(keys(local.defaults[type]), []) :
      "defaults.${type}.${key}: cannot be a default because it identifies or defines a single resource"
      if contains(forbidden, key)
    ]
  ])

  validation_errors = compact(concat(
    local.config_errors,
    local.mapping_errors,
    local.list_errors,
    local.defaults_errors,
    local.binding_errors,
    local.iam_member_errors,
    local.iam_condition_errors,
    local.access_member_errors,
    local.dataset_errors,
    local.duplicate_dataset_errors,
    local.authorization_errors,
    local.table_errors,
    local.query_errors,
    local.materialized_view_errors,
    local.duplicate_table_errors,
    local.file_errors,
    local.routine_errors,
    local.boolean_name_errors,
    local.connection_errors,
    local.connection_duplicate_errors,
    local.connection_ref_errors,
    local.transfer_errors,
  ))
}

locals {
  # Every resource's for_each is empty while the configuration is invalid. The
  # provider validates each planned instance before any precondition runs, so
  # without this an invalid file would fail with provider errors instead of the
  # message below.
  config_valid = length(local.validation_errors) == 0
}

resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = length(local.validation_errors) == 0
      error_message = "The BigQuery YAML configuration has ${length(local.validation_errors)} problem(s):\n  - ${join("\n  - ", local.validation_errors)}"
    }
  }
}
