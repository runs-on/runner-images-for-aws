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

## Descendant images

The GPU and StepSecurity images are packer builds on top of a full AMI. The
steps of `ubuntu-gpu-x64.pkr.hcl` were run on the OCI-built x64 AMI on
2026-11-10 (g4dn.xlarge; as `ubuntu` with sudo like packer's shell
provisioner, but over SSM instead of packer's SSH): driver 595 and CUDA 13.3
install, the modules load after the reboot, the final scripts pass, and the
resulting AMI passes the release test's GPU checks on a T4 (`nvidia-smi`, a
CUDA kernel built with `nvcc`, the same in a container with `--gpus all`).
Not tried: packer itself, the Blackwell test (no g7e capacity that day), the
StepSecurity templates, arm64.

Two things were missing at first, and the build above has both:

- **The `ubuntu` user.** cloud-init creates it at the first boot of Canonical's
  AMI; packer logs in with it and rolaunch gives it the instance's SSH key.
  The Dockerfile creates it first, like cloud-init (uid 1000, sudo without
  password); the install scripts then add it to the same groups as on the
  published image.
- **The kernel of the UKI.** `prepare-direct-uefi.sh`, the last step of every
  descendant, expects GRUB and `/boot/efi`. On an image that booted a UKI it
  writes the UKI of the newest installed linux-aws kernel in its place, with
  the same command line (`systemd-ukify` and `systemd-boot-efi` are in the
  image for that). Without it, a descendant whose packages bring a newer
  kernel would keep booting the old one, without the new kernel's modules.
  On 2026-11-10 the driver's prebuilt modules were for the parent's kernel, so
  the rewritten UKI held the same kernel: a build that changes the kernel has
  not been seen yet.

## Boot time of the full images

First boots on warm snapshots, six launches each in one round, against the
published ubuntu26-full AMIs (m7i.large and m7g.large, us-east-1a, 2026-11-10).
Time to the start of the user data, from VM start on x64 and from kernel start
on arm64 (whose firmware time is not visible from inside):

| | published | OCI |
|---|---|---|
| x64 | 3.59-3.86 s (median 3.70) | 2.73-3.23 s (median 2.82) |
| arm64 | 2.66-2.91 s (median 2.83) | 2.11-2.59 s (median 2.49) |

The arm64 snapshot was still warming: an earlier build of the same image, with
more launches behind it, was at 1.85-2.46 s (median 2.15) in the same round.

Launch to sandboxd in v4 (encrypted root volumes, spot, three jobs per image):
x64 7.2-8.7 s against 7.0-10.2 s for the published AMI, arm64 7.8-8.3 s
against 8.7-10.2 s. Most of that is EC2's own launch time, and the spread
between two jobs of one image is larger than the gain. The runner-images
Pester suite gives the same failures as the published AMIs on both
architectures.

What makes the difference, in the order found:

- **Root volume throughput.** A launch template that names no throughput takes
  the AMI's. Registered without one, the root is a gp3 volume at 125 MiB/s and
  rolaunch reads the runner in 2.0 s; at the published AMIs' 400 MiB/s, 0.9 s.
- **systemd's mount rate limit.** PID 1 starts no mount unit while its mount
  monitor is rate limited (5 changes a second, which the API mounts of early
  boot exceed), so every mount unit ordered before `local-fs.target` waits
  about 0.8 s, and with it `sysinit.target` and everything after. Here that is
  only `var-lib-machines.mount`, masked. The published AMIs wait on `/boot`
  and `/boot/efi` too.
- **The ext4 orphan file.** The kernel reads it block by block when it mounts
  the root. mke2fs gives a 30 GB filesystem 512 blocks: 0.35 s of every boot.
  `orphan_file_size=128k` (32 blocks) makes it 0.02 s.
- **Reserved descriptor blocks.** The first boot's online resize reads every
  reserved group descriptor block one by one. mke2fs reserves 1023 for a
  30 GB filesystem (room for 8 TB) and the resize takes 0.5-0.65 s;
  `resize=536870912` reserves about 250 (2 TB, like the published AMIs).
- **Early root resize.** In full mode the user data waits for the resize
  (0.3-0.5 s). `rolaunch-resize.service` (`rolaunch --resize-root`) runs it as
  soon as the root is writable, while udev and the network come up: 0.35 s
  less on x64, 0.45 s on arm64. The unit is written by
  `configure-full-rolaunch.sh`, so the packer builds of the full images get it
  too.

Not fixed: DHCP completes 0.2-0.3 s later than on the published AMIs, counted
from udev's start, because the services of `basic.target` now start at the
same moment as networkd (holding them back 0.5 s brings DHCP forward 0.18 s on
a reboot; a higher priority for networkd and udevd does not).

## Warming a new snapshot

A new snapshot boots slowly whatever was read from it before. Measured on a
fresh copy of a full AMI, m7i.large, time from pending to the end of rolaunch
and a cold read of `/home/runner` (1.3 GB):

| launch | 2 | 3 | 4 | 5 | 6 | 7 | 8 and later |
|---|---|---|---|---|---|---|---|
| to rolaunch done | 27 s | 21 s | 13 s | 12 s | 10 s | 7.5 s | 6.6-8.7 s |
| read | 59 s | 36 s | 23 s | 16 s | 12 s | 6.5 s | 5-6.7 s |

It is per snapshot and per availability zone (the first launch in another zone
is cold again), it follows the number of volumes created, not the blocks read
(directories never read are warm too) and not the time elapsed, parallel
launches count like sequential ones, and it holds after an idle hour and a
half. Eight launches per zone remove the seconds; the last half second of the
boot keeps improving until about forty. The first launches with encrypted
volumes were slow again on a snapshot warmed with unencrypted ones (17.6, 9.4
and 8.1 s to sandboxd in v4, then 7.2-8.7 s), seen once: warm with the volume
settings of the stack.
