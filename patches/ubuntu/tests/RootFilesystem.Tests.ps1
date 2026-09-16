Describe "Root filesystem defaults on Ubuntu 22" {
    It "Does not install the upstream filesystem tuning drop-in" {
        "/etc/default/grub.d/99-runner-performance.cfg" | Should -Not -Exist
    }

    It "Does not enable writeback mode on the kernel command line" {
        $cmdline = & cat /proc/cmdline
        $cmdline | Should -Not -Match "data=writeback"
    }

    It "Keeps the root filesystem writable with ordered data" {
        $mountOptions = (findmnt --noheadings --first-only --output OPTIONS --target /) -split ","
        $mountOptions | Should -Contain "rw"
        $mountOptions | Should -Contain "data=ordered"
    }
}
