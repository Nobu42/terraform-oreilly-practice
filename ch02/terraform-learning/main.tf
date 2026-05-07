provider "aws" {
  region  = "us-east-2"
  profile = "terraform-learning"
}

data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "example" {
  ami           = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type = "t2.micro"
}
