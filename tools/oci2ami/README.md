# oci2ami (spike)

One OCI image for every way RunsOn runs a job, turned into an AMI when a job
needs a whole EC2 instance. Spike from 2026-11-10, x64 and arm64, not used by
any image build.

- `job.Dockerfile`: the job image (Ubuntu 26.04, the runner, Docker, sudo).
  Nothing in it knows how it boots: Lambda MicroVMs, hostd's Firecracker and
  Nitro sandboxes and the Docker driver can run it as it is.
- `ec2.Dockerfile`: the EC2 boot layer on top: `linux-image-aws`, systemd as
  init, networkd DHCP, rolaunch and its early units, the bootstrap binaries,
  and the unit set of the minimal images (Docker on its socket, no ldconfig,
  apt timers or getty on tty1, a volatile journal).
- `oci2ami.sh IMAGE DEVICE`: exports the image, writes a GPT disk with a
  256 MiB EFI partition holding a UKI (the image's kernel and the minimal
  images' command line, no initrd, no GRUB) and an ext4 root with a fixed
  PARTUUID, and the files Docker owns at run time (`/etc/hosts`,
  `/etc/resolv.conf`, `/etc/hostname`, `/etc/fstab`). `KERNEL_ARGS` sets the
  command line; an image can leave its own `hosts`, `hostname` and
  `resolv.conf` in `/etc/oci2ami`.
- `build.sh DEVICE`: all three on a builder with an empty EBS volume.

Measured on the v4 dev stack (demo branch `v4-test/oci-ami`): jobs pass with
Docker; the build takes about 1 minute for the EC2 layer and 45 s for the disk,
plus 2-2.5 minutes for the snapshot. A new snapshot boots slowly for its first
boots (user data at 10-12 s after power-on) and warms within the hour
(2.2-2.4 s, against 1.6-1.9 s for the published minimal AMI). Warm, a v4 job
goes from launch to sandboxd in 7.2-10.2 s (median 8.6 s), against 6.8-8.4 s
(median 7.5 s) for the minimal AMI, n=6 each.

## Full images (`full/`)

The Ubuntu 26 full image built as an OCI image from the same scripts as the
packer template `patches/ubuntu/templates/ubuntu-full-<arch>.pkr.hcl`, in the
same order, on Canonical's cloud image root (`resolute-server-cloudimg-<arch>-root.tar.xz`).
The approach follows sprinters-sh/sprinters-images, which runs the
runner-images scripts in a Dockerfile.

- `gen-dockerfile.sh IMAGE_ID`: the Dockerfile, one `RUN` per provisioner, the
  install scripts read from `config.yml`.
- `shims/`: commands that need a booted machine, for the build only:
  `systemctl` changes unit files but skips start, stop and reload; `snap`,
  `modprobe`, `tune2fs` and `update-grub` do nothing; `invoke_tests` records a
  failed Pester test in `/imagegeneration/oci-test-failures.txt` and goes on;
  services installed by apt stay stopped (`policy-rc.d`).
- `patches/<script>`: the edits a script needs in a build (no cloud-init
  boot, `/etc/hosts` and `/etc/resolv.conf` are Docker's, an overlayfs root, no
  Docker daemon or podman network, no journald, no SSH host keys, no
  `CAP_NET_ADMIN`). Each must match or the build stops. `step.sh` applies them
  to a copy of the script and runs it like packer; each step bind-mounts only
  its scripts and edits, so changing one rebuilds from that step.
- `prepull.sh`: the Docker images `install-docker.sh` pulls (Dependabot,
  gh-aw, github-mcp-server: 3.4 GB) are pulled at conversion, by the image's
  own containerd and dockerd run against the exported root (`ROOT_HOOK` of
  `oci2ami.sh`). The OCI image itself does not carry them.
- `build.sh context IMAGE_ID DIR`, then `build.sh image DIR DEVICE` on a
  builder of the image's architecture. Register the AMI with its root on
  `/dev/sda1`, like the published ones: launch templates size the root volume
  on that device name, and on another it becomes a second, empty disk.

The packer reboot is not replayed, and `prepare-direct-uefi.sh` is replaced by
the converter's UKI (arm64 included, which the published image boots with GRUB).
