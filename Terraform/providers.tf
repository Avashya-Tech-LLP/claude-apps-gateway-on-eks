terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.default["region"]
}

data "aws_eks_clusters" "all" {}

locals {
  eks_cluster_name   = "${var.default["env"]}-${var.default["project"]}-eks"
  eks_cluster_exists = contains(tolist(data.aws_eks_clusters.all.names), local.eks_cluster_name)
}

data "aws_eks_cluster" "this" {
  count = local.eks_cluster_exists ? 1 : 0
  name  = local.eks_cluster_name
}


locals {
  eks_host    = local.eks_cluster_exists ? data.aws_eks_cluster.this[0].endpoint : "https://localhost:6443"
  eks_ca_cert = local.eks_cluster_exists ? base64decode(data.aws_eks_cluster.this[0].certificate_authority[0].data) : ""
}

provider "helm" {
  kubernetes {
    host                   = local.eks_host
    cluster_ca_certificate = local.eks_ca_cert
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.default["region"]]
    }
  }
}

provider "kubernetes" {
  host                   = local.eks_host
  cluster_ca_certificate = local.eks_ca_cert
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.default["region"]]
  }
}

provider "kubectl" {
  host                   = local.eks_host
  cluster_ca_certificate = local.eks_ca_cert
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.default["region"]]
  }
}
