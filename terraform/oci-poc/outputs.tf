output "compartment_ids" {
  description = "OCIDs of the service and customer compartments in use, keyed by role (service, customer names)."
  value       = merge({ service = local.service_compartment_id }, local.customer_compartment_ids)
}

output "service_vcn_id" {
  description = "OCID of the service VCN."
  value       = module.service_vcn.vcn_id
}

output "service_subnet_ids" {
  description = "Service VCN subnet OCIDs keyed by subnet name."
  value       = module.service_vcn.subnet_ids
}

output "service_subnet_cidrs" {
  description = "Service VCN subnet CIDRs keyed by subnet name."
  value       = module.service_vcn.subnet_cidrs
}

output "customer_vcn_ids" {
  description = "Customer VCN OCIDs keyed by customer."
  value       = { for k, m in module.customer_vcn : k => m.vcn_id }
}

output "customer_subnet_ids" {
  description = "Customer subnet OCIDs keyed by customer then subnet name."
  value       = { for k, m in module.customer_vcn : k => m.subnet_ids }
}

output "customer_subnet_cidrs" {
  description = "Customer subnet CIDRs keyed by customer then subnet name."
  value       = { for k, m in module.customer_vcn : k => m.subnet_cidrs }
}

output "customer_workers_nsg_ids" {
  description = "Worker NSG OCIDs keyed by customer."
  value       = { for k, n in oci_core_network_security_group.customer_workers : k => n.id }
}

output "drg_id" {
  description = "OCID of the DRG."
  value       = module.drg.drg_id
}

output "drg_route_table_ids" {
  description = "DRG route table OCIDs keyed by attachment name."
  value       = module.drg.route_table_ids
}

output "oke_cluster_id" {
  description = "OCID of the OKE cluster."
  value       = module.oke.cluster_id
}

output "oke_kubernetes_version" {
  description = "Kubernetes version of the OKE cluster."
  value       = module.oke.kubernetes_version
}

output "oke_public_endpoint" {
  description = "Public API endpoint of the OKE cluster."
  value       = module.oke.public_endpoint
}

output "oke_private_endpoint" {
  description = "Private API endpoint of the OKE cluster, reachable from the customer VCNs over the DRG."
  value       = module.oke.private_endpoint
}

output "oke_node_image_name" {
  description = "Node image selected for the pool."
  value       = module.oke.node_image_name
}

output "oke_nsg_ids" {
  description = "OKE NSG OCIDs: endpoint, nodes, pods."
  value = {
    endpoint = oci_core_network_security_group.oke_endpoint.id
    nodes    = oci_core_network_security_group.oke_nodes.id
    pods     = oci_core_network_security_group.oke_pods.id
  }
}

output "connect_command" {
  description = "Writes a kubeconfig for the cluster. Export OCI_CLI_PROFILE and OCI_CLI_AUTH first; the exec plugin inherits them."
  value       = module.oke.kubeconfig_command
}
