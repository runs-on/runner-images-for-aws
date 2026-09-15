Import-Module "$PSScriptRoot/../helpers/Common.Helpers.psm1"

Describe "Apt" {
    $packages = (Get-ToolsetContent).apt.cmd_packages + (Get-ToolsetContent).apt.vital_packages
    $testCases = $packages | ForEach-Object { @{ toolName = $_ } }

    It "<toolName> is available" -TestCases $testCases {
        switch ($toolName) {
            "acl"               { $toolName = "getfacl"; break }
            "aria2"             { $toolName = "aria2c"; break }
            "libnss3-tools"     { $toolName = "certutil"; break }
            "p7zip-full"        { $toolName = "p7zip"; break }
            "7zip"              { $toolName = "7z"; break }
            "subversion"        { $toolName = "svn"; break }
            "sphinxsearch"      { $toolName = "searchd"; break }
            "binutils"          { $toolName = "strings"; break }
            "coreutils"         { $toolName = "tr"; break }
            "net-tools"         { $toolName = "netstat"; break }
            "mercurial"         { $toolName = "hg"; break }
            "findutils"         { $toolName = "find"; break }
            "systemd-coredump"  { $toolName = "coredumpctl"; break }
        }

        (Get-Command -Name $toolName).CommandType | Should -BeExactly "Application"
    }
}

Describe "Apt acquire configuration" {
    $settingsTestCases = @(
        @{ setting = "Acquire::Retries"; expectedValue = "5" }
        @{ setting = "Acquire::http::Timeout"; expectedValue = "20" }
        @{ setting = "Acquire::https::Timeout"; expectedValue = "20" }
    )

    It "<setting> is set to <expectedValue>" -TestCases $settingsTestCases {
        (Get-CommandResult "apt-config dump $setting").Output | Should -BeExactly "$setting `"$expectedValue`";"
    }

    It "APT::Acquire::Retries is not set" {
        (Get-CommandResult "apt-config dump APT::Acquire::Retries").Output | Should -BeNullOrEmpty
    }

    It "Apt sources use the official Ubuntu archive directly" {
        $sourcesFile = if (Test-IsUbuntu22) { "/etc/apt/sources.list" } else { "/etc/apt/sources.list.d/ubuntu.sources" }
        $aptSources = Get-Content $sourcesFile -Raw
        $architecture = (Get-CommandResult "dpkg --print-architecture").Output.Trim()
        $expectedArchive = if ($architecture -eq "arm64") { "https://ports.ubuntu.com/ubuntu-ports/" } else { "https://archive.ubuntu.com/ubuntu/" }
        $aptSources | Should -Match ([regex]::Escape($expectedArchive))
        $aptSources | Should -Not -Match "mirror\+file:"
        $aptSources | Should -Not -Match "\.ec2\.archive\.ubuntu\.com"
    }
}
