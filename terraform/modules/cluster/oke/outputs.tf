output "cluster_id" {
  description = "OCID of the OKE cluster"
  value       = oci_containerengine_cluster.this.id
}

output "cluster_name" {
  description = "Display name of the OKE cluster"
  value       = oci_containerengine_cluster.this.name
}

output "kubernetes_version" {
  description = "Kubernetes version the cluster was created with"
  value       = oci_containerengine_cluster.this.kubernetes_version
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig context for this cluster"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.this.id} --file $HOME/.kube/config --region ${split(".", oci_containerengine_cluster.this.id)[3]} --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT --auth security_token"
}
