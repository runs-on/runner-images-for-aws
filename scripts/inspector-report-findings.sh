#!/usr/bin/env bash
set -euo pipefail

S3_URI="${1:-}"

usage() {
  cat <<'EOF'
Usage: inspector-report-findings.sh S3_URI

S3_URI may point to the Inspector JSON report object or to the report prefix
that contains exactly one JSON report file.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

resolve_report_uri() {
  local uri="${1%/}"
  local json_files

  if [[ "$uri" == s3://*.json ]]; then
    echo "$uri"
    return
  fi

  json_files="$(aws s3 ls "$uri/" | awk '$4 ~ /\.json$/ { print $4 }')"
  [ -n "$json_files" ] || fail "No JSON report found under $uri/"

  local count
  count="$(printf '%s\n' "$json_files" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || fail "Expected one JSON report under $uri/, found $count"

  printf '%s/%s\n' "$uri" "$json_files"
}

format_table() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    sed $'s/\t/  /g'
  fi
}

if [ "$S3_URI" = "-h" ] || [ "$S3_URI" = "--help" ]; then
  usage
  exit 0
fi

[ -n "$S3_URI" ] || {
  usage >&2
  exit 1
}

require_cmd aws
require_cmd jq

REPORT_URI="$(resolve_report_uri "$S3_URI")"
REPORT_FILE="$(mktemp)"
trap 'rm -f "$REPORT_FILE"' EXIT

aws s3 cp "$REPORT_URI" "$REPORT_FILE" >/dev/null

AMI_NAME="$(jq -r '[.findings[]?.resources[]?.tags.InspectorScannerAmiName? // empty] | unique | first // "unknown"' "$REPORT_FILE")"
AMI_ID="$(jq -r '[.findings[]?.resources[]? | .tags.InspectorScannerAmiId? // .details.awsEc2Instance.imageId? // empty] | unique | join(", ")' "$REPORT_FILE")"

if [ -n "$AMI_ID" ]; then
  printf 'AMI: %s (%s)\n\n' "$AMI_NAME" "$AMI_ID"
else
  printf 'AMI: %s\n\n' "$AMI_NAME"
fi

{
  printf 'Severity\tCVE\tScore\tAffected package(s)\tFix\tExploit\n'
  jq -r '
    def installed_version:
      (.version // "")
      + (if .release then "-" + .release else "" end);

    def package_summary:
      [
        .packageVulnerabilityDetails.vulnerablePackages[]?
        | .name + " " + installed_version + " -> " + (.fixedInVersion // "n/a")
      ]
      | unique
      | join("; ");

    [
      .findings[]?
      | select(.severity == "CRITICAL" or .severity == "HIGH")
    ]
    | sort_by(
        (if .severity == "CRITICAL" then 0 else 1 end),
        -(.inspectorScore // 0),
        (.packageVulnerabilityDetails.vulnerabilityId // .title)
      )
    | .[]
    | [
        .severity,
        (.packageVulnerabilityDetails.vulnerabilityId // .title),
        ((.inspectorScore // "") | tostring),
        package_summary,
        (.fixAvailable // ""),
        (.exploitAvailable // "")
      ]
    | @tsv
  ' "$REPORT_FILE"
} | format_table
