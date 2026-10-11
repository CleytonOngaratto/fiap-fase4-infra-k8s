resource "aws_ssm_parameter" "vpc_id" {
  name  = "/fase4/vpc/id"
  type  = "String"
  value = aws_vpc.main.id
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "/fase4/vpc/cidr"
  type  = "String"
  value = aws_vpc.main.cidr_block
}

resource "aws_ssm_parameter" "private_subnets" {
  name  = "/fase4/vpc/private-subnets"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)
}

resource "aws_ssm_parameter" "public_subnets" {
  name  = "/fase4/vpc/public-subnets"
  type  = "StringList"
  value = join(",", aws_subnet.public[*].id)
}

resource "aws_ssm_parameter" "cluster_name" {
  name  = "/fase4/eks/cluster-name"
  type  = "String"
  value = aws_eks_cluster.main.name
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name  = "/fase4/eks/cluster-endpoint"
  type  = "String"
  value = aws_eks_cluster.main.endpoint
}

# Tem que ser o cluster_security_group_id: os nós herdam este SG e o RDS só aceita conexão dele.
resource "aws_ssm_parameter" "node_sg_id" {
  name  = "/fase4/eks/node-sg-id"
  type  = "String"
  value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

resource "aws_ssm_parameter" "ecr_repo_url" {
  for_each = aws_ecr_repository.service

  name  = "/fase4/ecr/${each.key}/repo-url"
  type  = "String"
  value = each.value.repository_url
}

resource "aws_ssm_parameter" "sns_topic_arn" {
  for_each = aws_sns_topic.events

  name  = "/fase4/sns/${each.key}/topic-arn"
  type  = "String"
  value = each.value.arn
}

resource "aws_ssm_parameter" "alb_listener_arn" {
  name  = "/fase4/alb/listener-arn"
  type  = "String"
  value = aws_lb_listener.http.arn
}

resource "aws_ssm_parameter" "alb_sg_id" {
  name  = "/fase4/alb/sg-id"
  type  = "String"
  value = aws_security_group.alb.id
}

resource "aws_ssm_parameter" "alb_dns" {
  name  = "/fase4/alb/dns"
  type  = "String"
  value = aws_lb.internal.dns_name
}
