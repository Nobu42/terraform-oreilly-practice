terraform {
  required_version = ">= 1.0.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
  backend "s3" {
    bucket         = "nobu-iac-running-state"
    key            = "stage/data-stores/mysql/terraform.tfstate"
    region         = "us-east-2"
    profile        = "terraform-learning"
    dynamodb_table = "nobu-iac-locks"
    encrypt        = true
  }
}

provider "aws" {
  region  = "us-east-2"
  profile = "terraform-learning"
}

resource "aws_db_instance" "example" {
  identifier_prefix   = "terraform-up-and-running"
  engine              = "mysql"
  allocated_storage   = 20
  instance_class      = "db.t3.micro"
  skip_final_snapshot = true

  db_name = var.db_name

  username = var.db_username
  password = var.db_password
}
