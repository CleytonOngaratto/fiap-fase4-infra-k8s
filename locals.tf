locals {
  cluster_name = "${var.project}-eks"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Repo      = "fiap-fase4-infra-k8s"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  ecr_repositories = {
    os        = "os-service"
    billing   = "billing-service"
    execution = "execution-service"
  }

  sns_topics = ["billing-events", "execution-events"]
}
