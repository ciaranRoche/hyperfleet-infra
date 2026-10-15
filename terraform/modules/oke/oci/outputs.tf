output "cluster_id" {
  description = "OCID of the cluster."
  value       = oci_containerengine_cluster.this.id
}

output "cluster_name" {
  description = "Name of the cluster."
  value       = oci_containerengine_cluster.this.name
}

output "kubernetes_version" {
  description = "Kubernetes version of the control plane."
  value       = oci_containerengine_cluster.this.kubernetes_version
}

output "public_endpoint" {
  description = "Public API endpoint (host:port), empty when endpoint_public is false."
  value       = try(oci_containerengine_cluster.this.endpoints[0].public_endpoint, null)
}

output "private_endpoint" {
  description = "Private API endpoint (host:port) inside the VCN."
  value       = try(oci_containerengine_cluster.this.endpoints[0].private_endpoint, null)
}

output "node_pool_id" {
  description = "OCID of the node pool."
  value       = oci_containerengine_node_pool.this.id
}

output "node_image_name" {
  description = "Name of the node image that was selected."
  value       = local.node_image_name
}

output "kubeconfig_command" {
  description = "oci CLI command that writes a kubeconfig for the cluster. The exec plugin it installs inherits OCI_CLI_PROFILE and OCI_CLI_AUTH from the environment."
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.this.id} --file $HOME/.kube/config --region ${var.region} --token-version 2.0.0 --kube-endpoint ${var.endpoint_public ? "PUBLIC_ENDPOINT" : "PRIVATE_ENDPOINT"}"
}
