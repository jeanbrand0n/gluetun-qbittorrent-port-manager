#!/bin/bash

# Set default values for environment variables if not provided
CONTROL_SERVER_URL="${CONTROL_SERVER_URL:-http://localhost:8000}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"       # Interval (in seconds) between update cycles
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"           # Timeout (in seconds) for waiting on VPN status
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"          # Interval (in seconds) between status checks

COOKIES="/tmp/cookies.txt"

# Function: Remove the cookie file
remove_cookies() {
  rm -f "$COOKIES"
}

# Function: Wait until the VPN status matches the desired state
wait_for_vpn_status() {
  local desired_status="$1"  # "running" or "stopped"
  local timeout="$WAIT_TIMEOUT"
  local interval="$WAIT_INTERVAL"
  local elapsed=0

  echo "Waiting for VPN status to become '$desired_status'..."
  while [ "$elapsed" -lt "$timeout" ]; do
    current_status=$(curl -s "$CONTROL_SERVER_URL/v1/openvpn/status" | jq -r '.status')
    echo "Current VPN status: $current_status"
    if [ "$current_status" = "$desired_status" ]; then
      echo "VPN status is now '$desired_status'"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "Timeout waiting for VPN status to become '$desired_status'. Current status: $current_status"
  return 1
}

# Function: Change the VPN status via the Control Server
change_vpn_status() {
  local status="$1"  # "running" or "stopped"
  echo "Setting VPN status to '$status'..."
  response=$(curl -s -X PUT -H "Content-Type: application/json" \
    -d "{\"status\":\"$status\"}" "$CONTROL_SERVER_URL/v1/openvpn/status")
  echo "Response from VPN status change: $response"
  # Wait until the desired status is reached
  wait_for_vpn_status "$status"
}

# Function: Check with nmap whether the given TCP port on the IP is open
check_port_status() {
  local ip="$1"
  local port="$2"
  echo "Checking TCP port $port on $ip with nmap..."
  tcp_result=$(nmap -Pn -p "$port" "$ip" 2>/dev/null | grep "$port/tcp")
  if echo "$tcp_result" | grep -qi "open"; then
    echo "TCP port $port is open on $ip."
    return 0
  else
    echo "WARNING: TCP port $port is closed or filtered on $ip!"
    return 1
  fi
}

# Main function: Updates the qBittorrent port and checks port status
update_port() {
  echo "Retrieving forwarded port from Control Server..."
  PORT=$(curl -s "$CONTROL_SERVER_URL/v1/openvpn/portforwarded" | jq -r '.port')
  if [ -z "$PORT" ] || [ "$PORT" = "null" ]; then
    echo "Error retrieving forwarded port from Control Server"
    return 1
  fi

  remove_cookies

  echo "Logging into qBittorrent..."
  login_response=$(curl -s -c "$COOKIES" --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
    "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login")
  if ! echo "$login_response" | grep -iq "Ok"; then
    echo "Error logging into the qBittorrent Web UI"
    return 1
  fi

  echo "Updating qBittorrent listening port to $PORT..."
  curl -s -b "$COOKIES" --data-urlencode "json={\"listen_port\":$PORT}" \
    "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/setPreferences" > /dev/null
  remove_cookies
  echo "Successfully updated qBittorrent to port $PORT"

  echo "Retrieving current VPN public IP from Control Server..."
  PUBLIC_IP=$(curl -s "$CONTROL_SERVER_URL/v1/publicip/ip" | jq -r '.public_ip')
  if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
    echo "Error retrieving public IP from Control Server"
  else
    echo "Current VPN public IP: $PUBLIC_IP"
    # Check TCP port status using nmap
    if ! check_port_status "$PUBLIC_IP" "$PORT"; then
      echo "Port $PORT on $PUBLIC_IP is not open. Restarting VPN connection..."
      # Stop VPN (this stops OpenVPN and Wireguard)
      change_vpn_status "stopped"
      # Start VPN again
      change_vpn_status "running"
    fi
  fi
}

# Main loop: Update port at the defined intervals
while true; do
  update_port
  sleep "$CHECK_INTERVAL"
done
