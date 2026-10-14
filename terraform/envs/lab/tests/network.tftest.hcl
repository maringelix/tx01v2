# modules/network tested directly.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  github_owner = "maringelix"
  name         = "tx01v2-lab"
  kms_key_arn  = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
}

run "defaults" {
  command = apply

  module {
    source = "../../modules/network"
  }

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16" && aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "The VPC must default to 10.0.0.0/16 with DNS support and hostnames."
  }

  assert {
    condition     = aws_subnet.public[*].cidr_block == ["10.0.0.0/24", "10.0.1.0/24"] && aws_subnet.private[*].cidr_block == ["10.0.16.0/20", "10.0.32.0/20"]
    error_message = "Two AZs: /24 public and /20 private subnets derived from vpc_cidr."
  }

  assert {
    condition     = aws_subnet.public[*].availability_zone == ["us-east-1a", "us-east-1b"] && aws_subnet.private[*].availability_zone == ["us-east-1a", "us-east-1b"]
    error_message = "Subnets must come from aws_availability_zones, one pair per AZ."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false && s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "Public subnets must not auto-assign public IPs and must be tagged for internet-facing ALBs."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.tags["kubernetes.io/role/internal-elb"] == "1"])
    error_message = "Private subnets must be tagged for internal load balancers."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "A single NAT gateway must be the default."
  }

  assert {
    condition     = alltrue([for r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.this[0].id && r.destination_cidr_block == "0.0.0.0/0"])
    error_message = "Every private route table must use the single NAT gateway."
  }

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "The default security group must have no rules."
  }

  assert {
    condition = (
      aws_flow_log.this.traffic_type == "ALL" &&
      aws_flow_log.this.log_destination_type == "cloud-watch-logs" &&
      aws_flow_log.this.log_destination == aws_cloudwatch_log_group.flow_logs.arn &&
      aws_flow_log.this.iam_role_arn == aws_iam_role.flow_logs.arn
    )
    error_message = "VPC flow logs must go to the module log group through the module role."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.kms_key_id == var.kms_key_arn && aws_cloudwatch_log_group.flow_logs.retention_in_days == 7
    error_message = "The flow logs log group must be KMS-encrypted with a retention."
  }

  assert {
    condition = jsondecode(aws_iam_role.flow_logs.assume_role_policy).Statement[0].Condition == {
      StringEquals = { "aws:SourceAccount" = "123456789012" }
      ArnLike      = { "aws:SourceArn" = "arn:aws:ec2:us-east-1:123456789012:vpc-flow-log/*" }
    }
    error_message = "The flow logs role must be limited to flow logs of this account and region."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.flow_logs.policy).Statement : s.Resource if s.Sid == "WriteThisLogGroupOnly"][0] == "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    error_message = "The flow logs role may only write to its own log group."
  }
}

run "nat_per_az_and_three_azs" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    az_count           = 3
    nat_gateway_per_az = true
    vpc_cidr           = "10.20.0.0/16"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3 && length(aws_subnet.private) == 3
    error_message = "nat_gateway_per_az = true must create one NAT gateway per AZ."
  }

  assert {
    condition     = aws_subnet.private[*].cidr_block == ["10.20.16.0/20", "10.20.32.0/20", "10.20.48.0/20"] && aws_subnet.public[2].cidr_block == "10.20.2.0/24"
    error_message = "Subnet CIDRs must follow vpc_cidr, never hardcoded values."
  }
}
