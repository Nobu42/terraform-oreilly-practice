provider "aws" {
  region  = "us-east-2"
  profile = "terraform-learning"
}

resource "aws_instance" "example" {
  ami           = "ami-0e5497a77ef21b5ac"
  instance_type = "t2.micro"

  tags = {
    Name = "terraform-example"
  }
}

