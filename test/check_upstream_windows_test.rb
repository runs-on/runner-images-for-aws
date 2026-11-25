require "minitest/autorun"
load File.expand_path("../bin/check-upstream-windows", __dir__)

class CheckUpstreamWindowsTest < Minitest::Test
  TEMPLATES = ["build.windows-2022.pkr.hcl", "build.windows-2025-vs2026.pkr.hcl", "build.windows-2025.pkr.hcl"].freeze
  EXPECTED = { "windows-2025" => "windows-2025-vs2026", "templates" => TEMPLATES }.freeze

  def readme(windows_2025_row)
    <<~MD
      | Image | Architecture | YAML Label | Included Software |
      | --------------------|---------------------|--------------------|---------------------|
      #{windows_2025_row}
      | Windows Server 2022<br>![Endpoint Badge](https://img.shields.io/x) | x64 | `windows-2022` | [windows-2022] |
    MD
  end

  def test_drift
    current = "| Windows Server 2025<br>![Endpoint Badge](https://img.shields.io/x) | x64 | `windows-latest`, `windows-2025`, or `windows-2025-vs2026` | [windows-2025-vs2026] |"
    moved = "| Windows Server 2025<br>![Endpoint Badge](https://img.shields.io/x) | x64 | `windows-latest`, `windows-2025`, or `windows-2025-vs2027` | [windows-2025-vs2027] |"
    cases = {
      "matches upstream" => [current, TEMPLATES, []],
      "label moved to a new recipe" => [moved, TEMPLATES, [/windows-2025 label now uses windows-2025-vs2027/]],
      "label row gone" => ["", TEMPLATES, [/no recipe found/]],
      "new template upstream" => [current, TEMPLATES + ["build.windows-2025-vs2027.pkr.hcl"], [/added build.windows-2025-vs2027.pkr.hcl/]],
      "template removed upstream" => [current, TEMPLATES - ["build.windows-2025.pkr.hcl"], [/removed build.windows-2025.pkr.hcl/]]
    }
    cases.each do |name, (row, templates, expected)|
      problems = UpstreamWindows.drift(EXPECTED, readme: readme(row), templates: templates)
      assert_equal expected.length, problems.length, name
      expected.zip(problems).each { |pattern, problem| assert_match pattern, problem, name }
    end
  end
end
