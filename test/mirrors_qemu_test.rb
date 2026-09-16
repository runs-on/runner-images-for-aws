require "minitest/autorun"
require "open3"
require "tmpdir"

class MirrorsQemuTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_rewrite_covers_ec2_and_security_sources
    pre = File.read("#{ROOT}/patches/ubuntu/files/pre.sh")
    configuration = pre[pre.index('arch=$(dpkg')...pre.index('for src in')]
    cases = {
      "amd64" => ["http://us-east-1.ec2.archive.ubuntu.com/ubuntu/", "https://archive.ubuntu.com/ubuntu/"],
      "arm64" => ["http://us-east-1.ec2.ports.ubuntu.com/ubuntu-ports/", "https://ports.ubuntu.com/ubuntu-ports/"]
    }
    cases.each do |arch, (source, expected)|
      ["deb #{source} jammy main\n", "URIs: #{source}\n"].each do |content|
        Dir.mktmpdir do |dir|
          file = "#{dir}/sources"
          File.write(file, content + "deb http://security.ubuntu.com/ubuntu jammy-security main\n" +
            (arch == "arm64" ? "URIs: http://ports.ubuntu.com/ubuntu-ports\n" : ""))
          output, status = Open3.capture2e("bash", "-e", "-c", <<~SH)
            dpkg() { echo #{arch}; }
            if command -v gsed >/dev/null; then sed() { gsed "$@"; }; fi
            #{configuration}
            rewrite_apt_source '#{file}'
          SH
          assert status.success?, output
          result = File.read(file)
          assert_includes result, expected
          refute_match(/http:|\.ec2\./, result)
        end
      end
    end
    assert_operator pre.index('cloud-init status --wait'), :<, pre.index('arch=$(dpkg')
  end

  def test_qemu_uses_an_explicit_provider_for_each_architecture
    %w[runner-user.sh runner-finalize-nested-virt.sh].each do |name|
      script = File.read("#{ROOT}/patches/ubuntu/files/#{name}")
      selection = script[/case "\$\(uname -m\)" in.*?esac/m]
      refute_nil selection
      {"x86_64" => "qemu-system-x86", "aarch64" => "qemu-system-arm"}.each do |arch, package|
        output, status = Open3.capture2e("bash", "-e", "-c", "uname() { echo #{arch}; };\n#{selection}\necho \"$qemu_package\"")
        assert status.success?, output
        assert_equal package, output.strip
      end
      _, status = Open3.capture2e("bash", "-e", "-c", "uname() { echo unsupported; };\n#{selection}")
      refute status.success?
      assert_includes script, '"$qemu_package"'
      refute_match(/apt-get install[^\n]*qemu-kvm|^  qemu-kvm /, script)
    end
  end
end
