Describe "Java" {
    $toolsetJava = (Get-ToolsetContent).java
    $defaultVersion = $toolsetJava.default
    $jdkVersions = $toolsetJava.versions

    [array] $testCases = $jdkVersions | ForEach-Object { @{Version = $_ } }

    It "Java <DefaultJavaVersion> is default" -TestCases @(@{ DefaultJavaVersion = $defaultVersion }) {
        $actualJavaPath = Get-EnvironmentVariable "JAVA_HOME"
        $expectedJavaPath = Get-EnvironmentVariable "JAVA_HOME_${DefaultJavaVersion}_X64"

        $actualJavaPath | Should -Not -BeNullOrEmpty
        $expectedJavaPath | Should -Not -BeNullOrEmpty
        $actualJavaPath | Should -Be $expectedJavaPath
    }

    It "<ToolName>" -TestCases @(
        @{ ToolName = "java" }
        @{ ToolName = "mvn" }
        @{ ToolName = "ant" }
        @{ ToolName = "gradle" }
    ) {
        "$ToolName -version" | Should -ReturnZeroExitCode
    }

    It "Java <Version>" -TestCases $testCases {
        $javaVariableValue = Get-EnvironmentVariable "JAVA_HOME_${Version}_X64"
        $javaVariableValue | Should -Not -BeNullOrEmpty
        $javaPath = Join-Path $javaVariableValue "bin\java"

        if ($Version -eq 8) {
            $Version = "1.${Version}"
        }
        $outputPattern = "openjdk version `"${Version}"

        $outputLines = (& $env:comspec /c "`"$javaPath`" -version 2>&1") -as [string[]]
        $LASTEXITCODE | Should -Be 0
        $outputLines | Where-Object { $_ -match "openjdk version" } | Select-Object -First 1 | Should -Match $outputPattern
    }
}
