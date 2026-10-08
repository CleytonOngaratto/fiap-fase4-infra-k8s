locals {
  cluster_name = "${var.project}-eks"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Repo      = "fiap-fase4-infra-k8s"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Sem NAT a subnet privada não tem saída e o nó nunca se registra no control plane.
  node_subnet_ids = var.enable_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id
}
