packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.0"
    }
  }
}

variable "helper_script_folder" {
  type    = string
  default = "/imagegeneration/helpers"
}

variable "ami_name" {
  type = string
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
}

variable "image_version" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "volume_size" {
  type    = number
  default = 30
}

variable "builder_volume_size" {
  type    = number
  default = 80
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
  default = "g4dn.xlarge"
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
  ami_groups    = var.publish_publicly ? ["all"] : []
  ebs_optimized = true
  # spot_instance_types                       = ["g4dn.xlarge", "g5.xlarge", "g6.xlarge", "g6e.xlarge"]
  # spot_price                                = "auto"
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

source "amazon-ebssurrogate" "compact_root" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = var.ami_name
  ami_description                           = var.ami_description
  ami_virtualization_type                   = "hvm"
  ami_architecture                          = "x86_64"
  ami_groups                                = var.publish_publicly ? ["all"] : []
  snapshot_groups                           = var.publish_publicly ? ["all"] : []
  ena_support                               = true
  ebs_optimized                             = true
  imds_support                              = "v2.0"
  use_create_image                          = true
  instance_type                             = var.instance_type
  region                                    = var.region
  ssh_username                              = "ubuntu"
  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = true
  force_deregister                          = true
  force_delete_snapshot                     = true
  ami_regions                               = var.ami_regions

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.builder_volume_size
    iops                  = 3000
    throughput            = var.volume_throughput
    delete_on_termination = true
    encrypted             = false
    omit_from_artifact    = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sdf"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    iops                  = 3000
    throughput            = var.volume_throughput
    delete_on_termination = true
    encrypted             = false
  }

  ami_root_device {
    source_device_name    = "/dev/sdf"
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    iops                  = 3000
    throughput            = var.volume_throughput
    delete_on_termination = true
  }

  user_data = <<EOF
#!/bin/bash
systemctl enable ssh
systemctl start ssh
EOF

  run_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
  }

  run_volume_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
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
      name                = var.source_ami_name
      root-device-type    = "ebs"
    }
    owners      = [var.source_ami_owner]
    most_recent = true
  }
}

build {
  sources = [
    "source.amazon-ebs.build_ebs",
    "source.amazon-ebssurrogate.compact_root"
  ]

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-gpu.sh"]
  }

  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Reboot VM'", "sudo reboot"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-gpu.sh"]
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
