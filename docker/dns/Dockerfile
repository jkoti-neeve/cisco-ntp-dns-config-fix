# Minimal dnsmasq — DNS + DHCP server for the bench-test rig.
#
# Pinned to alpine:3.20 for build reproducibility. dnsmasq.conf and
# seed.hosts are bind-mounted at runtime from out/render/dns/ (rendered
# by scripts/render-config.sh) so the same image works for every device.
#
# Why dnsmasq instead of CoreDNS: the device under test (Neeve 2484)
# turned out to be a DHCP client on its WAN port, so the rig needs DHCP.
# dnsmasq serves DNS + DHCP from a single process — simpler than running
# CoreDNS + isc-dhcp-server side-by-side. Q-IP closed in session
# 2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.
FROM alpine:3.20

RUN apk add --no-cache dnsmasq

# -k = keep in foreground (no fork). log-facility=- in dnsmasq.conf
# sends logs to stdout so `docker compose logs dns` captures them.
ENTRYPOINT ["dnsmasq", "-k", "--conf-file=/etc/dnsmasq.conf"]
