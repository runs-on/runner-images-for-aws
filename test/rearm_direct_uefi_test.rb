require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class RearmDirectUefiTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/files/rearm-direct-uefi.sh", __dir__)

  def setup
    @tmpdir = Dir.mktmpdir("rearm-direct-uefi")
    @bin_dir = File.join(@tmpdir, "bin")
    @state_dir = File.join(@tmpdir, "state")
    @boot_path = File.join(@tmpdir, "boot-path")
    @boot_next = File.join(@tmpdir, "boot-next")
    FileUtils.mkdir_p([@bin_dir, @state_dir])
    File.write(File.join(@state_dir, "expected-boot-current"), "0004\n")
    File.write(@boot_path, "direct-uefi\n")
    write_command("dpkg", <<~'SH')
      #!/bin/sh
      test "$1" = --print-architecture
      echo amd64
    SH
    write_command("efibootmgr", <<~'SH')
      #!/bin/sh
      set -eu
      if test "${1:-}" = --bootnext; then
        printf '%s\n' "$2" > "$TEST_BOOT_NEXT"
        exit 0
      fi
      test ! -s "$TEST_BOOT_NEXT" || printf 'BootNext: %s\n' "$(cat "$TEST_BOOT_NEXT")"
      echo 'Boot0003* RunsOn GRUB fallback'
      echo 'Boot0004* RunsOn direct Linux'
    SH
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_rearms_the_recorded_direct_entry
    _stdout, stderr, status = Open3.capture3(environment, SCRIPT)

    assert status.success?, stderr
    assert_equal "0004\n", File.read(@boot_next)
  end

  def test_refuses_to_rearm_from_the_recovery_upper
    File.write(@boot_path, "grub-initramfs-recovery\n")

    _stdout, stderr, status = Open3.capture3(environment, SCRIPT)

    refute status.success?
    assert_includes stderr, "outside the direct overlay upper"
    refute File.exist?(@boot_next)
  end

  private

  def environment
    {
      "DIRECT_UEFI_BOOT_PATH_FILE" => @boot_path,
      "DIRECT_UEFI_STATE_DIR" => @state_dir,
      "IMAGE_OS" => "ubuntu26",
      "PATH" => "#{@bin_dir}:#{ENV.fetch("PATH")}",
      "TEST_BOOT_NEXT" => @boot_next
    }
  end

  def write_command(name, body)
    path = File.join(@bin_dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end
end
