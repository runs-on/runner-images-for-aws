packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.0"
    }
  }
}

variable "ami_name" { type = string }
variable "parent_ami_id" { type = string }
variable "rolaunch_binary" { type = string }
variable "region" { type = string }
variable "subnet_id" { type = string }
variable "variant" {
  type = string
  validation {
    condition     = contains(["baseline", "candidate"], var.variant)
    error_message = "Variant must be baseline or candidate."
  }
}

source "amazon-ebs" "rolaunch_sibling" {
  ami_name                                  = var.ami_name
  ami_description                           = "Private TTFS ${var.variant} sibling derived from ${var.parent_ami_id}"
  ami_virtualization_type                   = "hvm"
  associate_public_ip_address               = true
  ebs_optimized                             = true
  instance_type                             = "m8a.large"
  region                                    = var.region
  source_ami                                = var.parent_ami_id
  ssh_username                              = "ubuntu"
  subnet_id                                 = var.subnet_id
  temporary_security_group_source_public_ip = true

  run_tags = {
    creator      = "RunsOn"
    experiment   = "cold-flex-ttfs"
    parent_ami   = var.parent_ami_id
    ttfs_variant = var.variant
  }
  tags = {
    creator      = "RunsOn"
    experiment   = "cold-flex-ttfs"
    parent_ami   = var.parent_ami_id
    ttfs_variant = var.variant
  }
  snapshot_tags = {
    creator      = "RunsOn"
    experiment   = "cold-flex-ttfs"
    parent_ami   = var.parent_ami_id
    ttfs_variant = var.variant
  }

  user_data = <<EOF
#!/bin/bash
systemctl enable ssh
systemctl start ssh
EOF
}

build {
  sources = ["source.amazon-ebs.rolaunch_sibling"]

  provisioner "file" {
    source      = var.rolaunch_binary
    destination = "/tmp/rolaunch"
  }

  provisioner "shell" {
    environment_vars = ["IMAGE_OS=ubuntu26"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -eu",
      "test -s /tmp/rolaunch",
      "install -o root -g root -m 0755 /tmp/rolaunch /usr/bin/.rolaunch.new",
      "sync /usr/bin/.rolaunch.new",
      "mv -f /usr/bin/.rolaunch.new /usr/bin/rolaunch",
      "/usr/bin/rolaunch --help >/dev/null",
      "rm -f /tmp/rolaunch",
      "rm -f /runs-on/config.json /runs-on/instance-config.json /runs-on/env /runs-on/env.custom /runs-on/aws-container-auth-token",
      "rm -rf /var/lib/rolaunch/prefetch /var/lib/rolaunch/agent"
    ]
  }

  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Reboot VM'", "sudo reboot"]
  }

  provisioner "shell" {
    environment_vars = ["IMAGE_OS=ubuntu26"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    pause_before     = "1m0s"
    scripts = [
      "${path.root}/../../releases/ubuntu26/x64/images/ubuntu/scripts/build/cleanup.sh",
      "${path.root}/../../patches/ubuntu/files/after-reboot.sh",
      "${path.root}/../../patches/ubuntu/files/finalize-rolaunch-descendant.sh",
      "${path.root}/../../patches/ubuntu/files/prepare-direct-uefi.sh"
    ]
    start_retry_timeout = "10m"
  }
}
