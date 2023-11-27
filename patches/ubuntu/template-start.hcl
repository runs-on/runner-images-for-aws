packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "ami_name" {
  type    = string
  default = "${env("AMI_NAME")}"
}

variable "ami_description" {
  type    = string
  default = "${env("AMI_DESCRIPTION")}"
}

variable "dockerhub_login" {
  type    = string
  default = "${env("DOCKERHUB_LOGIN")}"
}

variable "dockerhub_password" {
  type    = string
  default = "${env("DOCKERHUB_PASSWORD")}"
}

variable "helper_script_folder" {
  type    = string
  default = "/imagegeneration/helpers"
}

variable "imagedata_file" {
  type    = string
  default = "/imagegeneration/imagedata.json"
}

variable "image_folder" {
  type    = string
  default = "/imagegeneration"
}

variable "image_os" {
  type    = string
  default = "ubuntu22"
}

variable "image_version" {
  type    = string
  default = "dev"
}

variable "installer_script_folder" {
  type    = string
  default = "/imagegeneration/installers"
}

variable "region" {
  type    = string
  default = "${env("AWS_DEFAULT_REGION")}"
}

variable "run_validation_diskspace" {
  type    = bool
  default = false
}

// make sure the subnet auto-assigns public IPs
variable "subnet_id" {
  type    = string
  default = "${env("SUBNET_ID")}"
}

variable "volume_size" {
  type    = number
  default = 120
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

source "amazon-ebs" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = "${var.ami_name}"
  ami_description                           = "${var.ami_description}"
  ami_virtualization_type                   = "hvm"
  # make AMIs publicly accessible
  ami_groups                                = ["all"]
  ebs_optimized                             = true
  spot_instance_types                       = ["c7a.xlarge", "c6a.xlarge", "m5zn.xlarge"]
  spot_price                                = "1.00"
  region                                    = "${var.region}"
  ssh_username                              = "ubuntu"
  subnet_id                                 = "${var.subnet_id}"
  associate_public_ip_address               = "true"

  ami_regions = [
    "us-east-1",
    "us-west-1",
    "eu-west-1",
    "eu-central-1",
    "sa-east-1",
    "ap-northeast-1",
    "ap-southeast-1"
  ]

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_type = "${var.volume_type}"
    volume_size = "${var.volume_size}"
    delete_on_termination = "true"
  }

  tags = {
    creator     = "Packer"
    contact     = "ops@runs-on.com"
    application = "RunsOn"
  }

  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"]
    most_recent = true
  }
}