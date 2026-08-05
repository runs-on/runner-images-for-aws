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

variable "builder_volume_size" {
  type    = number
  default = 60
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
  default = "m8g.large"
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

source "amazon-ebssurrogate" "compact_root" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = var.ami_name
  ami_description                           = var.ami_description
  ami_virtualization_type                   = "hvm"
  ami_architecture                          = "arm64"
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
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
  }

  snapshot_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
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
    only             = ["amazon-ebssurrogate.compact_root"]
    environment_vars = ["EXPECTED_BUILDER_VOLUME_SIZE_GB=${var.builder_volume_size}", "IMAGE_OS=${var.image_os}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script           = "${path.root}/../custom/files/wait-for-compact-root-resize.sh"
  }

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
    environment_vars    = ["IMAGE_OS=${var.image_os}"]
    execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    pause_before        = "1m0s"
    scripts             = ["${path.root}/../scripts/build/cleanup.sh", "${path.root}/../custom/files/after-reboot.sh", "${path.root}/../custom/files/finalize-rolaunch-descendant.sh"]
    start_retry_timeout = "10m"
  }

  provisioner "shell" {
    only            = ["amazon-ebssurrogate.compact_root"]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["install -d -o ubuntu -g ubuntu -m 0755 /run/runs-on-compact-root"]
  }

  provisioner "file" {
    only        = ["amazon-ebssurrogate.compact_root"]
    destination = "/run/runs-on-compact-root/"
    sources = [
      "${path.root}/../custom/files/compact-root-recovery-init",
      "${path.root}/../custom/files/compact-root-tree-manifest.py",
      "${path.root}/../custom/files/compact-root.boot-profile",
      "${path.root}/../custom/files/filter-compact-root-boot-profile.py"
    ]
  }

  provisioner "shell" {
    only = ["amazon-ebssurrogate.compact_root"]
    environment_vars = [
      "COMPACT_ROOT_ASSET_DIR=/run/runs-on-compact-root",
      "COMPACT_ROOT_VARIANT=stepsecurity",
      "IMAGE_OS=${var.image_os}",
      "TARGET_VOLUME_SIZE_GB=${var.volume_size}"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/finalize-compact-root.sh"
  }
}
