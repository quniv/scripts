#!/usr/bin/env bash

set -euo pipefail

REGION="${1:-${AWS_REGION:-il-central-1}}"

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI is not installed or is not in PATH." >&2
  exit 1
fi

echo "Fetching EC2 instances in region ${REGION}..."

INSTANCE_OUTPUT="$(
  aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`]|[0].Value || `-`, State.Name]' \
    --output text
)"

INSTANCE_IDS=()
INSTANCE_LABELS=()

while IFS=$'\t' read -r instance_id instance_name instance_state; do
  [[ -z "${instance_id:-}" ]] && continue
  INSTANCE_IDS+=("$instance_id")
  INSTANCE_LABELS+=("${instance_name} (${instance_id}) [${instance_state}]")
done < <(printf '%s\n' "$INSTANCE_OUTPUT" | sed '/^$/d')

if ((${#INSTANCE_IDS[@]} == 0)); then
  echo "No EC2 instances found in region ${REGION}."
  exit 0
fi

echo "Select an instance to connect to:"
select LABEL in "${INSTANCE_LABELS[@]}" "Cancel"; do
  if [[ "$LABEL" == "Cancel" ]]; then
    echo "Cancelled."
    exit 0
  fi

  if [[ -n "${LABEL:-}" ]]; then
    INSTANCE_ID="${INSTANCE_IDS[REPLY - 1]}"
    break
  fi

  echo "Invalid selection. Enter a number from the list." >&2
done

echo "Starting SSM session with ${LABEL} in ${REGION}..."
exec aws ssm start-session --region "$REGION" --target "$INSTANCE_ID"
