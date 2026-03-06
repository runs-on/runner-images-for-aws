#!/usr/bin/env bash
set -uo pipefail

AMI_NAME=""
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
INTERVAL_SEC="${WINDOWS_METRICS_INTERVAL_SEC:-180}"
METRICS_FILE="${WINDOWS_METRICS_FILE:-WINDOWS_METRICS.md}"

STOP_REQUESTED=0
SEEN_INSTANCE=0
NO_INSTANCE_POLLS=0

PEAK_USED="-"
PEAK_TOTAL="-"
PEAK_PCT="-"
PEAK_TS="-"

usage() {
  cat <<'EOF'
Usage: monitor-windows-builder-disk.sh --ami-name NAME [options]

Options:
  --ami-name NAME         AMI build tag name (required)
  --region REGION         AWS region (default: AWS_DEFAULT_REGION or us-east-1)
  --profile PROFILE       AWS profile (default: AWS_PROFILE)
  --interval-sec N        Poll interval in seconds (default: 180)
  --metrics-file PATH     Output markdown file (default: WINDOWS_METRICS.md)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ami-name)
      AMI_NAME="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --interval-sec)
      INTERVAL_SEC="${2:-}"
      shift 2
      ;;
    --metrics-file)
      METRICS_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$AMI_NAME" ]; then
  echo "ERROR: --ami-name is required" >&2
  exit 1
fi

if ! [[ "$INTERVAL_SEC" =~ ^[0-9]+$ ]] || [ "$INTERVAL_SEC" -le 0 ]; then
  echo "ERROR: --interval-sec must be a positive integer" >&2
  exit 1
fi

for cmd in aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

trap 'STOP_REQUESTED=1' INT TERM

aws_cmd() {
  if [ -n "$PROFILE" ]; then
    aws --profile "$PROFILE" --region "$REGION" "$@"
  else
    aws --region "$REGION" "$@"
  fi
}

append_line() {
  printf '%s\n' "$1" >> "$METRICS_FILE"
}

current_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

image_state() {
  local state
  state="$(aws_cmd ec2 describe-images --owners self --filters "Name=name,Values=$AMI_NAME" \
    --query 'Images[0].State' --output text 2>/dev/null || true)"
  if [ -z "$state" ] || [ "$state" = "None" ] || [ "$state" = "null" ]; then
    echo "not-found"
    return
  fi
  echo "$state"
}

latest_instance_json() {
  aws_cmd ec2 describe-instances \
    --filters "Name=tag:ami_name,Values=$AMI_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --output json 2>/dev/null || true
}

safe_note() {
  local text="$1"
  text="${text//$'\r'/ }"
  text="${text//$'\n'/ }"
  echo "$text" | sed -E 's/[[:space:]]+/ /g' | cut -c1-160
}

write_header() {
  if [ ! -f "$METRICS_FILE" ]; then
    append_line "# Windows Build Disk Metrics"
  fi
  append_line ""
  append_line "## $AMI_NAME"
  append_line "- Region: $REGION"
  append_line "- Sample interval: ${INTERVAL_SEC}s"
  append_line ""
  append_line "| Timestamp (UTC) | Instance ID | State | Used GB | Free GB | Total GB | Used % | Peak Used GB | Note |"
  append_line "|---|---|---|---:|---:|---:|---:|---:|---|"
}

compare_greater() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

