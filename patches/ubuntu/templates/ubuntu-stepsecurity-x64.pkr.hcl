packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.0"
    }
  }
}

variable "project_root" {
  type    = string
  default = "${env("PROJECT_ROOT")}"
}

variable "ami_name" {
  type    = string
  default = "${env("AMI_NAME")}"
}

variable "ami_description" {
  type = string
}

variable "ami_regions" {
  type = list(string)
}

variable "publish_publicly" {
  type    = bool
  default = true
}

variable "image_os" {
  type = string
  // ex: ubuntu22
  default = "${env("IMAGE_OS")}"
}

variable "image_version" {
  type    = string
  default = "${env("IMAGE_VERSION")}"
}

variable "subnet_id" {
  type = string
}

variable "volume_size" {
  type    = number
  default = 30
}

variable "volume_throughput" {
  type    = number
  default = 125
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_type" {
  type    = string
  default = "m8a.large"
}

variable "region" {
  type = string
}

variable "source_ami_owner" {
  type = string
}

variable "source_ami_name" {
  type = string
}

data "amazon-ami" "runs-on-ami" {
  filters = {
    name                = "${var.source_ami_name}"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["${var.source_ami_owner}"]
  region      = "${var.region}"
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
  # Make AMIs public for release builds; dev accounts can keep them private.
  ami_groups                  = var.publish_publicly ? ["all"] : []
  ebs_optimized               = true
  instance_type               = var.instance_type
  region                      = "${var.region}"
  ssh_username                = "ubuntu"
  subnet_id                   = "${var.subnet_id}"
  associate_public_ip_address = "true"
  force_deregister            = "true"
  force_delete_snapshot       = "true"

  ami_regions = "${var.ami_regions}"

  // Keep the snapshot visibility aligned with the AMI.
  snapshot_groups = var.publish_publicly ? ["all"] : []

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "${var.volume_type}"
    volume_size           = "${var.volume_size}"
    throughput            = var.volume_throughput
    delete_on_termination = "true"
    encrypted             = "false"
  }

  run_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = "${var.ami_name}"
  }

  tags = {
    creator = "RunsOn"
    contact = "ops@runs-on.com"
  }

  snapshot_tags = {
    creator = "RunsOn"
    contact = "ops@runs-on.com"
  }

  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = "${var.source_ami_name}"
      root-device-type    = "ebs"
    }
    owners      = ["${var.source_ami_owner}"]
    most_recent = true
  }

  user_data = <<EOF
#!/bin/bash
systemctl enable ssh
systemctl start ssh
EOF
}

build {
  sources = ["source.amazon-ebs.build_ebs"]

  provisioner "file" {
    source      = "${var.project_root}/integrations/stepsecurity/packer/files"
    destination = "/tmp/packer"
  }
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts         = ["${var.project_root}/integrations/stepsecurity/packer/install-linux.sh"]
  }
  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Reboot VM'", "sudo reboot"]
  }
  provisioner "shell" {
    environment_vars = ["IMAGE_OS=${var.image_os}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    pause_before     = "1m0s"
    scripts = [
      "${path.root}/../scripts/build/cleanup.sh",
      "${path.root}/../custom/files/after-reboot.sh",
      "${path.root}/../custom/files/finalize-rolaunch-descendant.sh",
      "${path.root}/../custom/files/prepare-direct-uefi.sh"
    ]
    start_retry_timeout = "10m"
  }
}
