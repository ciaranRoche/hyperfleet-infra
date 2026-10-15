# The compartments are created by the stack in ./compartments and looked up by
# name here, so a destroy of this stack never waits on compartment deletion.
data "oci_identity_compartments" "poc" {
  compartment_id = var.poc_compartment_id
  state          = "ACTIVE"
}

locals {
  tags = {
    "hyperfleet-managed-by" = "terraform"
    "hyperfleet-purpose"    = "oci-on-oke-poc"
    "owner"                 = var.owner
  }

  compartments_by_name  = { for c in data.oci_identity_compartments.poc.compartments : c.name => c.id }
  expected_compartments = concat([var.service_compartment_name], keys(var.customer_vcn_cidrs))
  missing_compartments  = [for n in local.expected_compartments : n if !contains(keys(local.compartments_by_name), n)]

  service_compartment_id   = lookup(local.compartments_by_name, var.service_compartment_name, null)
  customer_compartment_ids = { for c in keys(var.customer_vcn_cidrs) : c => lookup(local.compartments_by_name, c, null) }
}

check "compartments_exist" {
  assert {
    condition     = length(local.missing_compartments) == 0
    error_message = "Compartments not found under poc_compartment_id: ${join(", ", local.missing_compartments)}. Apply ./compartments first."
  }
}
