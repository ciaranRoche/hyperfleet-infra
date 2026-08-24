locals {
  common_tags = {
    owner      = var.owner
    managed-by = "terraform"
    project    = "hyperfleet-poc"
  }
}

# =============================================================================
# Network (VCN, subnets, gateways)
# =============================================================================
module "network" {
  source = "../modules/network/oci-vcn"

  compartment_id = var.compartment_id
  vcn_name       = "${var.name_prefix}-vcn"
  vcn_cidr       = var.vcn_cidr
  freeform_tags  = local.common_tags
}

# =============================================================================
# OKE cluster
# =============================================================================
module "oke" {
  source = "../modules/cluster/oke"

  compartment_id     = var.compartment_id
  cluster_name       = "${var.name_prefix}-oke"
  vcn_id             = module.network.vcn_id
  endpoint_subnet_id = module.network.public_subnet_id
  lb_subnet_id       = module.network.public_subnet_id
  node_subnet_id     = module.network.private_subnet_id
  kubernetes_version = var.kubernetes_version
  node_count         = var.node_count
  node_shape         = var.node_shape
  node_ocpus         = var.node_ocpus
  node_memory_gbs    = var.node_memory_gbs
  freeform_tags      = local.common_tags
}

# =============================================================================
# Container registry repositories
# =============================================================================
resource "oci_artifacts_container_repository" "this" {
  for_each = toset(var.registry_repo_names)

  compartment_id = var.compartment_id
  display_name   = each.value
  is_public      = false
  freeform_tags  = local.common_tags
}

# =============================================================================
# DNS zone (optional: only useful with a delegatable domain)
# =============================================================================
resource "oci_dns_zone" "this" {
  count = var.dns_zone_name != "" ? 1 : 0

  compartment_id = var.compartment_id
  name           = var.dns_zone_name
  zone_type      = "PRIMARY"
  freeform_tags  = local.common_tags
}
