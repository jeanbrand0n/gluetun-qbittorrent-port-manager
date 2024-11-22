# gluetun-qbittorrent Port Manager
Automatically updates the listening port for qBittorrent to match the port forwarded by [Gluetun](https://github.com/qdm12/gluetun/). This project is a fork of [SnoringDragon's gluetun-qbittorrent-port-manager](https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager).

## Overview
[Gluetun](https://github.com/qdm12/gluetun/) can forward ports for supported VPN providers, but qBittorrent lacks the ability to automatically update its listening port to match this forwarded port. This script, available as a Docker container, checks every 30 seconds if the forwarded port file created by Gluetun has changed, and automatically updates qBittorrent's listening port accordingly.

## Important Note
You need to add the provided  `docker-compose.yml` configuration into your existing Docker Compose setup that includes Gluetun. Make sure to replace the default values with your specific settings. Otherwise, the script will not work properly.

## Manual Test
Before using this script, ensure that qBittorrent is properly connected to the forwarded port. You can confirm this if you see a green globe icon at the bottom of the WebUI.

##  Setting Up Gluetun
Add a volume mount to your [Gluetun](https://github.com/qdm12/gluetun/) container, for example:
```
volumes:
    - /docker/gluetunvpn:/gluetun
```
Then, add the following environment variable to your Gluetun container:
```
environment:
    - VPN_PORT_FORWARDING_STATUS_FILE=/gluetun/forwarded_port
```
This ensures that the forwarded port information is saved to the volume at `/gluetun/`. Without this setup, [Gluetun](https://github.com/qdm12/gluetun/) will not create the file that stores the forwarded port.

## Setting Up Gluetun-qBittorrent Port Manager
Ensure that the correct volume is set to access the `forwarded_port` file. In your Docker Compose file, add:
```
volumes:
      - /docker/gluetun:/tmp/gluetun
```
Within the container, this volume will be accessible at `/tmp/gluetun`.

Next, inform the script where to find the `forwarded_port` file by adding the following environment variable:
```
environment:
      PORT_FORWARDED: /tmp/gluetun/forwarded_port
```
That's it! With these steps completed, the script should be able to dynamically update the qBittorrent listening port.