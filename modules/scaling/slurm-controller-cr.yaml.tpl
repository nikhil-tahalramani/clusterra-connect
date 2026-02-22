---
# Controller CR — tells the NodeSet operator where to find the central slurmctld.
# external: true means: don't deploy a local slurmctld, connect outbound to the given host:port.
apiVersion: slinky.slurm.net/v1beta1
kind: Controller
metadata:
  name: central-slurmctld
  namespace: slurm-operator
spec:
  external: true
  externalConfig:
    host: "${slurmctld_host}"     # Dev cluster public IP or Lattice DNS
    port: 30817                   # slurmctld NodePort (must be the real slurmctld port, not slurmrestd)
  clusterName: "${cluster_name}"
  # auth/slurm key
  slurmKeyRef:
    name: slurm-auth-slurm
    key: slurm.key
  # auth/jwt key
  jwtHs256KeyRef:
    name: slurm-auth-jwths256
    key: jwt_hs256.key
---
# RestApi CR — required by the Slinky operator even in external mode.
# The slurmclient-controller calls GetRestapisForController() to discover the server URL.
# Without this CR, that function returns empty and the slurmclient is never added to the
# ClientMap, causing a nil pointer panic in the nodeset-controller.
# replicas: 0 → no slurmrestd pod is deployed locally; the external host is used via externalConfig.
apiVersion: slinky.slurm.net/v1beta1
kind: RestApi
metadata:
  name: central-slurmrestd
  namespace: slurm-operator
spec:
  controllerRef:
    name: central-slurmctld
    namespace: slurm-operator
  replicas: 1
  slurmrestd:
    image: ghcr.io/slinkyproject/slurmrestd:25.11-ubuntu24.04
