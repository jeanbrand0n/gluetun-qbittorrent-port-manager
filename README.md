# gluetun-qbittorrent Port Manager
Automatically updates the listening port for qBittorrent to match the port forwarded by [Gluetun](https://github.com/qdm12/gluetun/). This project is a fork of [SnoringDragon's gluetun-qbittorrent-port-manager](https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager).

## Overview
[Gluetun](https://github.com/qdm12/gluetun/)  can forward ports for supported VPN providers, but qBittorrent lacks the ability to automatically update its listening port. In previous versions, the forwarded port was written to a file; however, with Gluetun v4, this file has been replaced by a Control Server API. This Docker container-based script periodically (by default every 30 seconds) retrieves the current forwarded port and the VPN public IP via the Control Server API, then automatically updates qBittorrent's listening port accordingly. Additionally, it uses nmap to check whether the port is actually open (TCP and UDP). If the TCP port appears closed or filtered, the script automatically restarts the VPN connection to obtain a new forwarded port.

## Important Note
You must integrate the provided `docker-compose.yml` configuration into your existing Docker Compose setup that includes Gluetun. Be sure to replace the default values with your specific settings; otherwise, the script will not function correctly.

## Manual Test
Before using this script, ensure that qBittorrent is properly connected to the forwarded port. You can confirm this if you see a green globe icon at the bottom of the qBittorrent WebUI.

##  Setting Up Gluetun
Add a volume mount to your [Gluetun](https://github.com/qdm12/gluetun/) container, for example:
```
volumes:
    - /docker/gluetunvpn:/gluetun
```
Enable the Control Server. Set the following environment variables in your Gluetun container:
```
environment:
  - CONTROL_SERVER=on
  - CONTROL_SERVER_ALLOW_CIDRS=192.168.1.0/24
```
Publish the Control Server Port. To make the Control Server externally accessible, map the internal port 8000 to a host port (e.g., 8000):
```
ports:
  - 8000:8000/tcp  # Control Server (accessible externally via port 8000, first port external, second port internal)
```

## Setting Up Gluetun-qBittorrent Port Manager
Ensure that the correct volume is mounted so that the container can access any necessary shared data. For example:
```
volumes:
  - /docker/gluetun:/tmp/gluetun
```
Within the container, this volume will be accessible at `/tmp/gluetun`.

Environment Variables
Configure your Docker Compose file to include the qBittorrent connection details as well as the Control Server URL and timing parameters. For example:
```
environment:
  QBITTORRENT_SERVER: localhost         # IP address of your qBittorrent server (adjust as needed)
  QBITTORRENT_PORT: 8080                  # Port on which qBittorrent is listening
  QBITTORRENT_USER: admin                 # qBittorrent username
  QBITTORRENT_PASS: adminadmin            # qBittorrent password
  HTTP_S: http                           # Use "http" or "https" as required
  
  # Timing parameters
  CHECK_INTERVAL: 30                     # Interval (in seconds) for the update cycle (default: 30)
  WAIT_TIMEOUT: 60                       # Timeout (in seconds) for waiting on VPN status changes
  WAIT_INTERVAL: 5                       # Interval (in seconds) between VPN status checks

  # Control Server settings
  # The Control Server is assumed to be available at hostname "gluetun" on port 8000 within the Docker network.
  CONTROL_SERVER_URL: http://gluetun:8000

```
With these steps completed, the script will dynamically update qBittorrent's listening port by querying the Gluetun Control Server for the current forwarded port and VPN public IP. It will also perform health checks using nmap and restart the VPN if the port is not open.