# Compartments live in their own stack because OCI deletes a compartment
# asynchronously and slowly (30 minutes or more once emptied), and a deleted
# name cannot be reused until that finishes. Keeping them out of the
# environment stack makes a destroy-and-rebuild of everything else a matter
# of minutes. Nothing here costs money.
locals {
  tags = {
    "hyperfleet-managed-by" = "terraform"
    "hyperfleet-purpose"    = "oci-on-oke-poc"
    "owner"                 = var.owner
  }

  compartments = merge(
    {
      (var.service_compartment_name) = "Service side of the OCI on OKE POC: management cluster, HyperFleet, hosted control planes."
    },
    {
      for c in var.customer_names :
      c => "Customer side of the OCI on OKE POC (${c}): worker VCN, instances, load balancers, volumes."
    },
  )
}

module "compartment" {
  for_each = local.compartments
  source   = "../../modules/compartment/oci"

  parent_compartment_id = var.poc_compartment_id
  name                  = each.key
  description           = each.value
  freeform_tags         = local.tags
}
