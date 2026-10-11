output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "Security group primário do cluster — é o SG efetivo dos nós."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "vpc_id" {
  description = "ID da VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Subnets públicas."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets privadas."
  value       = aws_subnet.private[*].id
}

output "ecr_repository_urls" {
  description = "URL do repositório ECR de cada serviço, para docker tag/push."
  value       = { for service, repo in aws_ecr_repository.service : service => repo.repository_url }
}

output "sns_topic_arns" {
  description = "ARN de cada tópico SNS FIFO."
  value       = { for topic, t in aws_sns_topic.events : topic => t.arn }
}

output "alb_dns_name" {
  description = "DNS do ALB interno; só resolve para IPs privados."
  value       = aws_lb.internal.dns_name
}

output "alb_listener_arn" {
  description = "Listener HTTP do ALB interno, onde cada serviço pendura a sua regra de path."
  value       = aws_lb_listener.http.arn
}

output "kubeconfig_command" {
  description = "Comando para configurar o kubectl."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}
