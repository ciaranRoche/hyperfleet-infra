data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_id
}

data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_id
}

locals {
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
  k8s_minor_patch     = trimprefix(var.kubernetes_version, "v")

  # Plain x86_64 Oracle Linux OKE images look like
  # Oracle-Linux-9.8-2026.08.14-0-OKE-1.37.0-1820; aarch64 and GPU variants
  # carry an extra token and fall out of the match. Sorting by name puts the
  # newest OS and date last.
  image_name_pattern = "^Oracle-Linux-[0-9]+\\.[0-9]+-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-[0-9]+-OKE-${replace(local.k8s_minor_patch, ".", "\\.")}-[0-9]+$"
  candidate_images = {
    for s in data.oci_containerengine_node_pool_option.this.sources :
    s.source_name => s.image_id if can(regex(local.image_name_pattern, s.source_name))
  }
  candidate_names = sort(keys(local.candidate_images))
  node_image_name = var.node_image_id == null ? (length(local.candidate_names) > 0 ? local.candidate_names[length(local.candidate_names) - 1] : null) : "explicit"
  node_image_id   = var.node_image_id != null ? var.node_image_id : local.candidate_images[local.node_image_name]
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_id
  name               = var.name
  kubernetes_version = var.kubernetes_version
  vcn_id             = var.vcn_id
  type               = "ENHANCED_CLUSTER"
  freeform_tags      = var.freeform_tags

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  endpoint_config {
    subnet_id            = var.endpoint_subnet_id
    is_public_ip_enabled = var.endpoint_public
    nsg_ids              = var.endpoint_nsg_ids
  }

  options {
    service_lb_subnet_ids = var.lb_subnet_ids

    kubernetes_network_config {
      services_cidr = var.services_cidr
    }

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    admission_controller_options {
      is_pod_security_policy_enabled = false
    }

    open_id_connect_discovery {
      is_open_id_connect_discovery_enabled = var.oidc_discovery_enabled
    }
  }

  lifecycle {
    precondition {
      condition     = local.node_image_id != null
      error_message = "No x86_64 Oracle Linux OKE image found for ${var.kubernetes_version}; set node_image_id or pick another version."
    }
  }
}

resource "oci_containerengine_node_pool" "this" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_id
  name               = "${var.name}-pool"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.node_shape
  freeform_tags      = var.freeform_tags

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.node_image_id
    boot_volume_size_in_gbs = var.node_boot_volume_gbs
  }

  node_config_details {
    size    = var.node_count
    nsg_ids = var.node_nsg_ids

    placement_configs {
      availability_domain = local.availability_domain
      subnet_id           = var.node_subnet_id
      fault_domains       = var.fault_domains
    }

    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      pod_subnet_ids    = [var.pod_subnet_id]
      pod_nsg_ids       = var.pod_nsg_ids
      max_pods_per_node = var.max_pods_per_node
    }
  }

  # The newest image for the version is chosen when the pool is created. OKE
  # publishes new images for the same Kubernetes version every few weeks;
  # following them would rewrite the pool definition on every plan. Roll nodes
  # deliberately (set node_image_id, or replace the pool) instead.
  lifecycle {
    ignore_changes = [node_source_details[0].image_id]
  }
}
