#!/bin/bash

# Required variables
REQUIRED_VARS=(
  "QBITTORRENT_USER"
  "QBITTORRENT_PASS"
  "QBITTORRENT_SERVER"
  "QBITTORRENT_PORT"
)

# Default configuration
CONTROL_SERVER_URL="${CONTROL_SERVER_URL:-http://localhost:8000}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
HTTP_S="${HTTP_S:-http}"
VPNMODE="${VPNMODE:-OPENVPN}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"

# Gluetun auth_config.toml variables
GLUETUN_AUTH_MODE="${GLUETUN_AUTH_MODE:-none}"  # none, basic, or apikey
GLUETUN_AUTH_USERNAME="${GLUETUN_AUTH_USERNAME:-}"
GLUETUN_AUTH_PASSWORD="${GLUETUN_AUTH_PASSWORD:-}"
GLUETUN_AUTH_APIKEY="${GLUETUN_AUTH_APIKEY:-}"

QBITTORRENT_COOKIES="/tmp/cookies.txt"
LAST_PORT=""
SCRIPT_PID=""

# API Paths
declare -A API_PATHS=(
  ["vpn_status"]="/v1/openvpn/status"
  ["port_forwarded"]="/v1/openvpn/portforwarded"
  ["public_ip"]="/v1/publicip/ip"
  ["qbittorrent_login"]="/api/v2/auth/login"
  ["qbittorrent_preferences"]="/api/v2/app/preferences"
  ["qbittorrent_set_preferences"]="/api/v2/app/setPreferences"
  ["qbittorrent_shutdown"]="/api/v2/app/shutdown"
)

# Utility functions
remove_qbittorrent_cookies() {
  rm -f "${QBITTORRENT_COOKIES}"
}

get_timestamp() {
  echo $(date '+%Y-%m-%d %H:%M:%S%z')
}

log() {
   echo "$(get_timestamp): $*"
}

error() {
  log "ERROR: $*" >&2
}

check_required_vars() {
  local missing_vars=()
  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
      missing_vars+=("${var}")
    fi
  done

  if [ ${#missing_vars[@]} -gt 0 ]; then
    error "Missing required environment variables: ${missing_vars[*]}"
    return 1
  fi
  return 0
}

cleanup() {
  log "Performing cleanup..."
  remove_qbittorrent_cookies
  if [ -n "${SCRIPT_PID}" ]; then
    kill "${SCRIPT_PID}" 2>/dev/null || true
  fi
  exit 0
}

# Validate Gluetun control server authentication configuration
# https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md
validate_gluetun_auth_config() {
  case "${GLUETUN_AUTH_MODE}" in
    "basic")
      if [ -z "${GLUETUN_AUTH_USERNAME}" ] || [ -z "${GLUETUN_AUTH_PASSWORD}" ]; then
        error "Basic authentication requires GLUETUN_AUTH_USERNAME and GLUETUN_AUTH_PASSWORD"
        return 1
      fi
      ;;
    "apikey")
      if [ -z "${GLUETUN_AUTH_APIKEY}" ]; then
        error "API key authentication requires GLUETUN_AUTH_APIKEY"
        return 1
      fi
      ;;
    "none")
      # No validation required
      ;;
    *)
      error "Invalid GLUETUN_AUTH_MODE: ${GLUETUN_AUTH_MODE}. Must be one of: none, basic, apikey"
      return 1
      ;;
  esac
  return 0
}


# Signal handling
trap cleanup SIGINT SIGTERM

# API functions
make_gluetun_api_call() {
  local method="$1"
  local endpoint="$2"
  local data="$3"
  local response
  local auth_header=""

  # Set up authentication based on mode
  case "${GLUETUN_AUTH_MODE}" in
    "basic")
      if [ -z "${GLUETUN_AUTH_USERNAME}" ] || [ -z "${GLUETUN_AUTH_PASSWORD}" ]; then
        error "Basic auth requires both username and password"
        return 1
      fi
      auth_header="-u ${GLUETUN_AUTH_USERNAME}:${GLUETUN_AUTH_PASSWORD}"
      ;;
    "apikey")
      if [ -z "${GLUETUN_AUTH_APIKEY}" ]; then
        error "API key auth requires an API key"
        return 1
      fi
      auth_header="-H \"X-API-Key: ${GLUETUN_AUTH_APIKEY}\""
      ;;
    "none")
      # No authentication needed
      ;;
    *)
      error "Invalid authentication mode: ${GLUETUN_AUTH_MODE}"
      return 1
      ;;
  esac

  # Make the API call with appropriate authentication
  response=$(curl -s -X "${method}" \
    -H "Content-Type: application/json" \
    ${auth_header} \
    -d "${data}" "${CONTROL_SERVER_URL}${endpoint}")

  if [ $? -ne 0 ]; then
    error "Failed to make Gluetun API call to ${endpoint}"
    return 1
  fi

  # Check for authentication errors
  if echo "${response}" | grep -q "401 Unauthorized"; then
    error "Authentication failed for Gluetun API call to ${endpoint}"
    return 1
  fi

  echo "${response}"
}

