# frozen_string_literal: true

require "json"
require "yaml"

module InspectorScannerConfig
  module_function

  DEV_PREFIX = "runs-on-dev"
  PROD_PREFIX = "runs-on-v2.2"

  def load_file(path)
    YAML.load_file(path)
  end

  def opted_in_images(config)
    config.fetch("images").filter_map do |image|
      next unless image.fetch("inspect", false) == true

      {
        "image_id" => image.fetch("id"),
        "instance_type" => image.fetch("instance_type")
      }
    end
  end

  def json_for_file(path)
    JSON.generate(opted_in_images(load_file(path)))
  end

  def selected_amis(images, scanner_config, dev_prefix: DEV_PREFIX, prod_prefix: PROD_PREFIX)
    scanner_config.flat_map do |image|
      [
        latest_ami(images, "dev", dev_prefix, image),
        latest_ami(images, "prod", prod_prefix, image)
      ]
    end.compact
  end

  def tag_rotation_plan(images, scanner_config, tag_name:, tag_value:, dev_prefix: DEV_PREFIX, prod_prefix: PROD_PREFIX)
    selected = selected_amis(images, scanner_config, dev_prefix: dev_prefix, prod_prefix: prod_prefix)
    selected_ids = selected.map { |image| image.fetch("image_id") }.to_h { |id| [id, true] }

    {
      tag: selected.reject { |image| tag_value?(image, tag_name, tag_value) },
      untag: images.select { |image| tag_value?(image, tag_name, tag_value) && !selected_ids[image.fetch("image_id")] }
    }
  end

  def latest_ami(images, channel, prefix, image)
    ami_prefix = "#{prefix}-#{image.fetch("image_id")}-"
    latest = images
      .select { |candidate| candidate.fetch("state", "available") == "available" }
      .select { |candidate| candidate.fetch("name").start_with?(ami_prefix) }
      .max_by { |candidate| candidate.fetch("creation_date") }

    return if latest.nil?

    latest.merge(
      "channel" => channel,
      "configured_image_id" => image.fetch("image_id"),
      "instance_type" => image.fetch("instance_type")
    )
  end

  def tag_value?(image, tag_name, tag_value)
    image.fetch("tags", {}).fetch(tag_name, nil) == tag_value
  end
end
