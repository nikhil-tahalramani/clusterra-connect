apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: scale-slurm-workers
  namespace: slurm-operator
spec:
  scaleTargetRef:
    apiVersion: slinky.slurm.net/v1beta1
    kind: NodeSet
    name: slurm-workers
  idleReplicaCount: 0
  minReplicaCount: 1
  maxReplicaCount: 10
  triggers:
    - type: prometheus
      metricType: Value
      metadata:
        serverAddress: ${prometheus_endpoint}
        query: slurm_partition_jobs_pending{partition="slurm-workers"}
        threshold: '1'
