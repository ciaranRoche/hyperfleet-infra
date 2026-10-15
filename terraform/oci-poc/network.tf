# Service VCN: API endpoint (public, NSG-locked), private load balancers that
# customer VCNs reach over the DRG, an empty public load balancer subnet for a
# later gateway, worker nodes and VCN-native pods.
locals {
  service_subnets = {
    "oke-endpoint" = { cidr = cidrsubnet(var.service_vcn_cidr, 12, 0), public = true, dns_label = "okeapi" }
    "lb-private"   = { cidr = cidrsubnet(var.service_vcn_cidr, 8, 1), public = false, dns_label = "lbpriv" }
    "lb-public"    = { cidr = cidrsubnet(var.service_vcn_cidr, 8, 2), public = true, dns_label = "lbpub" }
    "oke-nodes"    = { cidr = cidrsubnet(var.service_vcn_cidr, 5, 1), public = false, dns_label = "okenodes" }
    "oke-pods"     = { cidr = cidrsubnet(var.service_vcn_cidr, 1, 1), public = false, dns_label = "okepods" }
  }

  customer_subnets = {
    for c, cidr in var.customer_vcn_cidrs : c => {
      "workers"    = { cidr = cidrsubnet(cidr, 5, 1), public = false, dns_label = "workers" }
      "lb-private" = { cidr = cidrsubnet(cidr, 8, 1), public = false, dns_label = "lbpriv" }
      "lb-public"  = { cidr = cidrsubnet(cidr, 8, 2), public = true, dns_label = "lbpub" }
    }
  }
}

# One DRG in the service compartment. The service table learns every attached
# VCN; each customer table gets a single static route back to the service VCN
# and nothing else, so customers cannot reach each other.
module "drg" {
  source = "../modules/drg/oci"

  compartment_id = local.service_compartment_id
  name           = "${var.name_prefix}-drg"
  freeform_tags  = local.tags

  route_tables = merge(
    { service = { import_all_vcn_routes = true } },
    { for c in keys(var.customer_vcn_cidrs) : c => { import_all_vcn_routes = false } },
  )
}

module "service_vcn" {
  source = "../modules/vcn/oci"

  compartment_id     = local.service_compartment_id
  name               = "${var.name_prefix}-service"
  cidr               = var.service_vcn_cidr
  dns_label          = "hfpocservice"
  subnets            = local.service_subnets
  attach_drg         = true
  drg_id             = module.drg.drg_id
  drg_route_table_id = module.drg.route_table_ids["service"]
  drg_routes         = values(var.customer_vcn_cidrs)
  freeform_tags      = local.tags
}

module "customer_vcn" {
  for_each = var.customer_vcn_cidrs
  source   = "../modules/vcn/oci"

  compartment_id     = local.customer_compartment_ids[each.key]
  name               = "${var.name_prefix}-${each.key}"
  cidr               = each.value
  dns_label          = "hfpoc${replace(each.key, "-", "")}"
  subnets            = local.customer_subnets[each.key]
  attach_drg         = true
  drg_id             = module.drg.drg_id
  drg_route_table_id = module.drg.route_table_ids[each.key]
  drg_routes         = [var.service_vcn_cidr]
  freeform_tags      = local.tags
}

resource "oci_core_drg_route_table_route_rule" "customer_to_service" {
  for_each = var.customer_vcn_cidrs

  drg_route_table_id         = module.drg.route_table_ids[each.key]
  destination                = var.service_vcn_cidr
  destination_type           = "CIDR_BLOCK"
  next_hop_drg_attachment_id = module.service_vcn.drg_attachment_id
}
