Describe "otel-cli" {
    It "otel-cli" {
        "otel-cli exec -- true" | Should -ReturnZeroExitCode
    }
}
