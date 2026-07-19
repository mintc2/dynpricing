#!/bin/bash
#
# Measures the latency, error rate, timeout rate, and response completeness of
# the Rate API when all 36 unique (period, hotel, room) combinations are
# requested in a single batch.
#
# Scripts 03/04 measured the batch limit and the response time of a *single*
# attribute. Estimating the reliability of the real 36-item batch from those
# single-item numbers (e.g. treating the batch as 36 independent draws of the
# observed single-item failure rate) requires an independence assumption that
# may not hold: the API returns a batch as a whole, so it may succeed or fail
# as a unit. This script measures the 36-item batch directly, so the reliability
# figures the proxy actually depends on are observed rather than assumed.
#
# A short client timeout (default 50 ms) mirrors the proxy's non-blocking budget:
# any response the API does not deliver within it is counted as a timeout, which
# is the outcome the proxy would experience for the documented ">30 s" hangs.
#
# Example:
#   RATE_API_TOKEN='...' ./ai-data/06_out_test_api_batch_reliability.sh
#   RATE_API_TOKEN='...' ATTEMPTS=100 CLIENT_TIMEOUT_SECONDS=0.05 \
#     ./ai-data/06_out_test_api_batch_reliability.sh
#
# Note: each attempt consumes one request from the API's 1,000/day quota.

set -uo pipefail

: "${RATE_API_TOKEN:?Set RATE_API_TOKEN first}"
RATE_API_URL="${RATE_API_URL:-http://localhost:8080}"
ATTEMPTS="${ATTEMPTS:-1000}"
# Client-side budget. Kept short so ">30 s" API hangs register as timeouts
# rather than as slow-but-successful responses.
CLIENT_TIMEOUT_SECONDS="${CLIENT_TIMEOUT_SECONDS:-0.05}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-5}"

case "$ATTEMPTS" in
  *[!0-9]* | '' | 0) echo "ATTEMPTS must be a positive integer." >&2; exit 2 ;;
esac

# The full batch: all 36 unique valid combinations, matching the payload the
# proxy warms in a single call. Built the same way as script 03.
payload="$(
  {
    printf '{"attributes":['
    first=1

    for period in Summer Autumn Winter Spring; do
      for hotel in FloatingPointResort GitawayHotel RecursionRetreat; do
        for room in SingletonRoom BooleanTwin RestfulKing; do
          if [ "$first" -eq 0 ]; then printf ','; fi
          first=0
          printf '{"period":"%s","hotel":"%s","room":"%s"}' \
            "$period" "$hotel" "$room"
        done
      done
    done

    printf ']}'
  }
)"

batch_size="$(
  printf '%s' "$payload" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["attributes"]))
'
)"

timings_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$timings_file" "$response_file"' EXIT

successful_requests=0
error_requests=0
http_200_error_payload_requests=0
incomplete_batch_requests=0
invalid_http_200_payload_requests=0
timeout_requests=0

printf 'Rate API: %s\n' "$RATE_API_URL"
printf 'Sending %s batch requests of %s items each (%ss client timeout)...\n\n' \
  "$ATTEMPTS" "$batch_size" "$CLIENT_TIMEOUT_SECONDS"

for attempt in $(seq 1 "$ATTEMPTS"); do
  # Outputs: HTTP status, then total request duration in seconds.
  result="$(
    curl --silent --show-error \
      --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
      --max-time "$CLIENT_TIMEOUT_SECONDS" \
      --output "$response_file" \
      --write-out '%{http_code} %{time_total}' \
      --request POST "$RATE_API_URL/pricing" \
      --header "token: $RATE_API_TOKEN" \
      --header 'Content-Type: application/json' \
      --data "$payload" \
      2>/dev/null
  )"
  curl_exit=$?

  http_status="${result%% *}"
  duration_seconds="${result#* }"

  if [ "$curl_exit" -eq 0 ] && [ "$http_status" = "200" ]; then
    response_result="$(
      python3 - "$response_file" "$payload" <<'PY'
import json
import sys

error_payload = {
    "message": "Failed to process rates due to an intermittent issue.",
    "status": "error",
}

try:
    with open(sys.argv[1]) as response_file:
        response = json.load(response_file)
    expected = {
        (attribute["period"], attribute["hotel"], attribute["room"])
        for attribute in json.loads(sys.argv[2])["attributes"]
    }
except (OSError, ValueError, KeyError, TypeError):
    print("invalid")
    raise SystemExit

if response == error_payload:
    print("error-payload")
elif not isinstance(response, dict) or not isinstance(response.get("rates"), list):
    print("invalid")