probe_disk_usage_ssm() {
  local instance_id="$1"
  local ping_status command_id status output json_line

  C_USED="-"
  C_FREE="-"
  C_TOTAL="-"
  C_PCT="-"
  C_NOTE="ssm-unavailable"

  ping_status="$(aws_cmd ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"

  if [ "$ping_status" != "Online" ]; then
    C_NOTE="ssm-${ping_status:-unknown}"
    return
  fi

  local ps_cmd
  ps_cmd='$d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID=''C:''"; if ($null -eq $d) { Write-Output "{\"error\":\"no-c-drive\"}"; exit 2 }; [pscustomobject]@{UsedGB=[math]::Round(($d.Size-$d.FreeSpace)/1GB,2);FreeGB=[math]::Round($d.FreeSpace/1GB,2);TotalGB=[math]::Round($d.Size/1GB,2)} | ConvertTo-Json -Compress'

  local params_json
  params_json="$(jq -nc --arg cmd "$ps_cmd" '{commands:[$cmd]}')"

  command_id="$(aws_cmd ssm send-command \
    --document-name "AWS-RunPowerShellScript" \
    --instance-ids "$instance_id" \
    --parameters "$params_json" \
    --cli-binary-format raw-in-base64-out \
    --query 'Command.CommandId' --output text 2>/dev/null || true)"

  if [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
    C_NOTE="ssm-send-failed"
    return
  fi

  status="InProgress"
  for _ in $(seq 1 30); do
    status="$(aws_cmd ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || true)"
    case "$status" in
      Success|Failed|Cancelled|Cancelling|TimedOut)
        break
        ;;
      *)
        sleep 1
        ;;
    esac
  done

  output="$(aws_cmd ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text 2>/dev/null || true)"

  if [ "$status" != "Success" ]; then
    C_NOTE="ssm-${status:-unknown}"
    return
  fi

  json_line="$(printf '%s' "$output" | tr -d '\r' | tail -n 1)"
  if ! printf '%s' "$json_line" | jq -e . >/dev/null 2>&1; then
    C_NOTE="ssm-parse-failed"
    return
  fi

  C_USED="$(printf '%s' "$json_line" | jq -r '.UsedGB // empty')"
  C_FREE="$(printf '%s' "$json_line" | jq -r '.FreeGB // empty')"
  C_TOTAL="$(printf '%s' "$json_line" | jq -r '.TotalGB // empty')"

  if ! is_number "$C_USED" || ! is_number "$C_TOTAL" || [ "$(printf '%.0f' "$C_TOTAL")" -eq 0 ]; then
    C_USED="-"
    C_FREE="-"
    C_TOTAL="-"
    C_PCT="-"
    C_NOTE="ssm-invalid-values"
    return
  fi

  C_PCT="$(awk -v u="$C_USED" -v t="$C_TOTAL" 'BEGIN { printf("%.2f", (u/t)*100) }')"
  C_NOTE="ok"
}

write_row() {
  local ts="$1"
  local instance_id="$2"
  local state="$3"
  local used="$4"
  local free="$5"
  local total="$6"
  local pct="$7"
  local peak="$8"
  local note="$9"
  local pct_cell="$pct"
  if is_number "$pct"; then
    pct_cell="${pct}%"
  fi
  append_line "| $ts | $instance_id | $state | $used | $free | $total | $pct_cell | $peak | $(safe_note "$note") |"
}

update_peak() {
  local ts="$1"
  local used="$2"
  local total="$3"
  local pct="$4"

  if ! is_number "$used"; then
    return
  fi

  if [ "$PEAK_USED" = "-" ] || compare_greater "$used" "$PEAK_USED"; then
    PEAK_USED="$used"
    PEAK_TOTAL="$total"
    PEAK_PCT="$pct"
    PEAK_TS="$ts"
  fi
}

finalize() {
  append_line ""
  if is_number "$PEAK_USED"; then
    append_line "- Peak observed used: ${PEAK_USED} GB / ${PEAK_TOTAL} GB (${PEAK_PCT}%) at ${PEAK_TS}"
  else
    append_line "- Peak observed used: n/a (no successful C: samples captured)"
  fi
}

write_header

while [ "$STOP_REQUESTED" -eq 0 ]; do
  now_utc="$(current_timestamp)"
  inst_json="$(latest_instance_json)"
  instance_id="$(printf '%s' "$inst_json" | jq -r '[.Reservations[].Instances[]] | sort_by(.LaunchTime) | last | .InstanceId // empty' 2>/dev/null || true)"
  instance_state="$(printf '%s' "$inst_json" | jq -r '[.Reservations[].Instances[]] | sort_by(.LaunchTime) | last | .State.Name // empty' 2>/dev/null || true)"

  if [ -z "$instance_id" ]; then
    NO_INSTANCE_POLLS=$((NO_INSTANCE_POLLS + 1))
    img_state="$(image_state)"
    write_row "$now_utc" "-" "-" "-" "-" "-" "-" "$PEAK_USED" "builder-not-found image=${img_state}"

    # Stop once the AMI is finalized and no builder instance is around.
    if [ "$img_state" = "available" ] || [ "$img_state" = "failed" ]; then
      break
    fi
  else
    SEEN_INSTANCE=1
    NO_INSTANCE_POLLS=0
    C_USED="-"
    C_FREE="-"
    C_TOTAL="-"
    C_PCT="-"
    C_NOTE="instance-${instance_state}"

    if [ "$instance_state" = "running" ]; then
      probe_disk_usage_ssm "$instance_id"
      update_peak "$now_utc" "$C_USED" "$C_TOTAL" "$C_PCT"
    fi

    write_row "$now_utc" "$instance_id" "$instance_state" "$C_USED" "$C_FREE" "$C_TOTAL" "$C_PCT" "$PEAK_USED" "$C_NOTE"

    img_state="$(image_state)"
    if [ "$img_state" = "available" ] || [ "$img_state" = "failed" ]; then
      if [ "$instance_state" != "running" ] && [ "$instance_state" != "pending" ]; then
        break
      fi
    fi
  fi

  sleep "$INTERVAL_SEC" &
  wait $! || true
done

finalize
