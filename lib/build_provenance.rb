require "digest"
require "fileutils"
require "json"
require "pathname"

module BuildProvenance
  TAG_DIGEST = "runs-on:provenance-digest"
  TAG_URI = "runs-on:provenance-uri"

  module_function

  def digest_tree(root)
    root = Pathname.new(root)
    digest = Digest::SHA256.new

    root.glob("**/*", File::FNM_DOTMATCH).select(&:file?).sort.each do |path|
      relative_path = path.relative_path_from(root).to_s
      digest.update(relative_path)
      digest.update("\0")
      digest.update(path.binread)
      digest.update("\0")
    end

    digest.hexdigest
  end

  def write(path, manifest)
    contents = JSON.pretty_generate(manifest) + "\n"
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    Digest::SHA256.hexdigest(contents)
  end

  def resolve_source_ami(ec2_client:, name:, owner:)
    images = ec2_client.describe_images(
      owners: [owner.to_s],
      filters: [
        { name: "name", values: [name] },
        { name: "state", values: ["available"] }
      ]
    ).images
    fail("No available source AMI found for #{owner}/#{name}") if images.empty?

    images.max_by(&:creation_date)
  end

  def tag_resources(ec2_client:, resource_ids:, digest:, uri: nil)
    tags = [{ key: TAG_DIGEST, value: digest }]
    tags << { key: TAG_URI, value: uri } unless uri.nil? || uri.empty?
    ec2_client.create_tags(resources: resource_ids, tags: tags)
  end
end
