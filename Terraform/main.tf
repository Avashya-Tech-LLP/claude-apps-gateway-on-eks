module "networking" {
  source     = "./modules/networking"
  default    = var.default
  networking = var.networking
}

module "eks" {
  source             = "./modules/eks"
  default            = var.default
  eks                = var.eks
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnets
  enable_karpenter   = var.eks["enable_karpenter"]
}

module "eks_addons" {
  source                            = "./modules/eks-addons"
  default                           = var.default
  vpc_id                            = module.networking.vpc_id
  cluster_name                      = module.eks.cluster_name
  lbc_role_arn                      = module.eks.lbc_role_arn
  karpenter_role_arn                = module.eks.karpenter_role_arn
  karpenter_interruption_queue_name = module.eks.karpenter_interruption_queue_name
  node_role_name                    = module.eks.node_role_name
  enable_karpenter                  = var.eks["enable_karpenter"]
}

# module "route53" {
#   source  = "./modules/route53"
#   default = var.default
#   route53 = var.route53
#   vpc_id  = module.networking.vpc_id
# }

module "claude_gateway" {
  source             = "./modules/claude-gateway"
  default            = var.default
  claude_gateway     = var.claude_gateway
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  private_subnet_ids = module.networking.private_subnets
  public_subnet_ids  = module.networking.public_subnets

  depends_on = [module.eks_addons]
}
