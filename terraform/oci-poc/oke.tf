module "oke" {
  source = "../modules/oke/oci"

  compartment_id     = local.service_compartment_id
  name               = "${var.name_prefix}-oke"
  region             = var.region
  kubernetes_version = var.kubernetes_version
  vcn_id             = module.service_vcn.vcn_id

  endpoint_subnet_id = module.service_vcn.subnet_ids["oke-endpoint"]
  endpoint_public    = true
  endpoint_nsg_ids   = [oci_core_network_security_group.oke_endpoint.id]

  lb_subnet_ids  = [module.service_vcn.subnet_ids["lb-private"]]
  node_subnet_id = module.service_vcn.subnet_ids["oke-nodes"]
  node_nsg_ids   = [oci_core_network_security_group.oke_nodes.id]
  pod_subnet_id  = module.service_vcn.subnet_ids["oke-pods"]
  pod_nsg_ids    = [oci_core_network_security_group.oke_pods.id]

  node_count           = var.node_count
  node_shape           = var.node_shape
  node_ocpus           = var.node_ocpus
  node_memory_gbs      = var.node_memory_gbs
  node_boot_volume_gbs = var.node_boot_volume_gbs

  freeform_tags = local.tags
}
