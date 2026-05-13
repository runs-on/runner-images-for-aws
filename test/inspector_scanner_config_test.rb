require "minitest/autorun"
require_relative "../lib/inspector_scanner_config"

class InspectorScannerConfigTest < Minitest::Test
  def test_only_explicit_inspect_true_images_are_selected
    config = {
      "images" => [
        { "id" => "ubuntu24-full-x64", "inspect" => true, "instance_type" => "m8a.large" },
        { "id" => "ubuntu24-full-arm64", "inspect" => true, "instance_type" => "m8g.large" },
        { "id" => "ubuntu22-full-x64", "instance_type" => "m8a.large" },
        { "id" => "windows25-full-x64", "inspect" => false, "instance_type" => "m8i.xlarge" }
      ]
    }

    assert_equal(
      [
        { "image_id" => "ubuntu24-full-x64", "instance_type" => "m8a.large" },
        { "image_id" => "ubuntu24-full-arm64", "instance_type" => "m8g.large" }
      ],
      InspectorScannerConfig.opted_in_images(config)
    )
  end

  def test_latest_dev_and_prod_amis_are_selected_with_instance_type
    scanner_config = [{ "image_id" => "ubuntu24-full-x64", "instance_type" => "m8a.large" }]
    images = [
      image("ami-dev-old", "runs-on-dev-ubuntu24-full-x64-001", "2026-01-01T00:00:00.000Z"),
      image("ami-dev-new", "runs-on-dev-ubuntu24-full-x64-002", "2026-01-02T00:00:00.000Z"),
      image("ami-prod-old", "runs-on-v2.2-ubuntu24-full-x64-001", "2026-01-01T00:00:00.000Z"),
      image("ami-prod-new", "runs-on-v2.2-ubuntu24-full-x64-002", "2026-01-03T00:00:00.000Z"),
      image("ami-other", "runs-on-dev-ubuntu22-full-x64-002", "2026-01-04T00:00:00.000Z")
    ]

    selected = InspectorScannerConfig.selected_amis(images, scanner_config)

    assert_equal %w[ami-dev-new ami-prod-new], selected.map { |ami| ami.fetch("image_id") }
    assert_equal %w[dev prod], selected.map { |ami| ami.fetch("channel") }
    assert_equal ["m8a.large", "m8a.large"], selected.map { |ami| ami.fetch("instance_type") }
  end

  def test_tag_rotation_marks_latest_and_removes_stale_or_no_longer_opted_in_tags
    scanner_config = [{ "image_id" => "ubuntu24-full-x64", "instance_type" => "m8a.large" }]
    images = [
      image("ami-dev-old", "runs-on-dev-ubuntu24-full-x64-001", "2026-01-01T00:00:00.000Z", tags: { "inspector_scan" => "true" }),
      image("ami-dev-new", "runs-on-dev-ubuntu24-full-x64-002", "2026-01-02T00:00:00.000Z"),
      image("ami-prod-new", "runs-on-v2.2-ubuntu24-full-x64-002", "2026-01-03T00:00:00.000Z", tags: { "inspector_scan" => "true" }),
      image("ami-removed", "runs-on-dev-ubuntu22-full-x64-002", "2026-01-04T00:00:00.000Z", tags: { "inspector_scan" => "true" })
    ]

    plan = InspectorScannerConfig.tag_rotation_plan(images, scanner_config, tag_name: "inspector_scan", tag_value: "true")

    assert_equal ["ami-dev-new"], plan.fetch(:tag).map { |ami| ami.fetch("image_id") }
    assert_equal %w[ami-dev-old ami-removed], plan.fetch(:untag).map { |ami| ami.fetch("image_id") }
  end

  def test_repo_config_initial_opt_in
    config = InspectorScannerConfig.load_file(File.expand_path("../config.yml", __dir__))

    assert_equal(
      [
        { "image_id" => "ubuntu24-full-x64", "instance_type" => "m8a.large" },
        { "image_id" => "ubuntu24-full-arm64", "instance_type" => "m8g.large" }
      ],
      InspectorScannerConfig.opted_in_images(config)
    )
  end

  private

  def image(image_id, name, creation_date, state: "available", tags: {})
    {
      "image_id" => image_id,
      "name" => name,
      "creation_date" => creation_date,
      "state" => state,
      "tags" => tags
    }
  end
end
