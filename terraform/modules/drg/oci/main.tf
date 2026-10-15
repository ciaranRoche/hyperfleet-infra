resource "oci_core_drg" "this" {
  compartment_id = var.compartment_id
  display_name   = var.name
  freeform_tags  = var.freeform_tags
}

locals {
  hub_tables = { for k, t in var.route_tables : k => t if t.import_all_vcn_routes }
}

# One import distribution per hub table: import routes from every VCN
# attachment of the DRG, so the hub reaches all spokes.
resource "oci_core_drg_route_distribution" "import_all" {
  for_each = local.hub_tables

  drg_id            = oci_core_drg.this.id
  distribution_type = "IMPORT"
  display_name      = "${var.name}-${each.key}-import-all-vcn"
  freeform_tags     = var.freeform_tags
}

resource "oci_core_drg_route_distribution_statement" "import_all" {
  for_each = local.hub_tables

  drg_route_distribution_id = oci_core_drg_route_distribution.import_all[each.key].id
  action                    = "ACCEPT"
  priority                  = 1

  match_criteria {
    match_type      = "DRG_ATTACHMENT_TYPE"
    attachment_type = "VCN"
  }
}

# Spoke tables get no import distribution, so they carry only the static rules
# the caller adds. That absence is what keeps spokes from reaching each other.
resource "oci_core_drg_route_table" "this" {
  for_each = var.route_tables

  drg_id                           = oci_core_drg.this.id
  display_name                     = "${var.name}-${each.key}"
  import_drg_route_distribution_id = each.value.import_all_vcn_routes ? oci_core_drg_route_distribution.import_all[each.key].id : null
  freeform_tags                    = var.freeform_tags
}
