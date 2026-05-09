# Minimal chrony NTP server.
#
# Pinned to alpine:3.20 for build reproducibility. chrony.conf is
# bind-mounted at runtime from out/render/ntp/chrony.conf (rendered by
# scripts/render-config.sh) so the same image works for every device
# the rig is pointed at.
FROM alpine:3.20

RUN apk add --no-cache chrony && mkdir -p /var/log/chrony /var/run/chrony

# Run chronyd in the foreground (-d) reading the mounted config.
# Wipe any stale pidfile first: a previous crash can leave
# /var/run/chrony/chronyd.pid behind, which makes the next chronyd
# refuse to start ("Another chronyd may already be running").
ENTRYPOINT ["sh", "-c", "rm -f /var/run/chrony/chronyd.pid; exec chronyd -d -f /etc/chrony/chrony.conf"]
