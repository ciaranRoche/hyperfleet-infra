# Network security groups. Every VCN's default security list is egress only
# (see the vcn module), so these are the only ingress rules that exist.
# Load balancer frontend rules are deliberately absent: the cloud controller
# manager owns them per architecture ADR 0024 (see iam.tf).

locals {
  service_vcn_cidr   = var.service_vcn_cidr
  oke_nodes_cidr     = local.service_subnets["oke-nodes"].cidr
  oke_pods_cidr      = local.service_subnets["oke-pods"].cidr
  oke_internal_cidrs = toset([local.oke_nodes_cidr, local.oke_pods_cidr])
}

# ---------------------------------------------------------------------------
# Service VCN: OKE API endpoint
# ---------------------------------------------------------------------------
resource "oci_core_network_security_group" "oke_endpoint" {
  compartment_id = local.service_compartment_id
  vcn_id         = module.service_vcn.vcn_id
  display_name   = "${var.name_prefix}-oke-endpoint"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "oke_endpoint_ingress_operators" {
  for_each = toset(var.allowed_cidrs)

  network_security_group_id = oci_core_network_security_group.oke_endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "kubectl from an allowed operator address."

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_endpoint_ingress_nodes_6443" {
  for_each = local.oke_internal_cidrs

  network_security_group_id = oci_core_network_security_group.oke_endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "Kubernetes API from nodes and pods."

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_endpoint_ingress_nodes_12250" {
  for_each = local.oke_internal_cidrs

  network_security_group_id = oci_core_network_security_group.oke_endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "OKE control plane tunnel from nodes and pods."

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_endpoint_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.oke_endpoint.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source_type               = "CIDR_BLOCK"
  source                    = local.service_vcn_cidr
  description               = "Path MTU discovery inside the VCN."

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "oke_endpoint_egress_vcn" {
  network_security_group_id = oci_core_network_security_group.oke_endpoint.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = local.service_vcn_cidr
  description               = "Control plane to nodes and pods."
}

# ---------------------------------------------------------------------------
# Service VCN: OKE worker nodes
# ---------------------------------------------------------------------------
resource "oci_core_network_security_group" "oke_nodes" {
  compartment_id = local.service_compartment_id
  vcn_id         = module.service_vcn.vcn_id
  display_name   = "${var.name_prefix}-oke-nodes"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "oke_nodes_ingress_vcn" {
  network_security_group_id = oci_core_network_security_group.oke_nodes.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source_type               = "CIDR_BLOCK"
  source                    = local.service_vcn_cidr
  description               = "Node to node, pod to node, control plane and load balancer backends inside the VCN."
}

resource "oci_core_network_security_group_security_rule" "oke_nodes_ingress_customer_nodeports" {
  for_each = var.customer_vcn_cidrs

  network_security_group_id = oci_core_network_security_group.oke_nodes.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "NodePort services from the ${each.key} VCN over the DRG."

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_nodes_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.oke_nodes.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  description               = "Path MTU discovery."

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "oke_nodes_egress_all" {
  network_security_group_id = oci_core_network_security_group.oke_nodes.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
  description               = "Image pulls, OKE control plane, Oracle services, customer VCNs."
}

# ---------------------------------------------------------------------------
# Service VCN: OKE pods (VCN-native CNI)
# ---------------------------------------------------------------------------
resource "oci_core_network_security_group" "oke_pods" {
  compartment_id = local.service_compartment_id
  vcn_id         = module.service_vcn.vcn_id
  display_name   = "${var.name_prefix}-oke-pods"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "oke_pods_ingress_vcn" {
  network_security_group_id = oci_core_network_security_group.oke_pods.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source_type               = "CIDR_BLOCK"
  source                    = local.service_vcn_cidr
  description               = "Pod to pod, node to pod and load balancer backends inside the VCN."
}

resource "oci_core_network_security_group_security_rule" "oke_pods_ingress_customers" {
  for_each = var.customer_vcn_cidrs

  network_security_group_id = oci_core_network_security_group.oke_pods.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "Worker-initiated traffic from the ${each.key} VCN to hosted control plane pods behind private load balancers."
}

resource "oci_core_network_security_group_security_rule" "oke_pods_egress_all" {
  network_security_group_id = oci_core_network_security_group.oke_pods.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
  description               = "Pods reach the internet via NAT, Oracle services and customer VCNs."
}

# ---------------------------------------------------------------------------
# Customer VCNs: workers
# ---------------------------------------------------------------------------
resource "oci_core_network_security_group" "customer_workers" {
  for_each = var.customer_vcn_cidrs

  compartment_id = local.customer_compartment_ids[each.key]
  vcn_id         = module.customer_vcn[each.key].vcn_id
  display_name   = "${var.name_prefix}-${each.key}-workers"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "customer_workers_ingress_vcn" {
  for_each = var.customer_vcn_cidrs

  network_security_group_id = oci_core_network_security_group.customer_workers[each.key].id
  direction                 = "INGRESS"
  protocol                  = "all"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "Worker to worker and load balancer backends inside the ${each.key} VCN."
}

resource "oci_core_network_security_group_security_rule" "customer_workers_ingress_icmp" {
  for_each = var.customer_vcn_cidrs

  network_security_group_id = oci_core_network_security_group.customer_workers[each.key].id
  direction                 = "INGRESS"
  protocol                  = "1"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  description               = "Path MTU discovery."

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "customer_workers_egress_all" {
  for_each = var.customer_vcn_cidrs

  network_security_group_id = oci_core_network_security_group.customer_workers[each.key].id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
  description               = "Worker-initiated traffic: ignition, API and konnectivity over the DRG, pulls via NAT and the service gateway."
}
