# frozen_string_literal: true

module AmiName
  module_function

  def image_id(name, prefix:)
    expected_prefix = "#{prefix}-"
    raise ArgumentError, "AMI name does not start with #{expected_prefix}" unless name.start_with?(expected_prefix)

    components = name.delete_prefix(expected_prefix).split("-")
    raise ArgumentError, "AMI name does not include an image ID and version" if components.length < 4

    components[0...-1].join("-")
  end
end
