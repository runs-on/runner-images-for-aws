require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"

class CompactRootFinalizerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "patches/ubuntu/files/finalize-compact-root.sh")
  RECOVERY_INIT = File.join(ROOT, "patches/ubuntu/files/compact-root-recovery-init")
  TEMPLATES = %w[
    ubuntu-full-x64.pkr.hcl
    ubuntu-gpu-x64.pkr.hcl
    ubuntu-stepsecurity-x64.pkr.hcl
  ].map { |name| File.join(ROOT, "patches/ubuntu/templates", name) }.freeze
  AFTER_REBOOT = File.join(ROOT, "patches/ubuntu/files/after-reboot.sh")
  RESIZE_WAIT = File.join(ROOT, "patches/ubuntu/files/wait-for-compact-root-resize.sh")

  def test_shell_syntax
    [SCRIPT, RECOVERY_INIT, AFTER_REBOOT, RESIZE_WAIT].each do |path|
      _stdout, stderr, status = Open3.capture3("bash", "-n", path)
      assert status.success?, "#{path}: #{stderr}"
    end
  end

  def test_descendants_wait_for_backing_partition_and_ext4_growth
    wait_script = File.read(RESIZE_WAIT)

    assert_includes wait_script, "/etc/runs-on-overlay/backing-root-mount"
    assert_includes wait_script, '"${fstype}" == ext4'
    assert_includes wait_script, '"${part_number}" == 1'
    assert_includes wait_script, 'blockdev --getsize64 "${disk}"'
    assert_includes wait_script, 'filesystem_gap < 16 * 1024 * 1024'
    TEMPLATES.drop(1).each do |path|
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
    assert_includes script, 'findmnt -nro SOURCE --target "${root_mount}"'
    assert_includes script, '"${root_fstype}" =~ ^ext[234]$'
    assert_includes script, 'tune2fs -c 0 "${root_source}"'
    refute_includes script, "grep \" / \""
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

  def test_direct_target_uses_winner_squash_placement_without_discard
    script = File.read(SCRIPT)

    assert_includes script, "-E nodiscard,lazy_itable_init=0,lazy_journal_init=0"
    assert_operator script.index('fallocate -l 16M "${seed}"'), :<, script.index('bs=16M count=1')
    assert_operator script.index('bs=16M count=1'), :<, script.index('fallocate -l "${size}"')
    assert_includes script, '"${first_block}" -lt 1048576'
    assert_includes script, '"${extent_count}" -le 20'
    refute_match(/\b(?:blkdiscard|fstrim)\b/, script)
    refute_includes script, "materialize-sparse-ebs"
  end

  def test_acl_and_same_upper_contracts_are_mandatory
    script = File.read(SCRIPT)
    recovery = File.read(RECOVERY_INIT)

    assert_includes script, 'acl_directory_count"] > 0'
    assert_includes script, 'var/lib/tpm2-tss/system/keystore'
    assert_includes script, 'compact-root-acl.py" restore'
    assert_includes script, 'restored ACL manifest differs'
    assert_includes script, 'TPM keystore ACL was not copied into the persistent upper'
    assert_includes recovery, 'upperdir=${STATE}/upper,workdir=${STATE}/work'
    assert_includes recovery, '${BB} blkid -s PARTUUID -o value "${candidate}"'
    refute_match(/PARTUUID\) candidate_partuuid=/, recovery)
    refute_includes recovery, "recovery-upper"
    refute_includes recovery, "recovery-work"
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
    manifest_index = script.index('"${work_dir}/source-acl.json"', main_index)

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
    assert_operator quiesce_index, :<, socket_cleanup_index
    assert_operator socket_cleanup_index, :<, manifest_index
  end

  def test_boot_profile_gate_measures_unique_eligible_file_coverage
    script = File.read(SCRIPT)

    assert_includes script, "--min-output-count 900"
    assert_includes script, "--min-coverage-percent 99"
    refute_includes script, 'report["output_count"] * 100 >= report["input_count"] * 70'
  end

  def test_boot_paths_use_fresh_target_and_stable_direct_kernel
    script = File.read(SCRIPT)

    assert_includes script, 'grub-install --target=i386-pc'
    assert_includes script, 'DIRECT_UEFI_DISK="${target_disk}"'
    assert_includes script, "target root PARTUUID was reused"
    assert_includes script, "target BIOS PARTUUID was reused"
    assert_includes script, "target filesystem identity was reused"
    assert_operator script.index('"${asset_dir}/prepare-direct-uefi.sh"'), :<, script.index('write_grub_config "${target_mount}/boot"')
    assert_includes script, 'expected-recovery-cmdline'
    assert_includes script, 'recovery_arguments+=("console=ttyS0" "runs_on.recovery=1")'
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
        "root=PARTUUID=fresh ro console=null quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false init=/runs-on-root/init runs_on.immutable=1 runs_on.squash_threads=percpu\n"
      )
      command = <<~BASH
        source #{Shellwords.escape(SCRIPT)}
        trap - EXIT INT TERM
        write_recovery_cmdline #{Shellwords.escape(direct)} #{Shellwords.escape(recovery)}
      BASH

      _stdout, stderr, status = Open3.capture3("bash", "-c", command)

      assert status.success?, stderr
      assert_equal(
        "root=PARTUUID=fresh ro runs_on.immutable=1 runs_on.squash_threads=percpu console=ttyS0 runs_on.recovery=1\n",
        File.read(recovery)
      )
      assert_equal 0o644, File.stat(recovery).mode & 0o777
    end
  end

  def test_finalizer_is_last_and_surrogate_only
    TEMPLATES.each do |path|
      template = File.read(path)
      finalizer = template.index("finalize-compact-root.sh")

      refute_nil finalizer, path
      assert_operator finalizer, :>, template.index("prepare-direct-uefi.sh"), path
      final_block = template[template.rindex('provisioner "shell"', finalizer)..]
      assert_includes final_block, 'only = ["amazon-ebssurrogate.compact_root"]', path
      assert_equal 1, template.scan("finalize-compact-root.sh").length, path
    end
  end
end
