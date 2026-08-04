require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"

class DirectUefiTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/files/prepare-direct-uefi.sh", __dir__)
  README = File.expand_path("../README.md", __dir__)
  TEST_WORKFLOW = File.expand_path("../.github/workflows/test.yml", __dir__)
  TEMPLATE_DIR = File.expand_path("../patches/ubuntu/templates", __dir__)
  FULL_X64_TEMPLATE = File.join(TEMPLATE_DIR, "ubuntu-full-x64.pkr.hcl")
  DESCENDANT_TEMPLATES = %w[
    ubuntu-gpu-x64.pkr.hcl
    ubuntu-stepsecurity-x64.pkr.hcl
  ].map { |name| File.join(TEMPLATE_DIR, name) }.freeze
  ARM64_TEMPLATES = %w[
    ubuntu-full-arm64.pkr.hcl
    ubuntu-stepsecurity-arm64.pkr.hcl
  ].map { |name| File.join(TEMPLATE_DIR, name) }.freeze

  def run_function(command, env = {})
    Open3.capture3(
      env,
      "bash",
      "-c",
      "source #{Shellwords.escape(SCRIPT)}; #{command}"
    )
  end

  def test_shell_syntax
    _stdout, stderr, status = Open3.capture3("bash", "-n", SCRIPT)

    assert status.success?, stderr
  end

  def test_non_ubuntu26_images_exit_before_uefi_checks
    stdout, stderr, status = Open3.capture3({ "IMAGE_OS" => "ubuntu24" }, "bash", SCRIPT)

    assert status.success?, stderr
    assert_includes stdout, "keeping GRUB boot for ubuntu24"
  end

  def test_full_x64_prepares_direct_boot_after_rolaunch
    template = File.read(FULL_X64_TEMPLATE)

    assert_includes template, "IMAGE_OS=${var.image_os}"
    assert_equal 2, template.scan("prepare-direct-uefi.sh").length
    assert_operator template.index("prepare-direct-uefi.sh"), :>, template.index("configure-full-rolaunch.sh")
  end

  def test_direct_kernel_builds_compact_root_dependencies_in
    script = File.read(SCRIPT)

    %w[
      CONFIG_BLK_DEV_LOOP
      CONFIG_SQUASHFS
      CONFIG_SQUASHFS_ZSTD
      CONFIG_SQUASHFS_CHOICE_DECOMP_BY_MOUNT
    ].each do |option|
      assert_includes script, option
    end
  end

  def test_descendants_rearm_after_package_reboot_and_launch_state_cleanup
    DESCENDANT_TEMPLATES.each do |path|
      template = File.read(path)

      assert_includes template, "IMAGE_OS=${var.image_os}", path
      assert_equal 2, template.scan("prepare-direct-uefi.sh").length, path
      assert_operator template.index("prepare-direct-uefi.sh"), :>, template.index("finalize-rolaunch-descendant.sh"), path
      assert_operator template.index("prepare-direct-uefi.sh"), :>, template.index("sudo reboot"), path
    end
  end

  def test_arm64_templates_keep_grub
    ARM64_TEMPLATES.each do |path|
      refute_includes File.read(path), "prepare-direct-uefi.sh", path
    end
  end

  def test_arm64_script_guard_exits_before_uefi_checks
    Dir.mktmpdir("direct-uefi-arm-guard") do |dir|
      dpkg = File.join(dir, "dpkg")
      File.write(dpkg, <<~SH)
        #!/usr/bin/env bash
        printf '%s\n' arm64
      SH
      File.chmod(0o755, dpkg)
      stdout, stderr, status = Open3.capture3(
        { "IMAGE_OS" => "ubuntu26", "PATH" => "#{dir}:#{ENV.fetch("PATH")}" },
        "bash",
        SCRIPT
      )

      assert status.success?, stderr
      assert_includes stdout, "keeping GRUB boot for ubuntu26 arm64"
    end
  end

  def test_arm_patch_preserves_the_x64_guard
    patch_lib = File.read(File.expand_path("../bin/patch/lib.sh", __dir__))

    assert_match(/finalize-compact-root\.sh\|prepare-direct-uefi\.sh/, patch_lib)
    assert_includes File.read(SCRIPT), '"${debian_arch}" == "amd64"'
  end

  def test_pe_validator_rejects_the_wrong_architecture
    Dir.mktmpdir("direct-uefi-pe") do |dir|
      fake_bin = File.join(dir, "bin")
      Dir.mkdir(fake_bin)
      stat = File.join(fake_bin, "stat")
      File.write(stat, <<~SH)
        #!/usr/bin/env bash
        set -euo pipefail
        wc -c < "${3}"
      SH
      File.chmod(0o755, stat)

      amd64_image = File.join(dir, "amd64.efi")
      arm64_image = File.join(dir, "arm64.efi")
      write_test_pe(amd64_image, 0x8664)
      write_test_pe(arm64_image, 0xaa64)
      env = { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}" }

      _stdout, stderr, status = run_function("validate_pe_image #{Shellwords.escape(amd64_image)}", env)
      assert status.success?, stderr

      _stdout, stderr, status = run_function("validate_pe_image #{Shellwords.escape(arm64_image)}", env)
      refute status.success?
      assert_includes stderr, "kernel PE architecture is not AMD64"
    end
  end

  def test_latest_installed_aws_kernel_wins
    Dir.mktmpdir("direct-uefi-kernels") do |dir|
      boot_dir = File.join(dir, "boot")
      fake_bin = File.join(dir, "bin")
      Dir.mkdir(boot_dir)
      Dir.mkdir(fake_bin)
      %w[6.11.0-1020-aws 7.0.0-1009-aws 7.0.0-1010-aws].each do |release|
        File.write(File.join(boot_dir, "vmlinuz-#{release}"), "kernel")
      end
      dpkg_query = File.join(fake_bin, "dpkg-query")
      File.write(dpkg_query, <<~SH)
        #!/usr/bin/env bash
        set -euo pipefail
        package="${!#}"
        case "${package}" in
          linux-image-6.11.0-1020-aws|linux-image-7.0.0-1009-aws) printf installed ;;
          *) exit 1 ;;
        esac
      SH
      File.chmod(0o755, dpkg_query)

      stdout, stderr, status = run_function(
        "select_latest_aws_kernel #{Shellwords.escape(boot_dir)}",
        { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}" }
      )

      assert status.success?, stderr
      assert_equal "7.0.0-1009-aws\n", stdout
    end
  end

  def test_direct_cmdline_requires_portable_root_and_panic_reboot
    valid = "root=PARTUUID=abc ro panic=-1 console=null quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false"
    _stdout, stderr, status = run_function("validate_direct_cmdline #{Shellwords.escape(valid)}")
    assert status.success?, stderr

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=LABEL=cloudimg-rootfs panic=-1'")
    refute status.success?
    assert_includes stderr, "root=PARTUUID="

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc ro'")
    refute status.success?
    assert_includes stderr, "reboot immediately after a panic"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 initrd=initrd.img'")
    refute status.success?
    assert_includes stderr, "still refers to an initrd"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=ttyS0'")
    refute status.success?
    assert_includes stderr, "contains an active console"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=null console=null'")
    refute status.success?
    assert_includes stderr, "exactly one console=null"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=null earlycon=uart8250'")
    refute status.success?
    assert_includes stderr, "still enables an early console"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=null quiet loglevel=7 systemd.show_status=false rd.systemd.show_status=false'")
    refute status.success?
    assert_includes stderr, "wrong log level"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=null quiet loglevel=3 systemd.show_status=true rd.systemd.show_status=false'")
    refute status.success?
    assert_includes stderr, "still shows systemd status"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=null quiet quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false'")
    refute status.success?
    assert_includes stderr, "exactly one quiet"

    _stdout, stderr, status = run_function("validate_direct_cmdline 'root=PARTUUID=abc panic=-1 console=null quiet loglevel=3 systemd.show_status=false'")
    refute status.success?
    assert_includes stderr, "exactly one rd.systemd.show_status=false"
  end

  def test_direct_cmdline_removes_bootloader_initrd_and_console_arguments
    command = "compose_direct_cmdline root=PARTUUID=abc ro console=tty1 console=ttyS0 earlycon=uart8250 panic=-1 quiet loglevel=7 systemd.show_status=true rd.systemd.show_status=true BOOT_IMAGE=/vmlinuz initrd=initrd.img initrdfail"
    stdout, stderr, status = run_function(command)

    assert status.success?, stderr
    assert_equal "root=PARTUUID=abc ro panic=-1 console=null quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false\n", stdout
  end

  def test_compact_cmdline_replaces_root_and_deduplicates_immutable_arguments
    command = "compose_direct_cmdline root=PARTUUID=old rw panic=-1 init=/runs-on-root/init runs_on.immutable=1 runs_on.squash_threads=single console=ttyS0"
    env = {
      "DIRECT_UEFI_ROOT_PARTUUID" => "fresh-root",
      "DIRECT_UEFI_EXTRA_ARGUMENTS" => "init=/runs-on-root/init runs_on.immutable=1 runs_on.squash_threads=percpu"
    }

    stdout, stderr, status = run_function(command, env)

    assert status.success?, stderr
    assert_equal 1, stdout.scan("root=PARTUUID=").length
    assert_includes stdout, "root=PARTUUID=fresh-root"
    assert_equal 1, stdout.scan("init=/runs-on-root/init").length
    assert_includes stdout, "runs_on.squash_threads=percpu"
    refute_includes stdout, "runs_on.squash_threads=single"
  end

  def test_exact_label_parser_handles_verbose_output
    output = <<~EFI
      BootCurrent: 0004
      BootOrder: 0003,0004,0002
      Boot0002* Ubuntu\tHD(15,GPT,...)/File(\\EFI\\ubuntu\\shimaa64.efi)
      Boot0003* RunsOn GRUB fallback\tHD(15,GPT,...)/File(\\EFI\\ubuntu\\shimaa64.efi)
      Boot0004* RunsOn direct Linux\tHD(15,GPT,...)/File(\\EFI\\runs-on\\vmlinuz.efi)root=PARTUUID=x
      Boot0005* RunsOn direct Linux stale\tHD(15,GPT,...)
    EFI

    stdout, stderr, status = run_function(
      "bootnums_for_label_from_output 'RunsOn direct Linux' <<< \"${EFI_OUTPUT}\"",
      { "EFI_OUTPUT" => output }
    )

    assert status.success?, stderr
    assert_equal "0004\n", stdout
  end

  def test_boot_order_is_fallback_first_direct_last_and_idempotent
    command = "compose_boot_order 0003 0004 '0004,0002,0003,0000,0002'"
    stdout, stderr, status = run_function(command)
    assert status.success?, stderr
    assert_equal "0003,0002,0000,0004\n", stdout

    repeated, stderr, status = run_function("compose_boot_order 0003 0004 '#{stdout.strip}'")
    assert status.success?, stderr
    assert_equal stdout, repeated
  end

  def test_cleanup_removes_every_temporary_file
    Dir.mktmpdir("direct-uefi-cleanup") do |dir|
      paths = %w[before after].map { |name| File.join(dir, name) }
      paths.each { |path| File.write(path, "temporary") }
      assignments = %w[fallback_hashes_before fallback_hashes_after]
        .zip(paths)
        .map { |name, path| "#{name}=#{Shellwords.escape(path)}" }
        .join("; ")

      _stdout, stderr, status = run_function("#{assignments}; cleanup")

      assert status.success?, stderr
      paths.each { |path| refute_path_exists path }
    end
  end

  def test_exit_trap_cleans_temporary_files_without_hiding_failure
    Dir.mktmpdir("direct-uefi-failed-cleanup") do |dir|
      paths = %w[before after].map { |name| File.join(dir, name) }
      paths.each { |path| File.write(path, "temporary") }
      assignments = %w[fallback_hashes_before fallback_hashes_after]
        .zip(paths)
        .map { |name, path| "#{name}=#{Shellwords.escape(path)}" }
        .join("; ")

      _stdout, _stderr, status = run_function("#{assignments}; false")

      refute status.success?
      paths.each { |path| refute_path_exists path }
    end
  end

  def test_published_image_workflow_validates_direct_boot_state
    workflow = File.read(TEST_WORKFLOW)

    assert_includes workflow, "/var/lib/runs-on-direct-uefi"
    assert_includes workflow, "BootCurrent:"
    assert_includes workflow, "BootNext:"
    refute_includes workflow, 'test "$boot_order" = "$expected_order"'
    assert_includes workflow, 'test "$direct_bootnum" = "$expected_current"'
    assert_includes workflow, 'test "${boot_order%%,*}" = "$actual_fallback_bootnum"'
    assert_includes workflow, 'test "$direct_bootnum" != "${boot_order%%,*}"'
    assert_includes workflow, "expected-cmdline"
    assert_includes workflow, "root=PARTUUID="
    assert_includes workflow, "panic=-1"
    assert_includes workflow, %q([[ " $(< /proc/cmdline) " == *' console=null '* ]])
    assert_includes workflow, %q(! grep -Eq '(^| )earlycon(=| |$)' /proc/cmdline)
    assert_includes workflow, %q(test "$(tr ' ' '\n' < /proc/cmdline | grep -c '^quiet$')" = 1)
    assert_includes workflow, %q([[ " $(< /proc/cmdline) " == *' loglevel=3 '* ]])
    assert_includes workflow, %q([[ " $(< /proc/cmdline) " == *' systemd.show_status=false '* ]])
    assert_includes workflow, %q([[ " $(< /proc/cmdline) " == *' rd.systemd.show_status=false '* ]])
    assert_includes workflow, "direct-kernel.sha256"
    assert_includes workflow, "kernel-source-format"
    assert_includes workflow, 'test "$kernel_format" = raw'
    assert_includes workflow, 'test "$(uname -r)" = "$kernel_release"'
    assert_includes workflow, "fallback.sha256"
  end

  def test_readme_documents_the_x64_only_recovery_contract
    readme = File.read(README)

    assert_includes readme, "Fresh Ubuntu 26 x64 UEFI launches use a one-shot direct kernel boot"
    assert_includes readme, "Ubuntu 26 arm64 stays on GRUB"
    assert_includes readme, "Secure Boot is outside this fast-path contract"
  end

  def test_preparation_keeps_the_recovery_and_idempotency_contracts
    script = File.read(SCRIPT)

    assert_includes script, "CONFIG_EFI_STUB=y"
    %w[CONFIG_BLK_DEV_NVME CONFIG_NVME_CORE CONFIG_EXT4_FS].each do |option|
      assert_includes script, option
    end
    refute_includes script, "uname -r"
    refute_includes script, "gzip -cd"
    assert_includes script, "linux-image-${kernel_release}"
    assert_operator script.index('delete_boot_entries_for_label "${label_direct}"'), :<, script.index("efibootmgr --create")
    assert_includes script, "-name 'vmlinuz*.efi*' -delete"
    assert_includes script, 'direct_filename="vmlinuz.efi"'
    assert_includes script, "mounted target ESP does not belong"
    assert_includes script, "target ESP PARTUUID"
    assert_operator script.index("efibootmgr --bootnext"), :>, script.index("efibootmgr --bootorder")
    assert_includes script, '"${prepared_order%%,*}" == "${fallback_bootnum}"'
    assert_includes script, '"${prepared_order##*,}" == "${direct_bootnum}"'
    assert_includes script, 'cmp -s "${fallback_hashes_before}" "${fallback_hashes_after}"'
    assert_includes script, "BOOT_IMAGE=*|initrd=*|initrdfail|initrdless_boot_fallback_triggered|console=*|earlycon|earlycon=*|quiet|loglevel=*|systemd.show_status=*|rd.systemd.show_status=*"
    assert_includes script, "validate_direct_cmdline"
    assert_includes script, "read -ra kernel_arguments < /proc/cmdline"
    assert_includes script, 'compose_direct_cmdline "${kernel_arguments[@]}"'
    refute_includes script, 'for argument in $(< /proc/cmdline)'
  end

  private

  def write_test_pe(path, machine)
    image = "\0" * 256
    pe_offset = 128
    image[0, 2] = "MZ"
    image[60, 4] = [pe_offset].pack("V")
    image[pe_offset, 4] = "PE\0\0"
    image[pe_offset + 4, 2] = [machine].pack("v")
    image[pe_offset + 24, 2] = [0x20b].pack("v")
    image[pe_offset + 92, 2] = [10].pack("v")
    File.binwrite(path, image)
  end
end
