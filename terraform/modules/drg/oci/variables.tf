variable "compartment_id" {
  description = "OCID of the compartment the DRG and its route tables land in."
  type        = string
}

variable "name" {
  description = "Display name of the DRG, also the prefix for its route tables."
  type        = string
}

variable "route_tables" {
  description = <<-EOT
    DRG route tables to create, keyed by a short name. A table with
    `import_all_vcn_routes = true` learns every attached VCN's CIDRs (the hub
    pattern); a table with it set to false has only the static rules the caller
    adds with `oci_core_drg_route_table_route_rule` (the isolated spoke
    pattern). Assign a table to an attachment through the VCN module's
    `drg_route_table_id`.
  EOT
  type = map(object({
    import_all_vcn_routes = bool
  }))
}

variable "freeform_tags" {
  description = "Freeform tags applied to every resource in the module."
  type        = map(string)
  default     = {}
}
