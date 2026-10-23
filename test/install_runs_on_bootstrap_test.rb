require "minitest/autorun"
require "tmpdir"
require "open3"

class InstallRunsOnBootstrapTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/files/install-runs-on-bootstrap.sh", __dir__)
  RELEASES = "https://github.com/runs-on/bootstrap/releases/download".freeze

  # Stand-ins for the commands that would reach GitHub or depend on the build
  # host. curl writes a small executable so the script's `-h` check runs.
  STUBS = {
    "uname" => <<~'SH',
      #!/bin/sh
      echo "$FAKE_ARCH"
    SH
    "curl" => <<~'SH',
      #!/bin/sh
      url=""; out=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o) out="$2"; shift ;;
          https://*) url="$1" ;;
        esac
        shift
      done
      echo "download $url" >>"$LOG"
      printf '#!/bin/sh\nexit 0\n' >"$out"
    SH
    "sha256sum" => <<~'SH',
      #!/bin/sh
      read -r sum _file
      echo "verify $sum" >>"$LOG"
      exit "${SHA_EXIT:-0}"
    SH
  }.freeze

  def run_script(arch:, stub_sha256sum: true, sha_exit: 0)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "stubs")
      root = File.join(dir, "root")
      Dir.mkdir(bin)
      STUBS.each do |name, body|
        next if name == "sha256sum" && !stub_sha256sum
        File.write(File.join(bin, name), body)
        File.chmod(0o755, File.join(bin, name))
      end
      env = {
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "FAKE_ARCH" => arch,
        "LOG" => File.join(dir, "log"),
        "SHA_EXIT" => sha_exit.to_s,
      }
      output, status = Open3.capture2e(env, "bash", SCRIPT, root)
      log = File.exist?(env["LOG"]) ? File.read(env["LOG"]) : ""
      installed = Dir.glob(File.join(root, "usr/local/bin/*")).map { |path| File.basename(path) }.sort
      executable = installed.all? { |name| File.executable?(File.join(root, "usr/local/bin", name)) }
      yield status, output, log, installed, executable
    end
  end

  def test_installs_every_pinned_version_into_the_target_root
    run_script(arch: "x86_64") do |status, output, log, installed, executable|
      assert status.success?, output
      assert_equal %w[runs-on-bootstrap-v0.1.12 runs-on-bootstrap-v0.1.17 runs-on-bootstrap-v0.1.9], installed
      assert executable
      assert_equal <<~LOG, log
        download #{RELEASES}/v0.1.17/bootstrap-v0.1.17-linux-x86_64
        verify 1cb31b7988da2d705256f17b1c3da2956423fac53a2c4a6c36a4f4a4e0b82d86
        download #{RELEASES}/v0.1.12/bootstrap-v0.1.12-linux-x86_64
        verify a387bf964c573daabaf753d42213bfec5931b9a71d01325442253e6caa3dd115
        download #{RELEASES}/v0.1.9/bootstrap-v0.1.9-linux-x86_64
        verify 64fcfe5b327b2a75a13846467df2692354618718377ae1465ff847f10651d23b
      LOG
    end
  end

  def test_arm_images_get_the_aarch64_assets_and_hashes
    run_script(arch: "aarch64") do |status, output, log, _installed, _executable|
      assert status.success?, output
      assert_includes log, "download #{RELEASES}/v0.1.17/bootstrap-v0.1.17-linux-aarch64"
      assert_includes log, "verify 5bebba9f776bb35a6397d7e8bd95991cd7d4f93bd867d6b66c0af8286b7f6ee7"
    end
  end

  def test_a_download_that_does_not_match_its_hash_stops_the_build
    run_script(arch: "x86_64", stub_sha256sum: false) do |status, output, _log, installed, _executable|
      refute status.success?
      assert_includes output, "does not match its pinned SHA-256"
      assert_empty installed
    end
  end

  def test_an_architecture_without_pins_stops_the_build_before_any_download
    run_script(arch: "riscv64") do |status, output, log, installed, _executable|
      refute status.success?
      assert_includes output, "No pinned SHA-256 for RunsOn bootstrap v0.1.17 on riscv64"
      assert_empty log
      assert_empty installed
    end
  end
end