make_qbittorrent_api_call() {
  local method="${1:-GET}"
  local endpoint="$2"
  local data="$3"
  local response

  if [ -n "${data}" ]; then
    response=$(curl -s -X "${method}" -b ${QBITTORRENT_COOKIES} \
      --data-urlencode "json=${data}" \
      "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}${endpoint}")
  else
    response=$(curl -s -X "${method}" -b ${QBITTORRENT_COOKIES} \
      "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}${endpoint}")
  fi

  if [ $? -ne 0 ]; then
    error "Failed to make qBittorrent API call to ${endpoint}"
    return 1
  fi
  echo "${response}"
}

# VPN functions
wait_for_vpn_status() {
  local desired_status="$1"
  local timeout="${WAIT_TIMEOUT}"
  local interval="${WAIT_INTERVAL}"
  local elapsed=0

  log "Waiting for VPN status to become '${desired_status}'..."
  while [ "${elapsed}" -lt "${timeout}" ]; do
    current_status=$(make_gluetun_api_call "GET" "${API_PATHS[vpn_status]}" "" | jq -r '.status')
    if [ $? -ne 0 ]; then
      error "Failed to get VPN status"
      return 1
    fi
    log "Current VPN status: ${current_status}"
    if [ "${current_status}" = "${desired_status}" ]; then
      log "VPN status is now '${desired_status}'"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  error "Timeout waiting for VPN status to become '${desired_status}'. Current status: ${current_status}"
  return 1
}

change_vpn_status() {
  local status="$1"
  log "Setting VPN status to '${status}'..."
  response=$(make_gluetun_api_call "PUT" "${API_PATHS[vpn_status]}" "{\"status\":\"${status}\"}")
  if [ $? -ne 0 ]; then
    error "Failed to change VPN status"
    return 1
  fi
  log "Response from VPN status change: ${response}"
  wait_for_vpn_status "${status}"
}

# Port functionality
check_port_status() {
  local ip="$1"
  local port="$2"
  local retries=3
  local delay=5

  for attempt in $(seq 1 ${retries}); do
    log "Checking TCP port ${port} on ${ip} with nmap (Attempt: ${attempt})..."
    tcp_result=$(nmap -Pn -p "${port}" "${ip}" 2>/dev/null | grep "${port}/tcp")
    if echo "${tcp_result}" | grep -qi "open"; then
      log "TCP port ${port} is open on ${ip}."
      return 0
    else
      log "WARNING: TCP port ${port} is closed or filtered on ${ip}!"
      if [ "${attempt}" -lt "${retries}" ]; then
        log "Retrying in ${delay} seconds..."
        sleep "${delay}"
      fi
    fi
  done

  error "TCP port check failed after ${retries} attempts."
  return 1
}

qbittorrent_login() {
  remove_qbittorrent_cookies
  local login_response
  login_response=$(curl -s -c "${QBITTORRENT_COOKIES}" --data "username=${QBITTORRENT_USER}&password=${QBITTORRENT_PASS}" \
    "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}${API_PATHS[qbittorrent_login]}")
  
  if [ $? -ne 0 ]; then
    error "Failed to connect to qBittorrent"
    return 1
  fi

  if echo "${login_response}" | grep -iq "Ok"; then
    return 0
  else
    error "Error logging into the qBittorrent Web UI"
    return 1
  fi
}

check_port_change() {
  local new_port="$1"
  if [ "${LAST_PORT}" = "${new_port}" ]; then
    return 1
  fi
  return 0
}

update_qbittorrent_port() {
  local port="$1"
  if ! qbittorrent_login; then
    return 1
  fi

  log "Updating qBittorrent listening port to ${port}..."
  if ! make_qbittorrent_api_call "POST" "${API_PATHS[qbittorrent_set_preferences]}" "{\"listen_port\":${port}}" > /dev/null; then
    error "Failed to update qBittorrent port"
    return 1
  fi
  log "qBittorrent successfully updated to port ${port}"
  return 0
}

