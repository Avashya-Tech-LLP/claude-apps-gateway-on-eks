resource "aws_vpc" "vpc" {
  cidr_block           = var.networking["vpc"]["cidr_block"]
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-vpc"
  }
}

resource "aws_subnet" "public_subnet" {
  count = length(var.networking["vpc"]["public_subnet"])

  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = var.networking["vpc"]["public_subnet"][count.index]
  availability_zone       = var.networking["vpc"]["public_azs"][count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                                                        = "${var.default["env"]}-${var.default["project"]}-public-subnet-${count.index + 1}"
    "kubernetes.io/cluster/${var.default["env"]}-${var.default["project"]}-eks" = "shared"
    "kubernetes.io/role/elb"                                                    = "1"
    type                                                                        = "public"
  }
}

resource "aws_subnet" "private_subnet" {
  count = length(var.networking["vpc"]["private_subnet"])

  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = var.networking["vpc"]["private_subnet"][count.index]
  availability_zone       = var.networking["vpc"]["private_azs"][count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                                                                        = "${var.default["env"]}-${var.default["project"]}-private-subnet-${count.index + 1}"
    "kubernetes.io/cluster/${var.default["env"]}-${var.default["project"]}-eks" = "shared"
    "kubernetes.io/role/internal-elb"                                           = "1"
    "karpenter.sh/discovery"                                                    = "${var.default["env"]}-${var.default["project"]}-eks"
    type                                                                        = "private"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-igw"
  }
}

# Single NAT Gateway for dev/POC — one per AZ only needed for HA in prod
resource "aws_eip" "natgw_eip" {
  count = 1

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-natgw-eip-1"
  }
}

resource "aws_nat_gateway" "natgw" {
  count = 1

  allocation_id = aws_eip.natgw_eip[0].id
  subnet_id     = aws_subnet.public_subnet[0].id

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-natgw-1"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-public-rt"
  }
}

# Single route table shared by all private subnets — both route to the one NAT GW
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgw[0].id
  }

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-private-rt"
  }
}

resource "aws_route_table_association" "public_rt_association" {
  count = length(tolist(aws_subnet.public_subnet[*]))

  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_rt_association" {
  count = length(tolist(aws_subnet.private_subnet[*]))

  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_rt.id
}
