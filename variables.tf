variable "config_file" {
  description = <<-EOT
    Path to the YAML configuration file. The file is rendered with templatefile()
    before it is parsed, so $${name} placeholders are replaced with values from
    template_vars (project_id is always available). Write $$${ in the file to get
    a literal $${. Exactly one of config_file and config_yaml must be set.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.config_file == null || try(fileexists(var.config_file), false)
    error_message = "The config_file variable must point to an existing file."
  }
}

variable "config_yaml" {
  description = <<-EOT
    YAML configuration as a string, e.g. yamlencode({...}) or the output of your
    own templatefile() call. It is used as-is (not template-rendered).
    Exactly one of config_file and config_yaml must be set.
  EOT
  type        = string
  default     = null
}

variable "template_vars" {
  description = <<-EOT
    Values for $${...} placeholders in config_file and in any referenced *.tftpl
    file (query_file, definition_file). project_id is added automatically.
    Values must be known at plan time.
  EOT
  type        = any
  default     = {}

  validation {
    condition     = can(merge({}, var.template_vars))
    error_message = "The template_vars variable must be a map or object."
  }
}

variable "project_id" {
  description = "Default project for every resource. Used when the YAML has no top-level project_id; resource-level project_id values take precedence over both."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels added to every dataset, table, view and materialized view. YAML labels with the same key take precedence."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = <<-EOT
    Sensitive values that the YAML references by name, so they never appear in the
    configuration file: connections.*.cloud_sql.credential.password_secret,
    connections.*.configuration.authentication.username_password.password_secret and
    transfers.*.sensitive_params.secret_access_key_secret.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "base_path" {
  description = "Directory that relative paths in the YAML (schema_file, query_file, definition_file) are resolved against. Defaults to the directory of config_file, or path.root when config_yaml is used."
  type        = string
  default     = null
}