verify_current_port() {
  local port="$1"
  if ! qbittorrent_login; then
    return 1
  fi

  CURRENT_QBIT_PORT=$(make_qbittorrent_api_call "GET" "${API_PATHS[qbittorrent_preferences]}" "" | jq -r '.listen_port')
  if [ $? -ne 0 ]; then
    error "Failed to get qBittorrent preferences"
    return 1
  fi

  if [ "${CURRENT_QBIT_PORT}" != "${port}" ]; then
    log "qBittorrent is reachable but using incorrect port: ${CURRENT_QBIT_PORT} (expected: ${port})"
    log "Updating qBittorrent to port ${port}..."
    if ! make_qbittorrent_api_call "POST" "${API_PATHS[qbittorrent_set_preferences]}" "{\"listen_port\":${port}}" > /dev/null; then
      error "Failed to update qBittorrent port"
      return 1
    fi
    log "qBittorrent port updated."
  else
    log "qBittorrent port is correctly set."
  fi
  return 0
}

verify_port() {
  local port="$1"
  if [ "${VPNMODE}" = "DUMPMODE" ]; then
    log "DUMPMODE active: Port updated without TCP port check."
    return 0
  fi

  log "Retrieving current VPN public IP from Control Server..."
  local public_ip
  public_ip=$(make_gluetun_api_call "GET" "${API_PATHS[public_ip]}" "" | jq -r '.public_ip')
  if [ $? -ne 0 ] || [ -z "${public_ip}" ] || [ "${public_ip}" = "null" ]; then
    error "Error retrieving public IP from Control Server"
    return 1
  fi

  log "Current VPN puslic IP: ${public_ip}"
  if check_port_status "${public_ip}" "${port}"; then
    log "Port check successful."
    return 0
  else
    handle_port_check_failure
    return 1
  fi
}

handle_port_check_failure() {
  log "Port check failed."
  if [ "${VPNMODE}" = "OPENVPN" ]; then
    log "VPNMODE is OPENVPN. Restarting VPN connection..."
    change_vpn_status "stopped"
    change_vpn_status "running"
  elif [ "${VPNMODE}" = "WIREGUARD" ]; then
    log "VPNMODE is WIREGUARD. Shutting down qBittorrent due to closed TCP port..."
    shutdown_qbittorrent
  else
    log "Unknown VPNMODE: ${VPNMODE}. No action taken."
  fi
}

update_port() {
  log "Retrieving forwarded port from Control Server..."
  local new_port
  new_port=$(make_gluetun_api_call "GET" "${API_PATHS[port_forwarded]}" "" | jq -r '.port')
  if [ $? -ne 0 ] || [ -z "${new_port}" ] || [ "${new_port}" = "null" ]; then
    error "Error retrieving forwarded port from Control Server"
    return 1
  fi

  # Check if the port has changed. If it has, update qBittorrent.
  if ! check_port_change "${new_port}"; then
      if ! update_qbittorrent_port "${new_port}"; then
          return 1
      fi
      LAST_PORT="${new_port}"
      remove_qbittorrent_cookies
  else
    log "Port (${new_port}) has not changed. No update necessary."
  fi

  # Verify the new port is working
  verify_port "${new_port}"
}

shutdown_qbittorrent() {
  log "Shutting down qBittorrent via WebUI API..."
  if ! qbittorrent_login; then
    return 1
  fi

  shutdown_response=$(make_qbittorrent_api_call "POST" "${API_PATHS[qbittorrent_shutdown]}" "" "true")
  if [ $? -ne 0 ]; then
    error "Failed to shutdown qBittorrent"
    return 1
  fi

  if [ "${shutdown_response}" = "" ]; then
    log "qBittorrent has been successfully shut down."
  else
    error "Unexpected response: ${shutdown_response}"
  fi

  remove_qbittorrent_cookies
}

main() {
  # Validate required variables and Gluetun control server auth config
  if ! check_required_vars; then
    exit 1
  fi

  if ! validate_gluetun_auth_config; then
    exit 1
  fi

  SCRIPT_PID=$$
  log "Starting port manager loop (PID: ${SCRIPT_PID})..."
  log "Gluetun control server authentication mode: ${GLUETUN_AUTH_MODE}"

  while true; do
    update_port
    sleep "${CHECK_INTERVAL}"
  done
}

# Run the main function
main