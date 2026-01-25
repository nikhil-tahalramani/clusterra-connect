output "clusterra_onboarding" {
  description = "Values to provide to Clusterra for cluster registration"
  value = {
    cluster_name = var.cluster_name
    region       = var.region
    # TODO: Add endpoint service name and other connection details once implemented
  }
}
