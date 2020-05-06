provider "aws" {
  region = "eu-west-1"
}

provider "tls" {
  version = "2.0.1"
}

##################################################################
# Data sources to get VPC and subnets
##################################################################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "all" {
  vpc_id = data.aws_vpc.default.id
}

resource "random_pet" "this" {
  length = 2
}

//module "log_bucket" {
//  source  = "terraform-aws-modules/s3-bucket/aws"
//  version = "~> 1.0"
//
//  bucket                         = "logs-${random_pet.this.id}"
//  acl                            = "log-delivery-write"
//  force_destroy                  = true
//  attach_elb_log_delivery_policy = true
//}

resource "tls_private_key" "this" {
  algorithm = "RSA"
}

resource "tls_self_signed_cert" "this" {
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.this.private_key_pem

  subject {
    common_name  = "yes.iam.selfsigned"
    organization = "ACME Examples, Inc"
  }

  # 10 years
  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "this_selfsigned" {
  private_key      = tls_private_key.this.private_key_pem
  certificate_body = tls_self_signed_cert.this.cert_pem
}

resource "aws_eip" "this" {
  count = length(data.aws_subnet_ids.all.ids)

  vpc = true
}

##################################################################
# Network Load Balancer with Elastic IPs attached
##################################################################
module "nlb" {
  source = "../../"

  name = "complete-nlb-${random_pet.this.id}"

  load_balancer_type = "network"

  vpc_id = data.aws_vpc.default.id

  //  Use `subnets` if you don't want to attach EIPs
  //  subnets = tolist(data.aws_subnet_ids.all.ids)

  //  Use `subnet_mapping` to attach EIPs
  subnet_mapping = [for i, eip in aws_eip.this : { allocation_id : eip.id, subnet_id : tolist(data.aws_subnet_ids.all.ids)[i] }]

  //  # See notes in README (ref: https://github.com/terraform-providers/terraform-provider-aws/issues/7987)
  //  access_logs = {
  //    bucket = module.log_bucket.this_s3_bucket_id
  //  }


  // TCP_UDP, UDP, TCP
  http_tcp_listeners = [
    {
      port               = 81
      protocol           = "TCP_UDP"
      target_group_index = 0
    },
    {
      port               = 82
      protocol           = "UDP"
      target_group_index = 1
    },
    {
      port               = 83
      protocol           = "TCP"
      target_group_index = 2
    },
  ]

  // TLS
  https_listeners = [
    {
      port               = 84
      protocol           = "TLS"
      certificate_arn    = aws_acm_certificate.this_selfsigned.arn,
      target_group_index = 3
    },
  ]

  target_groups = [
    {
      name_prefix      = "tu1-"
      backend_protocol = "TCP_UDP"
      backend_port     = 81
      target_type      = "instance"
      tags = {
        tcp_udp = true
      }
    },
    {
      name_prefix      = "u1-"
      backend_protocol = "UDP"
      backend_port     = 82
      target_type      = "instance"
    },
    {
      name_prefix          = "t1-"
      backend_protocol     = "TCP"
      backend_port         = 83
      target_type          = "ip"
      deregistration_delay = 10
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/healthz"
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 6
      }
    },
    {
      name_prefix      = "t2-"
      backend_protocol = "TLS"
      backend_port     = 84
      target_type      = "instance"
    },
  ]
}
