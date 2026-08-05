require "minitest/autorun"
require "tmpdir"
require_relative "../lib/build_provenance"

class BuildProvenanceTest < Minitest::Test
  def test_digest_tree_is_stable_and_includes_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "nested"))
      File.write(File.join(dir, "a"), "same")
      File.write(File.join(dir, "nested", "b"), "same")

      first = BuildProvenance.digest_tree(dir)
      FileUtils.mv(File.join(dir, "nested", "b"), File.join(dir, "nested", "c"))

      refute_equal first, BuildProvenance.digest_tree(dir)
    end
  end

  def test_write_returns_the_file_digest
    Dir.mktmpdir do |dir|
      path = File.join(dir, "manifest.json")

      digest = BuildProvenance.write(path, { "image" => "ami-123" })

      assert_equal Digest::SHA256.file(path).hexdigest, digest
      assert_equal({ "image" => "ami-123" }, JSON.parse(File.read(path)))
    end
  end

  def test_resolve_source_ami_normalizes_numeric_owner_and_selects_latest
    image = Struct.new(:creation_date).new("2026-08-05T12:00:00Z")
    response = Struct.new(:images).new([image])
    client = Class.new do
      attr_reader :params

      def initialize(response)
        @response = response
      end

      def describe_images(**params)
        @params = params
        @response
      end
    end.new(response)

    resolved = BuildProvenance.resolve_source_ami(
      ec2_client: client,
      name: "Windows_Server-*",
      owner: 801119661308
    )

    assert_same image, resolved
    assert_equal ["801119661308"], client.params.fetch(:owners)
  end

  def test_tag_resources_tags_digest_and_uri
    client = Class.new do
      attr_reader :params

      def create_tags(**params)
        @params = params
      end
    end.new

    BuildProvenance.tag_resources(
      ec2_client: client,
      resource_ids: ["ami-123", "snap-123"],
      digest: "abc",
      uri: "https://example.test/build/1"
    )

    assert_equal ["ami-123", "snap-123"], client.params.fetch(:resources)
    assert_equal(
      [
        { key: "runs-on:provenance-digest", value: "abc" },
        { key: "runs-on:provenance-uri", value: "https://example.test/build/1" }
      ],
      client.params.fetch(:tags)
    )
  end
end
