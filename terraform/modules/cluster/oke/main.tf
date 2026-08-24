# OKE (Container Engine for Kubernetes) cluster with one managed node pool.
# Flannel overlay networking keeps the subnet requirements simple for POC use;
# revisit VCN-native pod networking when the gateway/multitenancy work needs it.

data "oci_containerengine_cluster_option" "this" {
  cluster_option_id = "all"
  compartment_id    = var.compartment_id
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_id
}

locals {
  # Cluster options list versions ascending; take the newest unless pinned.
  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : element(data.oci_containerengine_cluster_option.this.kubernetes_versions, length(data.oci_containerengine_cluster_option.this.kubernetes_versions) - 1)
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_id
  name               = var.cluster_name
  kubernetes_version = local.kubernetes_version
  vcn_id             = var.vcn_id
  type               = "BASIC_CLUSTER"
  freeform_tags      = var.freeform_tags

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    subnet_id            = var.endpoint_subnet_id
    is_public_ip_enabled = true
  }

  options {
    service_lb_subnet_ids = [var.lb_subnet_id]
  }
}

data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = oci_containerengine_cluster.this.id
  compartment_id      = var.compartment_id
}

locals {
  # Newest x86 Oracle Linux 8 OKE image compatible with the cluster version.
  node_image_ids = [
    for source in data.oci_containerengine_node_pool_option.this.sources : source.image_id
    if length(regexall("Oracle-Linux-8", source.source_name)) > 0
    && length(regexall("aarch64|GPU", source.source_name)) == 0
    && length(regexall(replace(local.kubernetes_version, "v", ""), source.source_name)) > 0
  ]
}

resource "oci_containerengine_node_pool" "this" {
  compartment_id     = var.compartment_id
  cluster_id         = oci_containerengine_cluster.this.id
  name               = "${var.cluster_name}-pool"
  kubernetes_version = local.kubernetes_version
  node_shape         = var.node_shape
  freeform_tags      = var.freeform_tags

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = local.node_image_ids[0]
  }

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
      subnet_id           = var.node_subnet_id
    }

    freeform_tags = var.freeform_tags
  }
}
