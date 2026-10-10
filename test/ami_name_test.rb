require "minitest/autorun"
require_relative "../lib/ami_name"

class AmiNameTest < Minitest::Test
  def test_extracts_multi_segment_image_ids
    assert_equal(
      "ubuntu24-gpu-stepsecurity-x64",
      AmiName.image_id(
        "runs-on-dev-ubuntu24-gpu-stepsecurity-x64-20260825120000",
        prefix: "runs-on-dev"
      )
    )
    assert_equal(
      "ubuntu24-gpu-stepsecurity-arm64",
      AmiName.image_id(
        "runs-on-v2.2-ubuntu24-gpu-stepsecurity-arm64-20260825120000",
        prefix: "runs-on-v2.2"
      )
    )
  end

  def test_rejects_unexpected_names
    assert_raises(ArgumentError) { AmiName.image_id("other-image", prefix: "runs-on-dev") }
    assert_raises(ArgumentError) { AmiName.image_id("runs-on-dev-ubuntu24-x64", prefix: "runs-on-dev") }
  end
end
