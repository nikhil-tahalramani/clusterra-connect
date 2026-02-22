---
# NodeSet CR — defines managed slurmd workers on the customer cluster.
# The controllerRef links this NodeSet to the Controller CR (which points at the external slurmctld).
# The NodeSet controller reads the Slurm job queue and creates pods with matching resource requests.
apiVersion: slinky.slurm.net/v1beta1
kind: NodeSet
metadata:
  name: slurm-workers
  namespace: slurm-operator
spec:
  # Reference the Controller CR (which points at the external central slurmctld)
  controllerRef:
    name: central-slurmctld
    namespace: slurm-operator

  # Start at 0 — NodeSet will scale up based on the Slurm job queue
  replicas: 0

  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1

  # Partition configuration — this NodeSet creates/manages the "all" partition
  partition:
    enabled: true
    config: "State=UP MaxTime=INFINITE"

  # Tolerate Karpenter taints so pods can land on provisioned nodes
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      tolerations:
      - operator: "Exists"

  # Logfile sidecar — REQUIRED: Slinky's workerbuilder uses this to populate the logfile init container image
  logfile:
    image: docker.io/library/alpine:latest

  # The slurmd container spec
  slurmd:
    image: ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "1"
        memory: "512Mi"
