output "customer_cluster_ip" {
  value = aws_instance.k8s_node.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/id_ed25519 ubuntu@${aws_instance.k8s_node.public_ip}"
}

output "kubeconfig_fetch_command" {
  value = "scp -i ~/.ssh/id_ed25519 ubuntu@${aws_instance.k8s_node.public_ip}:/home/ubuntu/kubeconfig.yaml ./kubeconfig-customer.yaml"
}

output "karpenter_node_role_name" {
  value = aws_iam_role.karpenter_node.name
}

output "cluster_endpoint" {
  value = "https://${aws_instance.k8s_node.public_ip}:6443"
}
