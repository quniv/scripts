#!/usr/bin/env bash

set -euo pipefail

REGION="${1:-${AWS_REGION:-ap-southeast-2}}"
SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI is not installed or is not in PATH." >&2
  exit 1
fi

role_name_from_profile_arn() {
  local profile_arn="$1"
  local profile_name="${profile_arn##*/}"

  aws iam get-instance-profile \
    --instance-profile-name "$profile_name" \
    --query 'InstanceProfile.Roles[0].RoleName' \
    --output text
}

add_ssm_permission() {
  local instance_id="$1"
  local label="$2"
  local profile_arn
  local role_name

  profile_arn="$(
    aws ec2 describe-instances \
      --region "$REGION" \
      --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
      --output text
  )"

  if [[ "$profile_arn" == "None" || -z "$profile_arn" ]]; then
    echo "Error: ${label} has no IAM instance profile." >&2
    echo "Associate an instance profile first, then re-run to attach the AWS managed policy AmazonSSMManagedInstanceCore." >&2
    exit 1
  fi

  role_name="$(role_name_from_profile_arn "$profile_arn")"

  if [[ "$role_name" == "None" || -z "$role_name" ]]; then
    echo "Error: instance profile ${profile_arn} has no IAM role." >&2
    exit 1
  fi

  if aws iam list-attached-role-policies --role-name "$role_name" \
    --query "AttachedPolicies[?PolicyArn==\`${SSM_POLICY_ARN}\`].PolicyArn" \
    --output text | grep -q "$SSM_POLICY_ARN"; then
    echo "${label} already has AWS managed policy AmazonSSMManagedInstanceCore on role ${role_name}."
    return 0
  fi

  echo "Attaching AWS managed policy AmazonSSMManagedInstanceCore to role ${role_name}..."
  aws iam attach-role-policy \
    --role-name "$role_name" \
    --policy-arn "$SSM_POLICY_ARN"

  echo "SSM permission added. Wait ~1–2 minutes for the agent, then connect with:"
  echo "  ./connect-ec2-ssm.sh ${REGION}"
}

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

echo
echo "Current EC2 instances:"
printf '%s\n' "${INSTANCE_LABELS[@]}"
echo

echo "Select an instance:"
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

echo
read -r -p "Attach AWS managed policy AmazonSSMManagedInstanceCore to ${LABEL}? [y/N] " ANSWER
case "${ANSWER}" in
  [yY]|[yY][eE][sS])
    add_ssm_permission "$INSTANCE_ID" "$LABEL"
    ;;
  *)
    echo "Skipped adding SSM permission."
    ;;
esac
