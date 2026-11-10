# oci2ami (spike)

One OCI image for every way RunsOn runs a job, turned into an AMI when a job
needs a whole EC2 instance. Spike from 2026-11-10, x64 only, not used by any
image build.

- `job.Dockerfile`: the job image (Ubuntu 26.04, the runner, Docker, sudo).
  Nothing in it knows how it boots: Lambda MicroVMs, hostd's Firecracker and
  Nitro sandboxes and the Docker driver can run it as it is.
- `ec2.Dockerfile`: the EC2 boot layer on top: `linux-image-aws`, systemd as
  init, networkd DHCP, rolaunch and its early units, the bootstrap binaries,
  and the unit set of the minimal images (Docker on its socket, no ldconfig,
  apt timers or getty on tty1, a volatile journal).
- `oci2ami.sh IMAGE DEVICE`: exports the image, writes a GPT disk with a
  64 MiB EFI partition holding a UKI (the image's kernel and the minimal
  images' command line, no initrd, no GRUB) and an ext4 root with a fixed
  PARTUUID, and the files Docker owns at run time (`/etc/hosts`,
  `/etc/resolv.conf`, `/etc/hostname`, `/etc/fstab`).
- `build.sh DEVICE`: all three on a builder with an empty EBS volume.

Measured on the v4 dev stack (demo branch `v4-test/oci-ami`): jobs pass with
Docker; the build takes about 1 minute for the EC2 layer and 45 s for the disk,
plus 2-2.5 minutes for the snapshot. A new snapshot boots slowly for its first
boots (user data at 10-12 s after power-on) and warms within the hour
(2.2-2.4 s, against 1.6-1.9 s for the published minimal AMI). Warm, a v4 job
goes from launch to sandboxd in 7.2-10.2 s (median 8.6 s), against 6.8-8.4 s
(median 7.5 s) for the minimal AMI, n=6 each.
