locals {
  has_public  = anytrue([for s in var.subnets : s.public])
  has_private = anytrue([for s in var.subnets : !s.public])
  create_igw  = var.create_internet_gateway && local.has_public
  attach_drg  = var.attach_drg
  drg_routes  = local.attach_drg ? var.drg_routes : []
}

data "oci_core_services" "oracle" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  display_name   = var.name
  cidr_blocks    = [var.cidr]
  dns_label      = var.dns_label
  freeform_tags  = var.freeform_tags
}

# The default security list opens TCP 22 from anywhere. Every subnet here uses
# it (so nothing is attached by accident), reduced to egress only; real access
# rules live in network security groups.
resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  display_name               = "${var.name}-default-sl-egress-only"
  freeform_tags              = var.freeform_tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Egress only; ingress is controlled by NSGs."
  }
}

resource "oci_core_internet_gateway" "this" {
  count = local.create_igw ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_nat_gateway" "this" {
  count = local.has_private ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-nat"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_service_gateway" "this" {
  count = local.has_private ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-sgw"
  freeform_tags  = var.freeform_tags

  services {
    service_id = data.oci_core_services.oracle.services[0].id
  }
}

resource "oci_core_drg_attachment" "this" {
  count = local.attach_drg ? 1 : 0

  drg_id             = var.drg_id
  display_name       = "${var.name}-drg-attachment"
  drg_route_table_id = var.drg_route_table_id
  freeform_tags      = var.freeform_tags

  network_details {
    type = "VCN"
    id   = oci_core_vcn.this.id
  }

  lifecycle {
    precondition {
      condition     = var.drg_id != null
      error_message = "drg_id must be set when attach_drg is true."
    }
  }
}

resource "oci_core_route_table" "public" {
  count = local.create_igw ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-public-rt"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this[0].id
    description       = "Internet via the internet gateway."
  }
}

# OCI rejects a route rule whose target is a DRG until the VCN is attached to
# it, hence the explicit dependency on the attachment.
resource "oci_core_route_table" "private" {
  count = local.has_private ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-private-rt"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this[0].id
    description       = "Internet egress via the NAT gateway."
  }

  route_rules {
    destination       = data.oci_core_services.oracle.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this[0].id
    description       = "Oracle services (OCIR, Object Storage, OKE) via the service gateway."
  }

  dynamic "route_rules" {
    for_each = toset(local.drg_routes)
    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = var.drg_id
      description       = "Peer VCN via the DRG."
    }
  }

  depends_on = [oci_core_drg_attachment.this]
}

resource "oci_core_subnet" "this" {
  for_each = var.subnets

  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.name}-${each.key}"
  cidr_block                 = each.value.cidr
  dns_label                  = coalesce(each.value.dns_label, replace(each.key, "-", ""))
  prohibit_public_ip_on_vnic = !each.value.public
  prohibit_internet_ingress  = !each.value.public
  route_table_id             = each.value.public ? oci_core_route_table.public[0].id : oci_core_route_table.private[0].id
  security_list_ids          = [oci_core_default_security_list.this.id]
  freeform_tags              = var.freeform_tags
}
