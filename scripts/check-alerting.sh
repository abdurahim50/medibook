#!/usr/bin/env bash
# Check that alarms will reach someone (finding F-13). Each new environment
# creates a new SNS email subscription, which delivers nothing until the link in
# the "Subscription Confirmation" email is clicked. Run from infra/ after apply.
#
# Usage: ../scripts/check-alerting.sh           wait up to 10 minutes for a confirmed subscription
#        ../scripts/check-alerting.sh --test    then publish a test notification to prove delivery
# Requires: terraform, aws
set -euo pipefail

TOPIC="$(terraform output -raw alert_topic_arn)"
DEADLINE=$((SECONDS + 600))

confirmed() {
  aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" \
    --query "length(Subscriptions[?SubscriptionArn != 'PendingConfirmation'])" --output text
}

until [[ "$(confirmed)" -gt 0 ]]; do
  if (( SECONDS >= DEADLINE )); then
    echo "FAIL: no confirmed alert subscription after 10 minutes; alarms will notify no one." >&2
    exit 1
  fi
  echo "Waiting: confirm the AWS Notifications subscription email, then this check continues..."
  sleep 15
done
echo "OK: $(confirmed) confirmed alert subscription(s)."

if [[ "${1:-}" == "--test" ]]; then
  aws sns publish --topic-arn "$TOPIC" --subject "MediBook alert test" \
    --message "Test notification from scripts/check-alerting.sh at $(date -u +%FT%TZ). No action needed." \
    --query MessageId --output text >/dev/null
  echo "Test notification published: check that the email arrives."
fi
