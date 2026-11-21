require 'json'
require 'open3'

module AmiRecycleBin
  module_function

  def rules(region, type)
    output, error, status = Open3.capture3('aws', 'rbin', 'list-rules', '--region', region,
                                         '--resource-type', type, '--output', 'json')
    raise "Cannot read Recycle Bin rules in #{region}: #{error}" unless status.success?

    JSON.parse(output).fetch('Rules').map do |summary|
      output, error, status = Open3.capture3('aws', 'rbin', 'get-rule', '--region', region,
                                           '--identifier', summary.fetch('Identifier'), '--output', 'json')
      raise "Cannot read Recycle Bin rule: #{error}" unless status.success?

      JSON.parse(output)
    end
  end

  def protected?(rules, tags)
    tags = tags.to_h { |tag| [tag.key, tag.value] }
    rules.any? do |rule|
      period = rule.fetch('RetentionPeriod')
      included = rule.fetch('ResourceTags', [])
      excluded = rule.fetch('ExcludeResourceTags', [])
      period['RetentionPeriodUnit'] == 'DAYS' && period['RetentionPeriodValue'] == 7 &&
        rule['Status'] == 'available' &&
        (included.empty? || included.any? { |tag| tags[tag['ResourceTagKey']] == tag['ResourceTagValue'] }) &&
        excluded.none? { |tag| tags[tag['ResourceTagKey']] == tag['ResourceTagValue'] }
    end
  end
end
