#!/bin/bash

COOKIES="/tmp/cookies.txt"

update_port () {
  PORT=$(cat $PORT_FORWARDED)
  rm -f $COOKIES
  
  # Log in to qBittorrent and save the session cookie
  login_response=$(curl -s -c $COOKIES --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login")
  
  if ! echo "$login_response" | grep -iq "Ok"; then
    echo "Error logging into the qBittorrent Web UI"
    return 1
  fi

  # Update the qBittorrent listening port
  curl -s -b $COOKIES --data-urlencode "json={\"listen_port\":$PORT}" "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/setPreferences" > /dev/null
  
  rm -f $COOKIES
  echo "Successfully updated qBittorrent to port $PORT"
}

while true; do
  if [ -f $PORT_FORWARDED ]; then
    update_port
  else
    echo "Couldn't find file $PORT_FORWARDED"
  fi
  
  # Wait for 30 seconds before checking again
  sleep 30
done