else:
    try:
        returned = {
            (rate["period"], rate["hotel"], rate["room"])
            for rate in response["rates"]
        }
    except (KeyError, TypeError):
        print("invalid")
    else:
        if expected - returned:
            print("incomplete")
        elif len(response["rates"]) != len(expected) or returned != expected:
            print("invalid")
        else:
            print("success")
PY
    )"

    case "$response_result" in
      success)
        # Only complete, valid batches contribute to the latency distribution.
        printf '%s\n' "$duration_seconds" >> "$timings_file"
        successful_requests=$((successful_requests + 1))
        ;;
      error-payload)
        http_200_error_payload_requests=$((http_200_error_payload_requests + 1))
        echo "Attempt $attempt: HTTP 200 error payload"
        ;;
      incomplete)
        incomplete_batch_requests=$((incomplete_batch_requests + 1))
        echo "Attempt $attempt: HTTP 200 incomplete batch response"
        ;;
      *)
        invalid_http_200_payload_requests=$((invalid_http_200_payload_requests + 1))
        echo "Attempt $attempt: HTTP 200 invalid payload"
        ;;
    esac
  elif [ "$curl_exit" -eq 28 ]; then
    # curl exit 28 is an operation timeout: the API did not respond within the
    # client budget. This is the ">30 s hang" outcome the proxy would see.
    timeout_requests=$((timeout_requests + 1))
    echo "Attempt $attempt: client timeout after ${CLIENT_TIMEOUT_SECONDS}s"
  else
    # Any HTTP response other than 200 (e.g. 500, 429) or a transport error.
    error_requests=$((error_requests + 1))
    echo "Attempt $attempt: HTTP ${http_status:-000} (curl exit $curl_exit)"
  fi
done

echo
echo "Results"
echo "-------"
printf 'Batch size (items):   %s\n' "$batch_size"
printf 'Attempts:             %s\n' "$ATTEMPTS"
printf 'Successful (valid 200):  %s\n' "$successful_requests"
printf 'Errors (non-200):        %s\n' "$error_requests"
printf 'HTTP 200 error payloads:  %s\n' "$http_200_error_payload_requests"
printf 'Incomplete batch results:  %s\n' "$incomplete_batch_requests"
printf 'Invalid HTTP 200 payloads: %s\n' "$invalid_http_200_payload_requests"
printf 'Client timeouts:          %s\n' "$timeout_requests"

awk -v attempts="$ATTEMPTS" \
    -v errors="$error_requests" \
    -v error_payloads="$http_200_error_payload_requests" \
    -v incomplete_batches="$incomplete_batch_requests" \
    -v invalid_payloads="$invalid_http_200_payload_requests" \
    -v timeouts="$timeout_requests" '
  END {
    combined_faults = errors + error_payloads + incomplete_batches + invalid_payloads
    printf "Error rate:              %.2f%% (%d/%d)\n", 100 * errors / attempts, errors, attempts
    printf "HTTP 200 error rate:     %.2f%% (%d/%d)\n", 100 * error_payloads / attempts, error_payloads, attempts
    printf "Incomplete batch rate:   %.2f%% (%d/%d)\n", 100 * incomplete_batches / attempts, incomplete_batches, attempts
    printf "Invalid HTTP 200 rate:   %.2f%% (%d/%d)\n", 100 * invalid_payloads / attempts, invalid_payloads, attempts
    printf "Combined fault rate:     %.2f%% (%d/%d)\n", 100 * combined_faults / attempts, combined_faults, attempts
    printf "Timeout rate:            %.2f%% (%d/%d)\n", 100 * timeouts / attempts, timeouts, attempts
  }
' /dev/null

echo
if [ "$successful_requests" -gt 0 ]; then
  echo "Latency of successful batch responses"
  echo "-------------------------------------"
  # Sort so a percentile can be read positionally from the timing samples.
  sort -n "$timings_file" | awk '
    { ms[NR] = $1 * 1000; sum += ms[NR] }
    END {
      n = NR
      # Nearest-rank percentile: index = ceil(p/100 * n), clamped to [1, n].
      p50 = ms[int((50 * n + 99) / 100)]
      p95 = ms[int((95 * n + 99) / 100)]
      p99 = ms[int((99 * n + 99) / 100)]
      printf "Samples:              %d\n", n
      printf "Average total time:   %.2f ms\n", sum / n
      printf "Minimum total time:   %.2f ms\n", ms[1]
      printf "p50 total time:       %.2f ms\n", p50
      printf "p95 total time:       %.2f ms\n", p95
      printf "p99 total time:       %.2f ms\n", p99
      printf "Maximum total time:   %.2f ms\n", ms[n]
    }
  '
else
  echo "No successful batch responses were available to calculate latency."
fi
