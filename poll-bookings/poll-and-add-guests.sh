#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------
# Poll Cal.com for recent bookings and add guests.
# Designed to run on a schedule via GitHub Actions.
# -------------------------------------------------------

CAL_API_BASE="https://api.cal.com/v2"
CAL_API_VERSION="2024-08-13"
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-15}"

# --- Validate config ---
if [[ -z "${CAL_API_KEY:-}" ]]; then
  echo "::error::CAL_API_KEY is not set"
  exit 1
fi

# --- Guest lists ---
DEFAULT_GUESTS='[{"email":"Sandra.Murray@altra.cloud","name":"Sandra Murray"}]'

WHITE_GLOVE_GUESTS='[{"email":"luke.lloyd@altra.cloud","name":"Luke Lloyd"},{"email":"Joey.Undis@altra.cloud","name":"Joey Undis"}]'

WHITE_GLOVE_SLUG="dr-migrate-white-glove-kickoff"

# --- Helpers ---
api_get() {
  curl -sf --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${CAL_API_KEY}" \
    -H "cal-api-version: ${CAL_API_VERSION}" \
    "$1"
}

api_post() {
  curl -sf --retry 3 --retry-delay 2 \
    -X POST \
    -H "Authorization: Bearer ${CAL_API_KEY}" \
    -H "Content-Type: application/json" \
    -H "cal-api-version: ${CAL_API_VERSION}" \
    -d "$2" \
    "$1"
}

# --- Fetch recent bookings ---
# afterStart = now, so we only get future bookings that were recently created.
# We rely on the API returning bookings sorted by creation and filter client-side.
now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cutoff_iso=$(date -u -d "${LOOKBACK_MINUTES} minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-"${LOOKBACK_MINUTES}"M +"%Y-%m-%dT%H:%M:%SZ")

echo "Polling for bookings created after ${cutoff_iso} (lookback=${LOOKBACK_MINUTES}m)"

bookings_response=$(api_get "${CAL_API_BASE}/bookings?status=upcoming&sortStart=asc&limit=50" || echo '{"status":"error"}')

if ! echo "${bookings_response}" | jq -e '.status == "success"' > /dev/null 2>&1; then
  echo "::warning::Failed to fetch bookings or unexpected response"
  echo "${bookings_response}" | head -c 500
  exit 0
fi

# Filter to bookings created within the lookback window
bookings=$(echo "${bookings_response}" | jq -c --arg cutoff "${cutoff_iso}" '
  .data // [] | map(select(.createdAt >= $cutoff))
')

count=$(echo "${bookings}" | jq 'length')
echo "Found ${count} booking(s) created in the last ${LOOKBACK_MINUTES} minutes"

if [[ "${count}" -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

# --- Process each booking ---
echo "${bookings}" | jq -c '.[]' | while read -r booking; do
  uid=$(echo "${booking}" | jq -r '.uid')
  event_slug=$(echo "${booking}" | jq -r '.eventType.slug // empty')
  event_title=$(echo "${booking}" | jq -r '.title // empty')
  existing_guests=$(echo "${booking}" | jq -r '[.guests[]?.email // empty] | map(ascii_downcase)')

  echo "Processing booking ${uid} (slug=${event_slug})"

  # Determine if white-glove
  is_white_glove=false
  for field in "${event_slug}" "${event_title}"; do
    if [[ "${field,,}" == *"${WHITE_GLOVE_SLUG}"* ]]; then
      is_white_glove=true
      break
    fi
  done

  # Build guest list
  if [[ "${is_white_glove}" == "true" ]]; then
    guests_to_add=$(echo "${DEFAULT_GUESTS} ${WHITE_GLOVE_GUESTS}" | jq -s 'add')
    echo "  White-glove booking detected — adding default + white-glove guests"
  else
    guests_to_add="${DEFAULT_GUESTS}"
    echo "  Standard booking — adding default guests"
  fi

  # Filter out guests that are already on the booking
  guests_to_add=$(echo "${guests_to_add}" | jq -c --argjson existing "${existing_guests}" '
    map(select((.email | ascii_downcase) as $e | $existing | index($e) | not))
  ')

  guest_count=$(echo "${guests_to_add}" | jq 'length')
  if [[ "${guest_count}" -eq 0 ]]; then
    echo "  All guests already present, skipping."
    continue
  fi

  # Add guests
  payload=$(jq -n --argjson g "${guests_to_add}" '{"guests": $g}')
  echo "  Adding ${guest_count} guest(s) to booking ${uid}..."

  if api_post "${CAL_API_BASE}/bookings/${uid}/guests" "${payload}" > /dev/null; then
    echo "  Done."
  else
    echo "::warning::Failed to add guests to booking ${uid}"
  fi
done

echo "Polling complete."
