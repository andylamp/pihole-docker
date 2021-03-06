#!/bin/bash

# This is a script that creates and maintains my pi-hole installation configured in a way that I can easily run it
# through the terminal. Note: as it's evident from the shebang it was developed (and tested) with bash (only).
#
# Author: Andreas Grammenos (ag926@cl.cam.ac.uk)
#
# Last touched: 06/09/2020
#

##### Initialisation and preamble

# pretty functions for log output
function cli_info { echo -e " -- \033[1;32m$1\033[0m" ; }
function cli_info_read { echo -e -n " -- \e[1;32m$1\e[0m" ; }
function cli_warning { echo -e " ** \033[1;33m$1\033[0m" ; }
function cli_warning_read { echo -e -n " ** \e[1;33m$1\e[0m" ; }
function cli_error { echo -e " !! \033[1;31m$1\033[0m" ; }

# check if we have access to docker-compose, jq, and curl
if [[ ! -x "$(command -v docker-compose)" ]] || \
[[ ! -x "$(command -v docker)" ]] || \
[[ ! -x "$(command -v curl)" ]]; then
  cli_error "curl, docker, and docker-compose need to be installed and accessible - cannot continue."
  exit 1
else
  cli_info "curl, docker, and docker-compose appear to be present."
fi

##### Variables and setup

# configure ufw for pihole flag - only configures it if true
UFW_CONF=true
# the local subnet - please configure accordingly
IP_BASE="10.10.1"
UFW_SUBNET="${IP_BASE}.0/24"
# the rule name
UFW_PIHOLE_RULENAME="pihole"

# uninstall flag
UNINSTALL=false

# the resolved related bits
ETC_RESOLV_CONF="/etc/resolv.conf"
# this is the default dns that /etc/resolv.conf points to if dns stub is enabled
RESOLV_DNS_IP="127.0.0.53"

# persistence related directories where the volumes will be mounted
PI_HOLE_BASE="/gavatha/container-data/pihole"
PI_HOLE_CONF=${PI_HOLE_BASE}/etc-pihole
PI_HOLE_DNSMASQ_CONF=${PI_HOLE_BASE}/etc-dnsmasq.d
PI_HOLE_RESOLV_CONF=${PI_HOLE_BASE}/etc-resolv.conf
PI_HOLE_LOG=${PI_HOLE_BASE}/pihole.log
PI_HOLE_FTL_LOG=${PI_HOLE_BASE}/pihole-FTL.log

# ports that the web-interface listens to from localhost (and ufw is configured)
PI_HOLE_ADMIN_HTTP_PORT=19080
PI_HOLE_ADMIN_HTTPS_PORT=19443

# the dns ip array - ordering here matters.
declare -a DNS_IP_ARRAY=(
  "127.0.0.1"
  "1.1.1.1"
  "1.0.0.1"
  "8.8.8.8"
  "8.8.4.4"
)

PI_HOLE_DOCKER_PROJ_NAME="pihole-docker"
PI_HOLE_DOCKER_CONT_NAME="pihole"
PI_HOLE_DOCKERFILE="./pihole.yaml"

PI_HOLE_TZ="Europe/Athens"

# check if we have an environment variable for the password
if [[ -z ${PI_HOLE_ADMIN_PASS} ]]; then
  cli_warning "Potentially using the pre-defined (unsecure) password!"
  PI_HOLE_PW="astrongpassword"
else
  cli_info "Discovered password through a (valid) environment variable"
  PI_HOLE_PW=${PI_HOLE_ADMIN_PASS}
fi

# create the volumes based on the user
USER_UID=$(id -u)
USER_NAME=$(whoami)

#### Installation path (install or remove?)

