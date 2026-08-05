require "minitest/autorun"
require "digest"
require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

class CompactRootFinalizerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "patches/ubuntu/files/finalize-compact-root.sh")
  BOOT_PROFILE = File.join(ROOT, "patches/ubuntu/files/compact-root.boot-profile")
  DIRECT_INIT = File.join(ROOT, "patches/ubuntu/files/compact-root-direct-init")
  RECOVERY_INIT = File.join(ROOT, "patches/ubuntu/files/compact-root-recovery-init")
  TEMPLATES = %w[
    ubuntu-full-x64.pkr.hcl
    ubuntu-full-arm64.pkr.hcl
    ubuntu-gpu-x64.pkr.hcl
    ubuntu-stepsecurity-x64.pkr.hcl
    ubuntu-stepsecurity-arm64.pkr.hcl
  ].map { |name| File.join(ROOT, "patches/ubuntu/templates", name) }.freeze
  DIRECT_TEMPLATES = %w[
    ubuntu-full-x64.pkr.hcl
    ubuntu-gpu-x64.pkr.hcl
    ubuntu-stepsecurity-x64.pkr.hcl
  ].map { |name| File.join(ROOT, "patches/ubuntu/templates", name) }.freeze
  ARM64_TEMPLATES = %w[
    ubuntu-full-arm64.pkr.hcl
    ubuntu-stepsecurity-arm64.pkr.hcl
  ].map { |name| File.join(ROOT, "patches/ubuntu/templates", name) }.freeze
  AFTER_REBOOT = File.join(ROOT, "patches/ubuntu/files/after-reboot.sh")
  RESIZE_WAIT = File.join(ROOT, "patches/ubuntu/files/wait-for-compact-root-resize.sh")
  WORKFLOW_TEST = File.join(ROOT, ".github/workflows/test.yml")
  BLOCK_DEVICE_RESOLVERS = [SCRIPT, AFTER_REBOOT, RESIZE_WAIT].freeze

  def test_shell_syntax
    [SCRIPT, DIRECT_INIT, RECOVERY_INIT, AFTER_REBOOT, RESIZE_WAIT].each do |path|
      _stdout, stderr, status = Open3.capture3("bash", "-n", path)
      assert status.success?, "#{path}: #{stderr}"
    end
  end

  def test_esp_is_a_lazy_automount
    script = File.read(SCRIPT)
    function = script[/^write_effective_fstab\(\) \{\n.*?^\}\n/m]

    refute_nil function
    assert_includes function, 'add_option(add_option($4, "noauto"), "x-systemd.automount")'
    assert_includes function, 'effective ESP mount is not lazy'
    assert_equal 1, function.scan('add_option(add_option($4, "noauto"), "x-systemd.automount")').length
  end

  def test_basic_target_probe_is_in_boot_profile
    profile = File.read(BOOT_PROFILE)
    script = File.read(SCRIPT)

    assert_match(/^usr\/bin\/systemctl [0-9]+$/, profile)
    assert_includes script, %(readonly profile_sha256="#{Digest::SHA256.hexdigest(profile)}")
  end

  def test_direct_init_persists_failures_before_recovery_reboot
    script = File.read(DIRECT_INIT)
    failure_index = script.index('${STATE}/direct-init.failure')
    sync_index = script.index('${BB} sync || true')
    reboot_index = script.index('${BB} reboot -f')

    refute_nil failure_index
    assert_includes script, '[ ! -r /proc/cmdline ] || ${BB} cat /proc/cmdline'
    assert_includes script, '${BB} mv "${failure_path}.new" "${failure_path}"'
    assert_operator failure_index, :<, sync_index
    assert_operator sync_index, :<, reboot_index
  end

  def test_descendants_wait_for_backing_partition_and_ext4_growth
    wait_script = File.read(RESIZE_WAIT)

    assert_includes wait_script, "/etc/runs-on-overlay/backing-root-mount"
    assert_includes wait_script, '"${fstype}" == ext4'
    assert_includes wait_script, '"${part_number}" == 1'
    assert_includes wait_script, 'blockdev --getsize64 "${disk}"'
    assert_includes wait_script, 'filesystem_gap < 16 * 1024 * 1024'
    [
      File.join(ROOT, "patches/ubuntu/templates", "ubuntu-gpu-x64.pkr.hcl"),
      File.join(ROOT, "patches/ubuntu/templates", "ubuntu-stepsecurity-x64.pkr.hcl"),
      File.join(ROOT, "patches/ubuntu/templates", "ubuntu-stepsecurity-arm64.pkr.hcl")
    ].each do |path|
      template = File.read(path)
      wait_index = template.index("wait-for-compact-root-resize.sh")
      installer_index = path.include?("gpu") ? template.index("install-gpu.sh") : template.index("install-linux.sh")
      refute_nil wait_index, path
      assert_operator wait_index, :<, installer_index, path
    end
  end

  def test_descendant_cleanup_tunes_the_backing_ext4_device
    script = File.read(AFTER_REBOOT)

    assert_includes script, "/etc/runs-on-overlay/backing-root-mount"
    assert_includes script, 'resolve_mount_block_device "${root_mount}"'
    assert_includes script, '${SYS_DEV_BLOCK:-/sys/dev/block}/${device_number}'
    assert_includes script, '"${root_fstype}" =~ ^ext[234]$'
    assert_includes script, 'tune2fs -c 0 "${root_source}"'
    refute_includes script, "grep \" / \""
  end

  def test_mount_block_device_resolver_handles_dev_root_through_sysfs
    resolvers = BLOCK_DEVICE_RESOLVERS.map do |path|
      resolver = File.read(path)[/^resolve_mount_block_device\(\) \{\n.*?^\}\n/m]
      refute_nil resolver, path
      resolver
    end
    assert_equal 1, resolvers.uniq.length

    block_device = Dir.glob("/dev/**/*").find { |path| File.blockdev?(path) }
    skip "test host exposes no block device" unless block_device

    Dir.mktmpdir("compact-root-mount-device") do |dir|
      sys_devices = File.join(dir, "sys/devices/virtual/block", File.basename(block_device))
      sys_dev_block = File.join(dir, "sys/dev/block")
      FileUtils.mkdir_p(sys_devices)
      FileUtils.mkdir_p(sys_dev_block)
      File.symlink(sys_devices, File.join(sys_dev_block, "259:1"))
      command = <<~BASH
        set -eu
        SYS_DEV_BLOCK=#{Shellwords.escape(sys_dev_block)}
        DEV_ROOT=#{Shellwords.escape(File.dirname(block_device))}
        findmnt() {
          case " $* " in
            *' SOURCE '*) printf '/dev/root\\n' ;;
            *' MAJ:MIN '*) printf '259:1\\n' ;;
            *) return 1 ;;
          esac
        }
        readlink() {
          if [[ "$*" == '-f /dev/root' ]]; then
            return 1
          fi
          command readlink "$@"
        }
        #{resolvers.first}
        resolved="$(resolve_mount_block_device /.bootstrap)"
        [[ "${resolved}" == #{Shellwords.escape(block_device)} ]]
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
    end
  end

  def test_fresh_target_is_resolved_and_rejected_fail_closed
    script = File.read(SCRIPT)

    assert_includes script, 'ebsnvme-id -b "${disk}"'
    assert_includes script, 'expected one Nitro disk for ${target_mapping}'
    assert_includes script, 'target resolves to the builder root disk'
    assert_includes script, "os.O_RDWR | os.O_EXCL | os.O_CLOEXEC"
    assert_includes script, 'fresh target already contains a recognized signature'
  end

  def test_partition_type_requires_a_canonical_gpt_guid
    command = <<~BASH
      source #{Shellwords.escape(SCRIPT)}
      trap - EXIT INT TERM
      sgdisk() {
        printf '%s\n' \
          'Partition GUID code: BC13C2FF-59E6-4262-A352-B275FD6F7172 (XBOOTLDR partition)' \
          'Partition unique GUID: 78CF0641-D0E8-4107-B856-6980732F3C6F'
      }
      parsed_type="$(partition_field /dev/fake 13 'Partition GUID code')"
      [[ "${parsed_type}" == BC13C2FF-59E6-4262-A352-B275FD6F7172 ]]
      valid_partition_type_guid "${parsed_type}"
      valid_partition_type_guid BC13C2FF-59E6-4262-A352-B275FD6F7172
      valid_partition_type_guid 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
      ! valid_partition_type_guid 8300
      ! valid_partition_type_guid BC13C2FF-59E6-4262-A352
      ! valid_partition_type_guid 'BC13C2FF-59E6-4262-A352-B275FD6F7172 (XBOOTLDR)'
    BASH

    _stdout, stderr, status = Open3.capture3("bash", "-c", command)

    assert status.success?, stderr
    assert_includes File.read(SCRIPT), 'type=${type:-missing}'
  end

  def test_direct_target_preallocates_the_complete_squashfs_before_writing
    script = File.read(SCRIPT)

    assert_includes script, "-E nodiscard,lazy_itable_init=0,lazy_journal_init=0"
    preallocate = script.index('fallocate -l "${size}" "${staged}"')
    write = script.index('dd if="${source}" of="${staged}"')
    refute_nil preallocate
    refute_nil write
    assert_operator preallocate, :<, write
    refute_includes script, '.root-allocation-seed'
    assert_includes script, '[[ "${filesystem_block_size}" == 4096 ]]'
    assert_equal 2, script.scan('squash_header_is_early "${first_block}"').length
    assert_includes script, '"${extent_count}" -le 20'
    refute_match(/\b(?:blkdiscard|fstrim)\b/, script)
    refute_includes script, "materialize-sparse-ebs"
  end

  def test_squash_header_gate_rejects_late_and_unknown_blocks
    command = <<~BASH
      source #{Shellwords.escape(SCRIPT)}
      trap - EXIT INT TERM
      squash_header_is_early 34816
      squash_header_is_early 262143
      ! squash_header_is_early 262144
      ! squash_header_is_early 7569408
      ! squash_header_is_early ''
      ! squash_header_is_early unknown
    BASH

    _stdout, stderr, status = Open3.capture3("bash", "-c", command)

    assert status.success?, stderr
  end

  def test_unsupported_tpm_acl_is_removed_and_boot_paths_share_the_upper
    script = File.read(SCRIPT)
    recovery = File.read(RECOVERY_INIT)

    assert_includes script, 'var/lib/tpm2-tss/system/keystore'
    assert_includes script, 'setfacl --remove-all --remove-default'
    assert_includes script, 'expected TPM keystore default ACL is missing'
    assert_includes script, 'TPM keystore still has an extended POSIX ACL'
    refute_includes script, 'compact-root-acl.py'
    refute_includes script, '--ignore-posix-acl'
    refute_includes script, "grep -Ev 'system\\.posix_acl_"
    TEMPLATES.each do |path|
      refute_includes File.read(path), 'compact-root-acl.py', path
    end
    assert_includes recovery, 'upperdir=${STATE}/upper,workdir=${STATE}/work'
    assert_includes recovery, 'PARTUUID) candidate_partuuid=${value} ;;'
    assert_includes recovery, '[ "${candidate_partuuid}" = "${desired_partuuid}" ] || continue'
    refute_includes recovery, '${BB} blkid'
    refute_includes recovery, "recovery-upper"
    refute_includes recovery, "recovery-work"
  end

  def test_workflow_requires_compact_tpm_acl_to_be_empty
    workflow = File.read(WORKFLOW_TEST)

    assert_includes workflow, 'runtime_keystore=/var/lib/tpm2-tss/system/keystore'
    assert_includes workflow, 'if sudo test -L "$runtime_keystore"; then'
    assert_includes workflow, 'elif sudo test -e "$runtime_keystore"; then'
    assert_includes workflow, 'sudo test -d "$runtime_keystore"'
    assert_includes workflow, 'test ! -s "$runtime_acl"'
    assert_includes workflow, 'if sudo test -L "$upper_keystore"; then'
    assert_includes workflow, 'elif sudo test -e "$upper_keystore"; then'
    assert_includes workflow, 'sudo test -d "$upper_keystore"'
    assert_includes workflow, 'test ! -s "$upper_acl"'
    assert_includes workflow, 'if [[ -n "$runtime_acl" ]]; then'
    refute_match(/^\s*test -s "\$runtime_acl"/, workflow)
    refute_match(/^\s*test -s "\$upper_acl"/, workflow)
  end

  def test_workflow_validates_arm64_compact_grub_boot
    workflow = File.read(WORKFLOW_TEST)

    assert_includes workflow, "ubuntu26-full-arm64|ubuntu26-stepsecurity-arm64"
    assert_includes workflow, 'if [[ "$boot_path" == grub-initramfs-recovery ]]; then'
    assert_includes workflow, 'runtime_dir=recovery-runtime'
    assert_includes workflow, 'test "$boot_path" = grub-initramfs-recovery'
  end

  def test_tpm_acl_normalization_removes_only_the_expected_acl
    Dir.mktmpdir("compact-root-acl-normalization") do |dir|
      root = File.join(dir, "root")
      keystore = File.join(root, "var/lib/tpm2-tss/system/keystore")
      evidence = File.join(dir, "removed.getfacl")
      marker = File.join(dir, "removed")
      calls = File.join(dir, "setfacl.calls")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        mkdir -p #{Shellwords.escape(keystore)}
        getfacl() {
          if [[ ! -e #{Shellwords.escape(marker)} ]]; then
            printf '%s\n' \
              '# file: #{keystore}' \
              '# owner: 0' \
              '# group: 0' \
              'default:user::rwx' \
              'default:group::---' \
              'default:other::---'
          fi
        }
        setfacl() {
          printf '%s\n' "$*" > #{Shellwords.escape(calls)}
          : > #{Shellwords.escape(marker)}
        }
        remove_irrelevant_tpm_acl \
          #{Shellwords.escape(root)} \
          #{Shellwords.escape(evidence)}
        [[ -s #{Shellwords.escape(evidence)} ]]
        [[ "$(< #{Shellwords.escape(calls)})" == \
          '--remove-all --remove-default -- #{keystore}' ]]
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
    end
  end

  def test_tpm_acl_normalization_accepts_an_already_clean_descendant
    Dir.mktmpdir("compact-root-clean-acl") do |dir|
      root = File.join(dir, "root")
      keystore = File.join(root, "var/lib/tpm2-tss/system/keystore")
      evidence = File.join(dir, "removed.getfacl")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        mkdir -p #{Shellwords.escape(keystore)}
        getfacl() { :; }
        setfacl() { return 99; }
        remove_irrelevant_tpm_acl \
          #{Shellwords.escape(root)} \
          #{Shellwords.escape(evidence)}
        [[ -f #{Shellwords.escape(evidence)} ]]
        [[ ! -s #{Shellwords.escape(evidence)} ]]
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
    end
  end

  def test_tpm_acl_normalization_accepts_a_missing_keystore
    Dir.mktmpdir("compact-root-missing-tpm-keystore") do |dir|
      root = File.join(dir, "root")
      evidence = File.join(dir, "removed.getfacl")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        mkdir -p #{Shellwords.escape(root)}
        getfacl() { return 99; }
        setfacl() { return 99; }
        remove_irrelevant_tpm_acl \
          #{Shellwords.escape(root)} \
          #{Shellwords.escape(evidence)}
        [[ -f #{Shellwords.escape(evidence)} ]]
        [[ ! -s #{Shellwords.escape(evidence)} ]]
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
    end
  end

  def test_tpm_acl_normalization_rejects_a_non_directory_keystore
    Dir.mktmpdir("compact-root-invalid-tpm-keystore") do |dir|
      root = File.join(dir, "root")
      keystore = File.join(root, "var/lib/tpm2-tss/system/keystore")
      evidence = File.join(dir, "removed.getfacl")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        mkdir -p #{Shellwords.escape(File.dirname(keystore))}
        : > #{Shellwords.escape(keystore)}
        remove_irrelevant_tpm_acl \
          #{Shellwords.escape(root)} \
          #{Shellwords.escape(evidence)}
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      refute status.success?
      assert_includes stderr, "expected TPM keystore path is not a directory"
    end
  end

  def test_tpm_acl_normalization_rejects_a_live_symlink_keystore
    Dir.mktmpdir("compact-root-symlink-tpm-keystore") do |dir|
      root = File.join(dir, "root")
      keystore = File.join(root, "var/lib/tpm2-tss/system/keystore")
      target = File.join(dir, "target")
      evidence = File.join(dir, "removed.getfacl")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        mkdir -p #{Shellwords.escape(File.dirname(keystore))} #{Shellwords.escape(target)}
        ln -s #{Shellwords.escape(target)} #{Shellwords.escape(keystore)}
        remove_irrelevant_tpm_acl \
          #{Shellwords.escape(root)} \
          #{Shellwords.escape(evidence)}
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      refute status.success?
      assert_includes stderr, "expected TPM keystore path is not a directory"
    end
  end

  def test_tpm_acl_normalization_rejects_a_dangling_symlink_keystore
    Dir.mktmpdir("compact-root-dangling-tpm-keystore") do |dir|
      root = File.join(dir, "root")
      keystore = File.join(root, "var/lib/tpm2-tss/system/keystore")
      evidence = File.join(dir, "removed.getfacl")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        mkdir -p #{Shellwords.escape(File.dirname(keystore))}
        ln -s missing-target #{Shellwords.escape(keystore)}
        remove_irrelevant_tpm_acl \
          #{Shellwords.escape(root)} \
          #{Shellwords.escape(evidence)}
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      refute status.success?
      assert_includes stderr, "expected TPM keystore path is not a directory"
    end
  end

  def test_boot_packages_are_held_and_recorded
    Dir.mktmpdir("compact-root-boot-holds") do |dir|
      held = File.join(dir, "held")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        dpkg-query() {
          printf '%s\n' \
            $'linux-image-7.0.0-1010-aws\tii ' \
            $'linux-image-aws:amd64\tii ' \
            $'grub2-common\tii ' \
            $'shim-signed\trc '
        }
        apt-mark() {
          case "$1" in
            hold)
              shift
              printf '%s\n' "$@" > #{Shellwords.escape(held)}
              ;;
            showhold)
              cat #{Shellwords.escape(held)}
              ;;
            *) return 1 ;;
          esac
        }
        hold_boot_packages #{Shellwords.escape(dir)}
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
      expected = %w[grub2-common linux-image-7.0.0-1010-aws linux-image-aws]
      assert_equal expected, File.readlines(held, chomp: true)
      assert_equal(
        expected,
        File.readlines(File.join(dir, "etc/runs-on-compact-root/held-boot-packages"), chomp: true)
      )
      preferences = File.read(File.join(dir, "etc/apt/preferences.d/runs-on-compact-boot"))
      assert_includes preferences, "linux-image-*-aws"
      assert_includes preferences, "linux-modules-nvidia-*-aws"
      assert_includes preferences, "grub-efi-amd64-signed"
      assert_includes preferences, "shim-signed"
      assert_includes preferences, "Pin-Priority: -1"
      refute_includes File.read(held), "shim-signed"
    end
  end

  def test_recovery_resolves_partuuid_from_kernel_uevent
    recovery = File.read(RECOVERY_INIT)
    resolver = recovery[/^resolve_partuuid_device\(\) \{\n.*?^\}\n/m]
    refute_nil resolver
    block_device = Dir.glob("/dev/**/*").find { |path| File.blockdev?(path) }
    skip "test host exposes no block device" unless block_device

    Dir.mktmpdir("compact-root-partuuid") do |dir|
      sys_class = File.join(dir, "sys/class/block")
      uevent_dir = File.join(sys_class, "nvme0n1p1")
      FileUtils.mkdir_p(uevent_dir)
      File.write(
        File.join(uevent_dir, "uevent"),
        "MAJOR=259\nMINOR=1\nDEVNAME=#{File.basename(block_device)}\n" \
          "DEVTYPE=partition\nPARTN=1\nPARTUUID=01234567-89ab-cdef-0123-456789abcdef\n"
      )
      command = <<~BASH
        set -eu
        BB=/bin/false
        SYS_CLASS_BLOCK=#{Shellwords.escape(sys_class)}
        DEV_ROOT=#{Shellwords.escape(File.dirname(block_device))}
        #{resolver}
        resolved="$(resolve_partuuid_device 01234567-89ab-cdef-0123-456789abcdef)"
        [[ "${resolved}" == #{Shellwords.escape(block_device)} ]]
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
    end
  end

  def test_native_ssh_stays_disabled_but_can_be_enabled_by_builder_user_data
    script = File.read(SCRIPT)

    assert_includes script, "for ssh_unit in ssh.service ssh.socket"
    assert_includes script, 'ssh_unit_state="$(systemctl is-enabled "${ssh_unit}" 2>/dev/null || true)"'
    assert_includes script, '[[ "${ssh_unit_state}" == disabled ]]'
    refute_includes script, 'systemctl is-enabled "${ssh_unit}" 2>/dev/null | grep'
    refute_includes script, 'ln -sfn /dev/null "${target_mount}/runs-on-root/upper/etc/systemd/system/ssh.service"'
    refute_includes script, 'ln -sfn /dev/null "${target_mount}/runs-on-root/upper/etc/systemd/system/ssh.socket"'
  end

  def test_root_writing_services_are_quiesced_before_source_capture
    script = File.read(SCRIPT)
    main_index = script.index("\nmain() {")
    quiesce_index = script.index("\n  quiesce_root_writers\n", main_index)
    socket_cleanup_index = script.index("\n  clean_socket_nodes\n", main_index)
    acl_removal_index = script.index("\n  remove_irrelevant_tpm_acl / ", main_index)
    manifest_index = script.index('"${work_dir}/source-tree-full.json"', main_index)

    %w[
      amazon-ssm-agent.service
      chrony.service
      irqbalance.service
      rsyslog.service
      syslog.socket
      rsyslog.socket
      cron.service
      udisks2.service
    ].each do |unit|
      assert_includes script, unit
    end
    assert_includes script, "systemctl list-units --type=timer --state=active"
    assert_includes script, "'php*-fpm.service'"
    assert_includes script, 'systemctl stop "${unit}"'
    assert_includes script, 'systemctl is-active "${unit}"'
    refute_nil quiesce_index
    refute_nil acl_removal_index
    assert_operator quiesce_index, :<, socket_cleanup_index
    assert_operator socket_cleanup_index, :<, acl_removal_index
    assert_operator acl_removal_index, :<, manifest_index
    assert_operator socket_cleanup_index, :<, manifest_index
  end

  def test_boot_profile_gate_measures_unique_eligible_file_coverage
    script = File.read(SCRIPT)

    assert_includes script, "--min-output-count 900"
    assert_includes script, "--min-coverage-percent 99"
    refute_includes script, 'report["output_count"] * 100 >= report["input_count"] * 70'
  end

  def test_merged_overlay_manifest_accepts_lower_device_numbers
    script = File.read(SCRIPT)

    assert_includes script, '"${merged}" "${work_dir}/merged-tree-full.json" --cross-filesystems'
  end

  def test_capture_uses_an_isolated_non_recursive_view
    script = File.read(SCRIPT)

    isolate_index = script.index("isolate_builder_mounts", script.index("main()"))
    source_view_index = script.index('create_source_view "${source_root}"')
    target_mount_index = script.index('mount -o rw "${target_p1}" "${target_mount}"')
    refute_nil isolate_index
    assert_operator isolate_index, :<, source_view_index
    assert_operator isolate_index, :<, target_mount_index
    assert_includes script, 'mount --bind / "${source_root}"'
    assert_includes script, 'mount --make-private "${source_root}"'
    assert_includes script, 'findmnt -Rnr -o TARGET --target "${source_root}"'
    assert_includes script, '"${exclude_args[@]}" --cross-filesystems'
    assert_includes script, '--cross-filesystems \\'
    assert_includes script, 'mksquashfs "${source_root}" "${squash}"'
    refute_includes script, '-one-file-system'
    assert_includes script, 'is on a different filesystem, ignored'
    assert_operator script.index('assert_isolated_source_view "${source_root}"', script.index('build_squash "${source_root}"')), :<, script.index('umount "${source_root}"')
  end

  def test_builder_mount_isolation_fails_closed
    command = <<~BASH
      source #{Shellwords.escape(SCRIPT)}
      trap - EXIT INT TERM
      mount() {
        [[ "$*" == "--make-rprivate /" ]]
      }
      findmnt() {
        printf '%s\n' shared
      }
      isolate_builder_mounts
    BASH

    _stdout, stderr, status = Open3.capture3("bash", "-c", command)

    refute status.success?
    assert_includes stderr, "builder root mount propagation is not private"
  end

  def test_capture_view_rejects_nested_mounts
    command = <<~BASH
      source #{Shellwords.escape(SCRIPT)}
      trap - EXIT INT TERM
      findmnt() {
        printf '%s\n' /capture /capture/nested
      }
      assert_isolated_source_view /capture
    BASH

    _stdout, stderr, status = Open3.capture3("bash", "-c", command)

    refute status.success?
    assert_includes stderr, "capture source view contains a nested mount"
  end

  def test_cleanup_unmounts_only_nested_mounts_before_removal
    Dir.mktmpdir("compact-root-unmount") do |dir|
      calls = File.join(dir, "umount.calls")
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        after=false
        findmnt() {
          if [[ "${after}" == true ]]; then
            printf '%s\n' / /run /srv
          else
            printf '%s\n' \
              / \
              /run \
              /run/capture/source \
              /run/capture/lower \
              /srv \
              /srv/unrelated
          fi
        }
        umount() {
          printf '%s\n' "$1" >> #{Shellwords.escape(calls)}
          after=true
        }
        unmount_tree /run/capture
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
      assert_equal(
        ["/run/capture/source", "/run/capture/lower"],
        File.readlines(calls, chomp: true)
      )
    end
    script = File.read(SCRIPT)
    assert_includes script, '"${validation_safe}" == true'
    assert_includes script, 'mount remains below %s'
  end

  def test_cleanup_refuses_removal_when_a_mount_remains
    command = <<~BASH
      source #{Shellwords.escape(SCRIPT)}
      trap - EXIT INT TERM
      findmnt() {
        printf '%s\n' / /run/capture/source
      }
      umount() {
        return 1
      }
      unmount_tree /run/capture
    BASH

    _stdout, stderr, status = Open3.capture3("bash", "-c", command)

    refute status.success?
    assert_includes stderr, "cannot unmount /run/capture/source"
    assert_includes stderr, "mount remains below /run/capture"
  end

  def test_workspace_persistent_tree_is_owned_by_runner
    script = File.read(SCRIPT)

    assert_includes script, 'install -d -m 0755 -o runner -g runner "/${path}"'
    assert_operator script.index('install -d -m 0755 -o runner -g runner "/${path}"'), :<, script.index('copy_tree "/${path}"')
  end

  def test_persistent_temporary_tree_preserves_sticky_mode
    script = File.read(SCRIPT)

    assert_includes script, 'rsync -aHAXx --numeric-ids "${source%/}" "${destination_parent}/"'
  end

  def test_finalizer_creates_temporary_directories_with_sticky_mode
    script = File.read(SCRIPT)

    assert_includes script, 'tmp|var/tmp) install -d -m 1777 "/${path}"'
  end

  def test_boot_paths_use_fresh_target_and_stable_direct_kernel
    script = File.read(SCRIPT)

    assert_includes script, 'grub-install --target=i386-pc'
    assert_includes script, 'DIRECT_UEFI_DISK="${target_disk}"'
    assert_includes script, "DIRECT_UEFI_EXTRA_ARGUMENTS='rw init=/runs-on-root/init"
    assert_includes script, "target root PARTUUID was reused"
    assert_includes script, "target BIOS PARTUUID was reused"
    assert_includes script, "target filesystem identity was reused"
    assert_operator script.index('"${asset_dir}/prepare-direct-uefi.sh"'), :<, script.index('write_grub_config "${target_mount}/boot"')
    assert_includes script, 'expected-recovery-cmdline'
    assert_includes script, 'recovery_arguments+=("console=ttyS0" "panic=0" "runs_on.recovery=1")'
    assert_includes script, "CONFIG_BLK_DEV_LOOP CONFIG_SQUASHFS CONFIG_SQUASHFS_ZSTD CONFIG_SQUASHFS_CHOICE_DECOMP_BY_MOUNT"
    refute_includes script, "console=ttyS0,115200n8"
    refute_includes script, "systemd.show_status=true"
    assert_includes File.read(File.join(ROOT, "patches/ubuntu/files/prepare-direct-uefi.sh")), 'direct_filename="vmlinuz.efi"'
  end

  def test_recovery_cmdline_is_derived_from_persisted_direct_state
    Dir.mktmpdir("compact-recovery-cmdline") do |dir|
      direct = File.join(dir, "expected-cmdline")
      recovery = File.join(dir, "expected-recovery-cmdline")
      File.write(
        direct,
        "root=PARTUUID=fresh rw panic=-1 console=null quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false init=/runs-on-root/init runs_on.immutable=1 runs_on.squash_threads=percpu\n"
      )
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        write_recovery_cmdline #{Shellwords.escape(direct)} #{Shellwords.escape(recovery)}
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
      assert_equal(
        "root=PARTUUID=fresh rw runs_on.immutable=1 runs_on.squash_threads=percpu console=ttyS0 panic=0 runs_on.recovery=1\n",
        File.read(recovery)
      )
      assert_equal 0o644, File.stat(recovery).mode & 0o777
    end
  end

  def test_arm64_primary_grub_cmdline_selects_the_compact_root
    command = <<~BASH
      source #{Shellwords.escape(SCRIPT)}
      trap - EXIT INT TERM
      write_grub_boot_cmdline 8f2eaf70-4e41-4d0b-b0de-3f6253d7d4d4
    BASH

    stdout, stderr, status = Open3.capture3("bash", "-c", command)

    assert status.success?, stderr
    assert_equal(
      "root=PARTUUID=8f2eaf70-4e41-4d0b-b0de-3f6253d7d4d4 rw runs_on.immutable=1 runs_on.squash_threads=percpu console=ttyS0 panic=0\n",
      stdout
    )
  end

  def test_finalizer_is_last_and_surrogate_only
    DIRECT_TEMPLATES.each do |path|
      template = File.read(path)
      finalizer = template.index("finalize-compact-root.sh")

      refute_nil finalizer, path
      assert_operator finalizer, :>, template.index("prepare-direct-uefi.sh"), path
      final_block = template[template.rindex('provisioner "shell"', finalizer)..]
      assert_includes final_block, 'only = ["amazon-ebssurrogate.compact_root"]', path
      assert_equal 1, template.scan("finalize-compact-root.sh").length, path
    end

    ARM64_TEMPLATES.each do |path|
      template = File.read(path)
      finalizer = template.index("finalize-compact-root.sh")

      refute_nil finalizer, path
      refute_includes template, "prepare-direct-uefi.sh", path
      refute_includes template, "compact-root-direct-init", path
      final_block = template[template.rindex('provisioner "shell"', finalizer)..]
      assert_includes final_block, 'only = ["amazon-ebssurrogate.compact_root"]', path
      assert_equal 1, template.scan("finalize-compact-root.sh").length, path
    end
  end

  def test_direct_uefi_init_is_installed_only_for_amd64
    script = File.read(SCRIPT)

    assert_match(
      /if \[\[ "\$\{architecture\}" == amd64 \]\]; then\n\s+install -m 0755 "\$\{asset_dir\}\/compact-root-direct-init"/,
      script,
    )
  end
end
