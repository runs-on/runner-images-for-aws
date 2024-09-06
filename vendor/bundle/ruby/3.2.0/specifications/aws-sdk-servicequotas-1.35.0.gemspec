# -*- encoding: utf-8 -*-
# stub: aws-sdk-servicequotas 1.35.0 ruby lib

Gem::Specification.new do |s|
  s.name = "aws-sdk-servicequotas".freeze
  s.version = "1.35.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "changelog_uri" => "https://github.com/aws/aws-sdk-ruby/tree/version-3/gems/aws-sdk-servicequotas/CHANGELOG.md", "source_code_uri" => "https://github.com/aws/aws-sdk-ruby/tree/version-3/gems/aws-sdk-servicequotas" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Amazon Web Services".freeze]
  s.date = "2024-01-26"
  s.description = "Official AWS Ruby gem for Service Quotas. This gem is part of the AWS SDK for Ruby.".freeze
  s.email = ["aws-dr-rubygems@amazon.com".freeze]
  s.homepage = "https://github.com/aws/aws-sdk-ruby".freeze
  s.licenses = ["Apache-2.0".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.5".freeze)
  s.rubygems_version = "3.4.10".freeze
  s.summary = "AWS SDK for Ruby - Service Quotas".freeze

  s.installed_by_version = "3.4.10" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<aws-sdk-core>.freeze, ["~> 3", ">= 3.191.0"])
  s.add_runtime_dependency(%q<aws-sigv4>.freeze, ["~> 1.1"])
end