if [[ ${#} -eq 0 ]]; then
  cli_info "Install procedure selected"
elif [[ ${#} -eq 1 ]]; then
  if [[ "${1}" == "-r" ]]; then
    cli_warning "Uninstall procedure selected"
    UNINSTALL=true
  elif [[ "${1}" == "-i" ]]; then
    cli_warning "Install procedure selected"
  else
    cli_error "invalid command argument provided accepted are only -i and -r."
  fi
else
  cli_error "script arguments need to be zero (for install) or exactly one (for remove)"
  exit 1
fi

##### Check if we need to uninstall

if [[ ${UNINSTALL} = true ]]; then
  cli_warning "Uninstalling pi-hole and removing all data (note: resolved configuration is _not_ restored)..."
  if docker-compose -p ${PI_HOLE_DOCKER_PROJ_NAME} -f ${PI_HOLE_DOCKERFILE} down &&
     docker container prune -f &&
     # remove the data stored by pi-hole
     sudo rm -rf ${PI_HOLE_BASE}; then
    cli_warning "Uninstallation completed successfully!"
    exit 0
  else
    cli_error "There was an error while uninstalling..."
    exit 1
  fi
fi

#### Create the required folders, if not already there.

# create the folders while making the user owner the pihole directory
if ! ret_val=$(sudo mkdir -p {${PI_HOLE_CONF},${PI_HOLE_DNSMASQ_CONF}} && \
sudo chown -R "${USER_NAME}":"${USER_NAME}" ${PI_HOLE_BASE});
then
  cli_error "Could not create pi-hole directories and/or assign permissions - ret val: ${ret_val}."
  exit 1
else
  cli_info "Created required pi-hole directories and assigned permissions for user ${USER_NAME} (id: ${USER_UID})"
fi

# function that prints the resolv.conf for pi-hole
function print_resolv_conf() {
  nameservers=$(printf 'nameserver %s\n' "${DNS_IP_ARRAY[@]}")
  # put it to resolv.conf
  if ! echo "${nameservers}" > ${PI_HOLE_RESOLV_CONF}; then
    return 1
  fi
}

# now run it.
if print_resolv_conf; then
    cli_info "Created pi-hole resolv.conf successfully."
else
  cli_error "Failed to create pi-hole resolv.conf - cannot continue"
  exit 1
fi

##### Prepare the logs

if touch ${PI_HOLE_FTL_LOG} && touch ${PI_HOLE_LOG}; then
  cli_info "Log files for FTL: ${PI_HOLE_FTL_LOG}, pihole: ${PI_HOLE_LOG} created successfully"
else
  cli_error "Failed to create log files for FTL and/or pihole - cannot continue"
  exit 1
fi

##### Prepare the systemd-resolved if needed

if [[ -f ${ETC_RESOLV_CONF} ]] && grep -q ${RESOLV_DNS_IP} ${ETC_RESOLV_CONF}; then
  cli_info "Located resolv.conf with a potential problem; it is mapped to: ${RESOLV_DNS_IP} - trying to fix it. "

  if sudo sed -r -i.orig 's/#?DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf && \
     sudo sh -c "rm ${ETC_RESOLV_CONF} && ln -s /run/systemd/resolve/resolv.conf ${ETC_RESOLV_CONF}"; then
    cli_info "resolved config was fixed successfully."
  else
    cli_error "There was an error while configuring resolved - cannot continue, pihole will probably not work"
    exit 1
  fi
else
  cli_info "resolv.conf appears to be OK - continuing"
fi

##### Create the pihole yaml file

# nifty little function to print the plug IP's in a tidy way
function print_dns_ip() {
  if [[ ${#} -eq 0 ]]; then
    echo -e "# IP of your DNS entries"
  else
    echo -e "The DNS IP's supplied are the following:"
  fi
  printf '      - %s\n' "${DNS_IP_ARRAY[@]}"
}

cli_info "Creating pi-hole services dockerfile..."

echo -e "
# Generated automatically from my pi-hole script
version: \"3.7\"

# More info at https://github.com/pi-hole/docker-pi-hole/ and https://docs.pi-hole.net/
services:
  pihole:
    container_name: ${PI_HOLE_DOCKER_CONT_NAME}
    image: pihole/pihole:latest
    ports:
      # dns ports
      - \"53:53/tcp\"
      - \"53:53/udp\"
      # ftl (dhcp) ports
      #- \"67:67/udp\"
      #- \"67:67/udp\"
      #- \"547:547/udp\"
      # ports for http interface
      - \"${PI_HOLE_ADMIN_HTTP_PORT}:80/tcp\"
      - \"${PI_HOLE_ADMIN_HTTPS_PORT}:443/tcp\"
    environment:
      TZ: ${PI_HOLE_TZ}
      WEBPASSWORD: ${PI_HOLE_PW}
    # Volumes store your data between container upgrades
    volumes:
      - \"${PI_HOLE_CONF}:/etc/pihole\"
      - \"${PI_HOLE_DNSMASQ_CONF}:/etc/dnsmasq.d/\"
      - \"${PI_HOLE_RESOLV_CONF}:/etc/resolv.conf\"
      - \"${PI_HOLE_LOG}:/var/log/pihole.log\"
      - \"${PI_HOLE_FTL_LOG}:/var/log/pihole-FTL.log\"
    dns:
    $(print_dns_ip)
    # Recommended but not required (DHCP needs NET_ADMIN)
    #   https://github.com/pi-hole/docker-pi-hole#note-on-capabilities
    cap_add:
      - NET_ADMIN
    restart: unless-stopped
" > ${PI_HOLE_DOCKERFILE}

cli_info "Created pi-hole services dockerfile successfully..."

##### Pull images

if ! docker-compose -f ${PI_HOLE_DOCKERFILE} pull; then
  cli_error "Failed to pull the required docker images - please ensure network connectivity"
  exit 1
else
  cli_info "Pulled the required docker images successfully"
fi

##### Create the services

# now execute the docker-compose using our newly created yaml
if ! docker-compose -p ${PI_HOLE_DOCKER_PROJ_NAME} -f ./${PI_HOLE_DOCKERFILE} up -d --force-recreate; then
  cli_error "Could not create pi-hole docker service, exiting."
  exit 1
else
  cli_info "Installed pi-hole docker service successfully."
fi

##### Create and register ufw rule for pi-hole

setup_ufw() {
  # optionally, we can configure ufw to open pi-hole to our local network.
  if [[ ${UFW_CONF} = true ]]; then
    cli_info "Configuring ufw firewall is enabled - proceeding"
    # output the rule in the ufw application folder - note if rule already exists, skips creation.
    if [[ -f /etc/ufw/applications.d/${UFW_PIHOLE_RULENAME} ]]; then
      cli_warning "ufw pi-hole rule file already exists - skipping."
    else
        if ! echo -e \
"[${UFW_PIHOLE_RULENAME}]
title=pihole
description=Pi Hole firewall rule
ports=53/tcp|53/udp|19080/tcp|19443/tcp
" | sudo tee -a /etc/ufw/applications.d/${UFW_PIHOLE_RULENAME} > /dev/null; then
        cli_error "Failed to output pi-hole ufw rule successfully - exiting."
        return 1
      else
        cli_info "ufw pi-hole rule file was created successfully!"
      fi
    fi

    # now configure the ufw rule
    if [[ "$(sudo ufw status)" == "Status: inactive" ]]; then
      cli_warning "ufw is inactive we are not adding the rule in it for now."
    elif ! sudo ufw status verbose | grep -q ${UFW_PIHOLE_RULENAME}; then
      cli_info "ufw rule seems to be missing - trying to add!"
      if ! sudo ufw allow from ${UFW_SUBNET} to any app ${UFW_PIHOLE_RULENAME}; then
        cli_error "Failed to configure ufw rule - exiting!"
        return 1
      else
        cli_info "ufw pi-hole rule was applied successfully!"
      fi
    else
      cli_warning "ufw pi-hole rule seems to be registered already - skipping!"
    fi
  fi
}

# call thw wrapper function to setup ufw
if setup_ufw; then
  cli_info "Configured ufw successfully"
else
  cli_error "Encountered an error while registering ufw rule - please do it manually"
fi

#### end

cli_info "Installation script finished successfully!"