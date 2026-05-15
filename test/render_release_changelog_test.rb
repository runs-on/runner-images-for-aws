require "minitest/autorun"
require "json"
require "tmpdir"
load File.expand_path("../bin/render-release-changelog", __dir__)

class ReleaseChangelogTest < Minitest::Test
  def test_renders_available_images_with_region_ami_ids_in_config_order
    Dir.mktmpdir do |dir|
      write_summary(
        File.join(dir, "windows.json"),
        image_id: "windows25-full-x64",
        regions: [
          region("eu-west-1", "ami-euw1"),
          region("us-east-1", "ami-use1")
        ]
      )
      write_summary(
        File.join(dir, "ubuntu.json"),
        image_id: "ubuntu24-full-x64",
        regions: [
          region("ap-southeast-2", "ami-apse2"),
          region("us-east-2", "ami-use2")
        ]
      )

      markdown = ReleaseChangelog.render([dir])

      assert_includes markdown, "## Available images"
      assert_includes markdown, '### `ubuntu24-full-x64`'
      assert_includes markdown, '### `windows25-full-x64`'
      assert_includes markdown, "| us-east-1 | `ami-use1` |"
      assert_includes markdown, "| eu-west-1 | `ami-euw1` |"
      assert_includes markdown, "| us-east-2 | `ami-use2` |"
      assert_includes markdown, "| ap-southeast-2 | `ami-apse2` |"
      refute_includes markdown, "compare"
      refute_includes markdown, "commit"
      refute_includes markdown, "snapshot"
      refute_includes markdown, "status"
      assert_operator markdown.index("| us-east-1 | `ami-use1` |"), :<, markdown.index("| eu-west-1 | `ami-euw1` |")
    end
  end

  private

  def write_summary(path, image_id:, regions:)
    File.write(
      path,
      JSON.pretty_generate(
        {
          image_id: image_id,
          ami_name: "runs-on-v2.2-#{image_id}-20260515000000",
          regions: regions
        }
      )
    )
  end

  def region(name, ami_id)
    {
      region: name,
      ami_id: ami_id
    }
  end
end
