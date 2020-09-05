# Pi-Hole with docker (hassle-free)

In my quest for ultimate automation, I needed to update my [pi-hole][1] container image frequently and hassle free.
Additionally, I also desired that I could use this script to set up a pi-hole container in another location at ease 
with as little external reading/tooling as possible - i.e. to this fast and through shell.

To this end, I have created this repo which contains a [script][2] that installs, updates, and removes (if needed) that 
run with minimal effort on debian based installations and bash where `docker`, `docker-compose` and `curl` are present. 
Frankly speaking, this is largely based on the guide provided [here][1], but tailored for my specific purposes 
and wrapped up in a convenient script that I can run.

# Configuring the image

To start, we need to create the `Dockerfile` that create the pi-hole container; the `yaml` I used which is able to that
is shown below.

```yaml 

# Generated automatically from pi-hole script
version: "3.7"

# More info at https://github.com/pi-hole/docker-pi-hole/ and https://docs.pi-hole.net/
services:
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    ports:
      # dns ports
      - "53:53/tcp"
      - "53:53/udp"
      # ftl (dhcp) ports
      #- "67:67/udp"
      #- "547:547/udp"
      # ports for http interface
      - "19080:80/tcp"
      - "19443:443/tcp"
    environment:
      TZ: Europe/Athens
      WEBPASSWORD: astrongpassword
    # Volumes store your data between container upgrades
    volumes:
      - "/usr/pihole/etc-pihole:/etc/pihole"
      - "/usr/pihole/etc-dnsmasq.d:/etc/dnsmasq.d/"
      - "/usr/pihole/etc-resolv.conf:/etc/resolv.conf"
      - "/usr/pihole/pihole.log:/var/log/pihole.log"
    dns:
    # IP of your DNS entries
      - 127.0.0.1
      - 1.1.1.1
    # Recommended but not required (DHCP needs NET_ADMIN)
    #   https://github.com/pi-hole/docker-pi-hole#note-on-capabilities
    cap_add:
      - NET_ADMIN
    restart: unless-stopped
```

In my particular use-case I do not require the DHCP server that is provided by pi-hole, hence I opted to not include 
these ports - specifically, ports `67` and `547` for ipv4 and ipv6 respectively. However, I did want to have a 
web interface hence the `cap_add` includes the `NET_ADMIN` flag as well as the ports `19080` and `19443` for accessing
pi-hole through `http(s)` - you can edit these ports to suit your own use case if you fancy something else.

Another thing that you perhaps might change, if you desire, is the location of the persistent storage - specifically
you have to change the following variables accordingly:

```bash
PI_HOLE_BASE="/usr/pihole"
PI_HOLE_CONF=${PI_HOLE_BASE}/etc-pihole
PI_HOLE_DNSMASQ_CONF=${PI_HOLE_BASE}/etc-dnsmasq.d
PI_HOLE_RESOLV_CONF=${PI_HOLE_BASE}/etc-resolv.conf
PI_HOLE_LOG=${PI_HOLE_BASE}/pihole.log
```

**Note**: please change the web password to something familiar or you are comfortable with - specifically you need to
change this variable:

```bash
PI_HOLE_PW="astrongpassword"
```

# System resolved service

In some distributions there is already a dns cache stub resolver which is bound on port `53` that pi-hole will try to 
use - as such installation will fail; this issue is well documented. To this end I've created a function that provisions
 the resolved service to disable the dns caching mechanism as well as use the dns resolver to use the one provided by 
 our DHCP. It has to be noted that this is only performed if needed and not every time. The function that performs the 
 steps outlined follows.
 
```bash
if [[ -f ${ETC_RESOLV_CONF} ]] && grep -q ${RESOLV_DNS_IP} ${ETC_RESOLV_CONF}; then
  cli_info "Located resolv.conf with a problem; it is mapped to: ${RESOLV_DNS_IP}"

  if sudo sed -r -i.orig \
     's/#?DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf && \
     sudo sh -c "rm ${ETC_RESOLV_CONF} && \
     ln -s /run/systemd/resolve/resolv.conf ${ETC_RESOLV_CONF}"; then
    cli_info "resolved config was fixed successfully."
  else
    cli_error "There was an error while configuring resolved - cannot continue"
    exit 1
  fi
else
  cli_info "resolv.conf appears to be OK - continuing"
fi
``` 

# Configuring ufw

In order to make pi-hole accessible to our local network we need to configure `ufw` accordingly, hence - optionally 
but enabled by default - we can run the following function do perform this for us.

**Note** for this to work as intended you need to have your IP subnet set by setting this variable:

```bash
# the local subnet - please configure accordingly
IP_BASE="10.10.1"
UFW_SUBNET="${IP_BASE}.0/24"
```

```bash
setup_ufw() {
  # optionally, we can configure ufw to open grafana to our local network.
  if [[ ${UFW_CONF} = true ]]; then
    cli_info "Configuring ufw firewall is enabled - proceeding"
    # output the rule in the ufw application folder - note if rule already exists, skips creation.
    if [[ -f /etc/ufw/applications.d/${UFW_GRAF_RULENAME} ]]; then
      cli_warning "ufw grafana rule file already exists - skipping."
    else
        if ! echo -e \
"[${UFW_PIHOLE_RULENAME}]
title=pihole
description=Pi Hole firewall rule
ports=53/tcp|53/udp|19080/tcp|19443/tcp
" | sudo tee -a /etc/ufw/applications.d/${UFW_PIHOLE_RULENAME} > /dev/null; then
        cli_error "Failed to output grafana ufw rule successfully - exiting."
        return 1
      else
        cli_info "ufw grafana rule file was created successfully!"
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
```

# Putting everything together

The full script can be found [here][2] and you can use it to compile, build, and launch pi-hole as a docker service 
on your own server/machine. Concretely, to run the script you can do the following:

```bash
# clone this repository
git clone https://github.com/andylamp/pihole-docker
# enter this directory
cd pihole-docker
# maybe you need to chmod +x
chmod +x ./pihole-docker.sh
# then, run the script to install everything
./pihole-docker.sh
# alternatively you can use
./pihole-docker.sh -i
```

Conversely, to uninstall everything after installation you can do the following:

```bash
# assuming you are in the cloned repo directory
./pihole-docker.sh -r
```

That's it!

[1]: https://hub.docker.com/r/pihole/pihole/
[2]: ./pihole-docker.sh