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
  default = "${env("IMAGE_OS")}"
}

variable "image_version" {
  type    = string
  default = "${env("IMAGE_VERSION")}"
}

variable "installer_script_folder" {
  type    = string
  default = "/imagegeneration/installers"
}

variable "region" {
  type    = string
  default = "${env("AWS_DEFAULT_REGION")}"
}

variable "ami_regions" {
  type = list(string)
}

variable "source_ami_owner" {
  type    = string
  default = "966509368716"
}

variable "source_ami_name" {
  type    = string
  default = "runs-on-dev-ubuntu24-minimal-x64-*"
}

variable "subnet_id" {
  type    = string
  default = "${env("SUBNET_ID")}"
}

variable "volume_size" {
  type    = number
  default = 30
}

variable "volume_throughput" {
  type    = number
  default = 750
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_type" {
  type    = string
  default = "m8azn.large"
}

source "amazon-ebssurrogate" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = var.ami_name
  ami_description                           = var.ami_description
  ami_virtualization_type                   = "hvm"
  ami_architecture                          = "x86_64"
  ena_support                               = true
  ebs_optimized                             = true
  instance_type                             = var.instance_type
  region                                    = var.region
  ssh_username                              = "ubuntu"
  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = true
  force_deregister                          = true
  force_delete_snapshot                     = true

  user_data = <<EOF
#!/bin/bash
set -euxo pipefail
systemctl unmask ssh.service || true
systemctl enable ssh.service || true
systemctl start ssh.service || true
EOF

  ami_regions = var.ami_regions

  launch_block_device_mappings {
    device_name           = "/dev/sdf"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    throughput            = var.volume_throughput
    delete_on_termination = true
    encrypted             = false
  }

  ami_root_device {
    source_device_name    = "/dev/sdf"
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    delete_on_termination = true
  }

  run_tags = {
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
  sources = ["source.amazon-ebssurrogate.build_ebs"]

  provisioner "file" {
    source      = "${path.root}/../custom/files/rolaunch"
    destination = "/tmp/rolaunch"
  }

  provisioner "file" {
    source      = "${path.root}/../custom/files/rootfs-compaction.sh"
    destination = "/tmp/rootfs-compaction.sh"
  }

  provisioner "file" {
    destination = "/tmp/waagent.conf"
    source      = "${path.root}/../custom/files/waagent.conf"
  }

  provisioner "file" {
    source      = "${path.root}/../custom/files/install-runs-on-bootstrap.sh"
    destination = "/tmp/install-runs-on-bootstrap.sh"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mv /tmp/waagent.conf /etc"]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mkdir -p ${var.image_folder}", "chmod 777 ${var.image_folder}"]
  }

  provisioner "file" {
    destination = "${var.image_folder}/bootfast-runner-user.sh"
    source      = "${path.root}/../custom/files/bootfast-runner-user.sh"
  }

  provisioner "file" {
    destination = "${var.image_folder}/runner-finalize-common.sh"
    source      = "${path.root}/../custom/files/runner-finalize-common.sh"
  }

  provisioner "file" {
    destination = "${var.image_folder}/runner-finalize-nested-virt.sh"
    source      = "${path.root}/../custom/files/runner-finalize-nested-virt.sh"
  }

  provisioner "file" {
    destination = "${var.image_folder}/runner-finalize-cleanup.sh"
    source      = "${path.root}/../custom/files/runner-finalize-cleanup.sh"
  }

  provisioner "file" {
    destination = "${var.image_folder}/runner-finalize-units.sh"
    source      = "${path.root}/../custom/files/runner-finalize-units.sh"
  }

  provisioner "file" {
    destination = "${var.helper_script_folder}"
    source      = "${path.root}/../scripts/helpers"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}"
    source      = "${path.root}/../scripts/build"
  }

  provisioner "file" {
    destination = "${var.image_folder}"
    sources = [
      "${path.root}/../assets/post-gen",
      "${path.root}/../scripts/tests",
      "${path.root}/../scripts/docs-gen"
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}/docs-gen/"
    source      = "${path.root}/../../../helpers/software-report-base"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}/toolset.json"
    source      = "${path.root}/../toolsets/toolset-2404.json"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mv ${var.image_folder}/docs-gen ${var.image_folder}/SoftwareReport",
      "mv ${var.image_folder}/post-gen ${var.image_folder}/post-generation"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "TARGET_VOLUME_SIZE_GB=${var.volume_size}",
      "UBUNTU_RELEASE=noble",
      "UBUNTU_MIRROR=http://${var.region}.ec2.archive.ubuntu.com/ubuntu",
      "UBUNTU_SECURITY_MIRROR=http://security.ubuntu.com/ubuntu",
      "ROLAUNCH_SOURCE=/tmp/rolaunch",
      "ROOTFS_COMPACTION_HELPER=/tmp/rootfs-compaction.sh",
      "BOOTSTRAP_APT_TIMEOUT_SECONDS=900",
      "DEBOOTSTRAP_TIMEOUT_SECONDS=1200",
      "CHROOT_APT_TIMEOUT_SECONDS=900"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/bootstrap-minimal-rootfs.sh"
    timeout         = "30m"
  }

  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}",
      "IMAGE_OS=${var.image_os}",
      "IMAGE_FOLDER=${var.image_folder}",
      "IMAGEDATA_FILE=${var.imagedata_file}",
      "HELPER_SCRIPTS=${var.helper_script_folder}",
      "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}",
      "ROOTFS_COMPACTION_HELPER=/tmp/rootfs-compaction.sh",
      "MINIMAL_INCLUDE_FULL_INSTALLERS=true",
      "DEBIAN_FRONTEND=noninteractive",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/apply-minimal-installers.sh"
  }
}
