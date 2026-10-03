Import-Module "$PSScriptRoot/../helpers/Common.Helpers.psm1"

Describe "RunsOnBuildKit" {
    BeforeAll {
        $line = Get-Content /etc/environment | Where-Object { $_ -like "RUNS_ON_BUILDKIT_IMAGE=*" }
        $image = $line -replace '^RUNS_ON_BUILDKIT_IMAGE="?([^"]*)"?$', '$1'
    }

    It "RUNS_ON_BUILDKIT_IMAGE pins a RunsOn BuildKit release by digest" {
        $image | Should -Match '^public\.ecr\.aws/c5h5o9k1/runs-on/buildkit:v\d+\.\d+\.\d+-runs-on\.\d+@sha256:[0-9a-f]{64}$'
    }

    It "The pinned image is present" {
        (Get-CommandResult "docker image inspect $image").ExitCode | Should -Be 0
    }

    It "buildkitd reports the pinned release" {
        $release = $image -replace '^.*:(v\d+\.\d+\.\d+)-runs-on\.\d+@.*$', '$1'
        (Get-CommandResult "docker run --rm --entrypoint buildkitd $image --version").Output | Should -Match " $([regex]::Escape($release))"
    }
}
