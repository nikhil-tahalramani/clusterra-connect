terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

locals {
  ssh_opts = "-i ${var.ssh_key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o BatchMode=yes"
}

# ─── Generate Manifests from Templates ──────────────────────────────────────

resource "local_file" "karpenter_nodeclass" {
  content = templatefile("${path.module}/karpenter-nodeclass.yaml.tpl", {
    cluster_name   = var.cluster_name
    karpenter_role = var.karpenter_node_role_name
    # AMI ID and K3s token will be injected dynamically by the setup script on the node itself.
  })
  filename = "${path.module}/karpenter-nodeclass.yaml.tmp"
}

resource "local_file" "slurm_controller_cr" {
  content = templatefile("${path.module}/slurm-controller-cr.yaml.tpl", {
    slurmctld_host  = var.slurmctld_host
    slurmrestd_port = var.slurmrestd_port
    cluster_name    = var.cluster_name
  })
  filename = "${path.module}/slurm-controller-cr.yaml.tmp"
}

resource "local_file" "slurm_nodeset_cr" {
  content = templatefile("${path.module}/slurm-nodeset-cr.yaml.tpl", {
    cluster_name = var.cluster_name
  })
  filename = "${path.module}/slurm-nodeset-cr.yaml.tmp"
}

resource "local_file" "keda_scaledobject" {
  content = templatefile("${path.module}/keda-scaledobject.yaml.tpl", {
    prometheus_endpoint = var.prometheus_endpoint
  })
  filename = "${path.module}/keda-scaledobject.yaml.tmp"
}

# ─── Upload Manifests and Setup Script ──────────────────────────────────────

resource "null_resource" "upload_scaling_assets" {
  triggers = {
    head_ip              = var.head_node_public_ip
    setup_script_hash    = filemd5("${path.module}/setup_scaling.sh")
    nodepool_hash        = filemd5("${path.module}/karpenter-nodepool.yaml")
    operator_values_hash = filemd5("${path.module}/slurm-operator-values.yaml")
    nodeclass_hash       = local_file.karpenter_nodeclass.content
    controller_cr_hash   = local_file.slurm_controller_cr.content
    nodeset_cr_hash      = local_file.slurm_nodeset_cr.content
    keda_cr_hash         = local_file.keda_scaledobject.content
  }

  provisioner "local-exec" {
    command = <<-CMD
      until ssh ${local.ssh_opts} ${var.ssh_user}@${var.head_node_public_ip} true; do
        echo "Waiting for SSH to be available..."
        sleep 5
      done

      scp ${local.ssh_opts} \
        ${path.module}/setup_scaling.sh \
        ${path.module}/karpenter-nodepool.yaml \
        ${path.module}/slurm-operator-values.yaml \
        ${local_file.karpenter_nodeclass.filename} \
        ${local_file.slurm_controller_cr.filename} \
        ${local_file.slurm_nodeset_cr.filename} \
        ${local_file.keda_scaledobject.filename} \
        ${var.ssh_user}@${var.head_node_public_ip}:/tmp/

      ssh ${local.ssh_opts} ${var.ssh_user}@${var.head_node_public_ip} " \
        mv /tmp/karpenter-nodeclass.yaml.tmp /tmp/karpenter-nodeclass.yaml && \
        mv /tmp/slurm-controller-cr.yaml.tmp /tmp/slurm-controller-cr.yaml && \
        mv /tmp/slurm-nodeset-cr.yaml.tmp /tmp/slurm-nodeset-cr.yaml && \
        mv /tmp/keda-scaledobject.yaml.tmp /tmp/keda-scaledobject.yaml"
    CMD
  }
}

# ─── Execute Setup Script ───────────────────────────────────────────────────

resource "null_resource" "deploy_scaling" {
  depends_on = [null_resource.upload_scaling_assets]

  triggers = {
    assets_trigger = null_resource.upload_scaling_assets.id
  }

  provisioner "local-exec" {
    command = <<-CMD
      ssh ${local.ssh_opts} ${var.ssh_user}@${var.head_node_public_ip} \
        "CLUSTER_NAME=${var.cluster_name} CLUSTER_ENDPOINT=${var.cluster_endpoint} PROMETHEUS_ENDPOINT=${var.prometheus_endpoint} PROMETHEUS_BEARER_TOKEN_SECRET_NAME=${var.prometheus_bearer_token_secret_name} bash -s" \
        < ${path.module}/setup_scaling.sh
    CMD
  }
}
