These scripts come from actions/runner-images at
`bac22751eb7d886e12c6063685275299469e9e5b`, the upstream revision used by
[the failed build](https://github.com/runs-on/runner-images-for-aws/actions/runs/34957769714/job/104344049133).

Only trailing whitespace is normalized. Keep the fixtures otherwise unchanged so the tests exercise our AWS patch against the
upstream scripts that caused the failure. System commands are stubbed, and APT
configuration is redirected into a temporary directory.
