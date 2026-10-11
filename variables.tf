variable "region" {
  description = "Região AWS. O Learner Lab só libera us-east-1 e us-west-2."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo de nome e valor da tag Project."
  type        = string
  default     = "fiap-fase4"
}

variable "vpc_cidr" {
  description = "CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Subnets públicas, uma por AZ. Só o NAT mora nelas."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "private_subnet_cidrs" {
  description = "Subnets privadas, uma por AZ: nós, ALB interno, bancos e Lambda. /20 porque o VPC CNI consome um IP da subnet por pod."
  type        = list(string)
  default     = ["10.0.128.0/20", "10.0.144.0/20"]
}

variable "cluster_version" {
  description = "Versão do Kubernetes. null = default da AWS, sempre em standard support (extended support custa 6x mais)."
  type        = string
  default     = null
}

variable "cluster_role_name" {
  description = <<-EOT
    Role do control plane. Sem default: o lab cria o role por CloudFormation com prefixo e sufixo
    gerados, únicos por instância (ex.: `c2215...-LabEksClusterRole-XXXXXXXXXXXX`) — e não é a
    LabRole. Descubra com scripts/preflight.ps1.
  EOT
  type        = string
}

variable "cluster_public_access_cidrs" {
  description = "Quem alcança o endpoint público da API. 0.0.0.0/0 é necessário para o GitHub Actions (IP dinâmico)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "O lab libera de nano a large. O VPC CNI limita pods por ENI: t3.large comporta 35 pods por nó."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Nós desejados. Sem cluster-autoscaler (exigiria IAM/IRSA): escalar é reaplicar."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Mínimo de nós."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Máximo de nós (folga para o rolling update). O lab permite 9 instâncias / 32 vCPU, e 20+ DESATIVAM a conta apagando tudo."
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "Disco de cada nó em GB. O lab limita volumes a 100GB."
  type        = number
  default     = 20
}

variable "enable_metrics_server" {
  description = "Add-on metrics-server. Sem ele o HPA da aplicação fica <unknown> e nunca escala."
  type        = bool
  default     = true
}

variable "ecr_keep_last_images" {
  description = "Quantas imagens manter em cada repositório ECR."
  type        = number
  default     = 10
}
