#!/usr/bin/env bash
# A TrueNAS appliance for this job, booted under qemu inside the runner.
#
# The runner's pool attaches the appliance's disk ("disks" in the pool's
# extra specs: a clone of truenas_appliance:<channel> on the box), and the
# appliance lives and dies with the runner: nothing to claim from anyone,
# nothing to release, nothing to leak. See iXsystems/github-truenas-runner's
# docs/e2e-appliances.md.
#
#   appliance.sh start            boot it, wait for its API, give it this
#                                 claim's admin password, and snapshot it
#                                 as the baseline; KEY=value on stdout
#   appliance.sh snapshot <name>  save the running appliance, memory and
#                                 disks, as <name>
#   appliance.sh revert <name>    back to <name>, in seconds, no boot, with
#                                 the guest's clock set to now
#   appliance.sh probe [baseline] change it, revert, check the change went
#   appliance.sh boot-report     where the boot's time went: systemd's
#                                 critical chain and slowest units, and
#                                 middleware's start, over ssh. Leaves ssh
#                                 on, with a key and sudo for the admin:
#                                 revert afterwards if that matters
#   appliance.sh call <method> [params...]
#                                 a middleware API call, as the admin, its
#                                 result as JSON on stdout
#   appliance.sh snapshots        the names there are
#   appliance.sh console [lines]  the end of its serial console
#   appliance.sh stop             quit it, and take its bridge network down
#
# Settings, environment variables, all optional:
#
#   APPLIANCE_DISK        the appliance's disk: a device or a qcow2/raw file
#                         (default: the disk the pool attached, found by
#                         attached_disk)
#   APPLIANCE_DIR         its state: overlay, data disks, sockets, console
#                         (default $RUNNER_TEMP/truenas-appliance)
#   APPLIANCE_MEMORY_MB   6144       APPLIANCE_VCPUS        4
#   APPLIANCE_DATA_DISKS  10         APPLIANCE_DATA_DISK_GB 10 (sparse)
#   APPLIANCE_EXTRA_DISK_GB  more sparse disks after those, one per size in
#                         GB, space-separated: "32", "12 12 15" (default none)
#   APPLIANCE_SPARE_NICS  0: NICs after the one the API is reached on, each
#                         alone on a qemu hub of its own, so no DHCP, no
#                         route and no peer: for a suite to reconfigure
#                         without cutting itself off
#   APPLIANCE_NETWORK     user: qemu's user-mode network, the guest behind
#                         its NAT and its ports forwarded to this machine's
#                         loopback, on the ports below. bridge: the guest
#                         on a bridge with this machine (bridge_up), on its
#                         own address and its real ports, reachable from
#                         here, from containers and from a browser; needs
#                         passwordless sudo
#   APPLIANCE_HTTP_PORT   8080       APPLIANCE_HTTPS_PORT   8443
#   APPLIANCE_SSH_PORT    2222       APPLIANCE_SSH          false
#                         (the ports forwarded with user; bridge has none)
#   APPLIANCE_BASELINE    fresh-install: the snapshot start takes; empty
#                         takes none
#   APPLIANCE_PASSWORD    the claim's admin password (default: generated)
#   APPLIANCE_BOOT_TIMEOUT 900 seconds
#   APPLIANCE_ACCEL       kvm; tcg runs without KVM, too slowly for
#                         anything but testing this script
#
# start prints TN_PROFILE, TN_HOST (host:https port), TN_HOST_HTTP,
# TN_USERNAME, TN_PASSWORD, TN_DOMAIN, TN_BASELINE (the suite's contract,
# as the lab's claim action gives it, less its TN_GUEST_ISO), TN_SSH when
# APPLIANCE_SSH is true, TN_SPARE_NICS (the spare NICs' MAC addresses,
# space-separated) when there are any, TN_NETWORK (user or bridge),
# TN_RUNNER_IP (where the guest reaches this machine), TN_APPLIANCE_IP
# with bridge, and what it measured: APPLIANCE_BOOT_SECONDS,
# APPLIANCE_SNAPSHOT_SECONDS.

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(realpath "$0")")/lib.sh"

DIR="${APPLIANCE_DIR:-${RUNNER_TEMP:-/tmp}/truenas-appliance}"
QMP="$DIR/qmp.sock"
# The guest agent's channel: TrueNAS ships qemu-ga, which starts once this
# port (org.qemu.guest_agent.0) appears. revert sets the clock through it.
QGA="$DIR/qga.sock"
STATE="$DIR/state.env"

# The bridge network (APPLIANCE_NETWORK=bridge): this machine at .1 and the
# appliance at .10, by its MAC. Not ha.sh's 10.231.0.0/24, Docker's
# 172.17.0.0/16 or compose's networks. The MAC is fixed so that the address
# is the same after a revert; the spare NICs' are e0:01 and up.
BR=tnapp-br
TAP=tnapp-tap
BR_NET=10.232.0
BR_RUNNER_IP=$BR_NET.1
BR_APPLIANCE_IP=$BR_NET.10
BR_MAC=52:54:00:e2:e0:00
# What bridge_up changed, written before it changes anything: bridge_down
# reads it, even after a start that failed halfway.
NETSTATE="$DIR/network.env"
# The rules bridge_up adds, as "table chain rule...". Docker loads
# br_netfilter and drops FORWARD by default, which would drop the
# appliance's traffic to containers and beyond this machine, and theirs to
# it; the NAT takes it beyond this machine, as qemu's user-mode NAT does.
BR_RULES=(
    "filter FORWARD -i $BR -j ACCEPT"
    "filter FORWARD -o $BR -j ACCEPT"
    "nat POSTROUTING -s $BR_NET.0/24 ! -o $BR -j MASQUERADE"
)

hmp() { "${TNCTL[@]}" hmp "$QMP" "$*"; }
# resume: a failed loadvm leaves the VM paused, and later loadvms leave it
# so, however they go; cont is a no-op on one that runs.
resume() { "${TNCTL[@]}" qmp "$QMP" cont >/dev/null; }
# addr <guest port>: host:port where this machine reaches that port of the
# appliance: its own address on the bridge, or qemu's forward of it.
addr() {
    if [ "${APPLIANCE_NETWORK:-user}" = bridge ]; then
        echo "$BR_APPLIANCE_IP:$1"
        return
    fi
    case "$1" in
    80)  echo "127.0.0.1:${APPLIANCE_HTTP_PORT:-8080}" ;;
    443) echo "127.0.0.1:${APPLIANCE_HTTPS_PORT:-8443}" ;;
    22)  echo "127.0.0.1:${APPLIANCE_SSH_PORT:-2222}" ;;
    esac
}
url() { echo "ws://$(addr 80)"; }
running() { [ -f "$DIR/qemu.pid" ] && kill -0 "$(cat "$DIR/qemu.pid")" 2>/dev/null; }
# shellcheck source=/dev/null
state() { [ -r "$STATE" ] || die "no appliance started here ($STATE)"; . "$STATE"; }

# attached_disk: the appliance disk the runner's pool attached. By its
# serial when the box kept the one the provider gave it; TrueNAS gives
# every VM disk a random serial of its own instead, so otherwise by what is
# on it: the one disk, not the one / is on, that holds a ZFS pool named
# boot-pool (a TrueNAS install).
attached_disk() {
    local serial=/dev/disk/by-id/virtio-truenas_appliance
    [ -e "$serial" ] && { realpath "$serial"; return; }
    lsblk -J -p -o NAME,PKNAME,FSTYPE,LABEL,MOUNTPOINT | python3 -c '
import json, sys
devs = []
def walk(ds):
    for d in ds:
        devs.append(d)
        walk(d.get("children") or [])
walk(json.load(sys.stdin)["blockdevices"])
root = {d["pkname"] for d in devs if d.get("mountpoint") == "/"}
found = sorted({d["pkname"] for d in devs
                if d.get("fstype") == "zfs_member" and d.get("label") == "boot-pool"
                and d.get("pkname") and d["pkname"] not in root})
if len(found) != 1:
    sys.exit("found %d disks with a TrueNAS boot-pool: %s" % (len(found), " ".join(found) or "none"))
print(found[0])
'
}

# bridge_up: the bridge network. A bridge with this machine on it, a tap
# for qemu (this user's, so qemu runs without sudo), BR_RULES, and dnsmasq
# giving the appliance's MAC its address and answering its DNS.
bridge_up() {
    say "network: bridge $BR, this machine at $BR_RUNNER_IP, the appliance at $BR_APPLIANCE_IP"
    local forward rule r
    forward="$(cat /proc/sys/net/ipv4/ip_forward)"
    echo "BR_FORWARD_WAS=$forward" > "$NETSTATE"
    sudo -n ip link add "$BR" type bridge
    sudo -n ip addr add "$BR_RUNNER_IP/24" dev "$BR"
    sudo -n ip link set "$BR" up
    sudo -n ip tuntap add dev "$TAP" mode tap user "$(id -u)"
    sudo -n ip link set "$TAP" master "$BR" up
    for rule in "${BR_RULES[@]}"; do
        read -r -a r <<< "$rule"
        sudo -n iptables -t "${r[0]}" -I "${r[1]}" "${r[@]:2}"
    done
    # Docker turns it on; a runner without Docker may not have.
    if [ "$forward" != 1 ]; then
        sudo -n sysctl -q -w net.ipv4.ip_forward=1
    fi
    # DNS as well as DHCP, unlike ha.sh's: the appliance needs a resolver
    # for NTP and for what middleware looks up as it starts, and this
    # machine's may be a stub on its loopback (systemd-resolved's
    # 127.0.0.53) that the appliance cannot reach. dnsmasq forwards to
    # whatever /etc/resolv.conf names, and its offer names it as the router
    # and the DNS server; --no-hosts keeps this machine's /etc/hosts out of
    # its answers. Static: it answers this MAC alone. The lease never ends,
    # so a revert, which restores the guest's lease with its memory and
    # moves its clock on, never finds it expired.
    sudo -n dnsmasq --interface="$BR" --bind-interfaces --except-interface=lo --no-hosts \
        --dhcp-range="$BR_APPLIANCE_IP,static" --dhcp-host="$BR_MAC,$BR_APPLIANCE_IP,infinite" \
        --dhcp-leasefile="$DIR/dnsmasq.leases" --pid-file="$DIR/dnsmasq.pid" \
        --log-dhcp --log-facility="$DIR/dnsmasq.log"
}

# bridge_down: undo bridge_up, each part only if it is there, so that a
# self-hosted runner's next start finds nothing of this one. Nothing to do
# for a user-mode appliance.
bridge_down() {
    if [ ! -f "$NETSTATE" ] && ! ip link show "$BR" >/dev/null 2>&1; then
        return 0
    fi
    say "network: taking $BR down"
    local BR_FORWARD_WAS=1 rule r
    # shellcheck source=/dev/null
    if [ -r "$NETSTATE" ]; then . "$NETSTATE"; fi
    if [ -s "$DIR/dnsmasq.pid" ]; then
        sudo -n kill "$(cat "$DIR/dnsmasq.pid")" 2>/dev/null || true
    fi
    for rule in "${BR_RULES[@]}"; do
        read -r -a r <<< "$rule"
        while sudo -n iptables -t "${r[0]}" -C "${r[1]}" "${r[@]:2}" 2>/dev/null; do
            sudo -n iptables -t "${r[0]}" -D "${r[1]}" "${r[@]:2}"
        done
    done
    if ip link show "$TAP" >/dev/null 2>&1; then sudo -n ip link del "$TAP"; fi
    if ip link show "$BR" >/dev/null 2>&1; then sudo -n ip link del "$BR"; fi
    if [ "$BR_FORWARD_WAS" != 1 ]; then
        sudo -n sysctl -q -w net.ipv4.ip_forward="$BR_FORWARD_WAS"
    fi
    rm -f "$NETSTATE"
}

start() {
    local disk="${APPLIANCE_DISK:-}"
    local memory="${APPLIANCE_MEMORY_MB:-6144}" vcpus="${APPLIANCE_VCPUS:-4}"
    local ndata="${APPLIANCE_DATA_DISKS:-10}" datagb="${APPLIANCE_DATA_DISK_GB:-10}"
    local extragb=()
    read -r -a extragb <<< "${APPLIANCE_EXTRA_DISK_GB:-}"
    local nspare="${APPLIANCE_SPARE_NICS:-0}"
    local http="${APPLIANCE_HTTP_PORT:-8080}" https="${APPLIANCE_HTTPS_PORT:-8443}" sshp="${APPLIANCE_SSH_PORT:-2222}"
    local baseline="${APPLIANCE_BASELINE-fresh-install}"
    local password="${APPLIANCE_PASSWORD:-$(head -c 15 /dev/urandom | base64 | tr -d '/+=')}"
    local name="appliance-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}"

    running && die "an appliance is running already ($DIR)"
    APPLIANCE_NETWORK="${APPLIANCE_NETWORK:-user}"
    case "$APPLIANCE_NETWORK" in
    user) ;;
    bridge)
        if ip link show "$BR" >/dev/null 2>&1; then
            die "$BR exists already: an earlier appliance's network is still up, and truenas-appliance stop takes it down"
        fi
        sudo -n true 2>/dev/null || die "APPLIANCE_NETWORK=bridge needs passwordless sudo, for the bridge, the tap, iptables and dnsmasq"
        needs dnsmasq dnsmasq-base iptables iptables
        ;;
    *)  die "APPLIANCE_NETWORK: \"$APPLIANCE_NETWORK\" is not user or bridge" ;;
    esac
    local gb
    for gb in "${extragb[@]}"; do
        [[ "$gb" =~ ^[1-9][0-9]*$ ]] || die "APPLIANCE_EXTRA_DISK_GB: \"$gb\" is not a whole number of GB"
    done
    [[ "$nspare" =~ ^[0-9]$ ]] || die "APPLIANCE_SPARE_NICS: \"$nspare\" is not a number of NICs from 0 to 9"
    needs qemu-system-x86_64 qemu-system-x86 qemu-img qemu-utils python3 python3
    ovmf
    local accel="${APPLIANCE_ACCEL:-kvm}" cpu=host
    if [ "$accel" = kvm ]; then
        [ -w /dev/kvm ] || die "no /dev/kvm this user can use: the runner needs nested virtualization (cpu_mode HOST-PASSTHROUGH) and to be in the kvm group"
    else
        cpu=max
    fi
    if [ -z "$disk" ] && ! disk="$(attached_disk)"; then
        echo "appliance: no appliance disk attached to this runner. Its disks:" >&2
        lsblk -p -o NAME,SIZE,SERIAL,FSTYPE,LABEL,MOUNTPOINT >&2 || true
        die "give the runner's pool {\"disks\": [\"truenas_appliance:nightly\"]} in its extra specs, or set APPLIANCE_DISK"
    fi
    [ -e "$disk" ] || die "no appliance disk at $disk"
    disk="$(realpath "$disk")"
    # Read only: the appliance writes to an overlay of it.
    if [ ! -r "$disk" ]; then
        sudo -n chown "$(id -u)" "$disk" || die "$disk is not readable here, and sudo cannot change that"
    fi
    local format=raw
    [ -f "$disk" ] && format="$(qemu-img info --output=json "$disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')"

    rm -rf "$DIR"
    mkdir -p "$DIR"
    qemu-img create -q -f qcow2 -F "$format" -b "$disk" "$DIR/os.qcow2"
    vars_qcow2 "$DIR/vars.qcow2"
    local drives=() i
    for i in $(seq 1 "$ndata"); do
        qemu-img create -q -f qcow2 "$DIR/data$i.qcow2" "${datagb}G"
        drives+=(-drive "file=$DIR/data$i.qcow2,if=none,id=data$i,format=qcow2,discard=unmap"
                 -device "virtio-blk-pci,drive=data$i,serial=data$i")
    done
    # After the data disks, so a suite that takes the first unused disks
    # still gets data disks, all of one size.
    local nextra=0
    for gb in "${extragb[@]}"; do
        nextra=$((nextra + 1))
        qemu-img create -q -f qcow2 "$DIR/extra$nextra.qcow2" "${gb}G"
        drives+=(-drive "file=$DIR/extra$nextra.qcow2,if=none,id=extra$nextra,format=qcow2,discard=unmap"
                 -device "virtio-blk-pci,drive=extra$nextra,serial=extra$nextra")
    done
    local extrasaid=""
    if [ "$nextra" -gt 0 ]; then
        extrasaid=", and $nextra more of $(printf '%sG ' "${extragb[@]}")"
        extrasaid="${extrasaid% }"
    fi
    # After the NIC the API is reached on, so that one keeps its PCI slot,
    # and with it its name, whatever the count. Each on a hub with no other
    # port: its link is up, and nothing ever answers on it. qemu warns
    # "hub N is not connected to host network" for each, which is the
    # point. The MACs are fixed, for a suite to tell these NICs apart by.
    local nics=() spare_macs=()
    for i in $(seq 1 "$nspare"); do
        spare_macs+=("52:54:00:e2:e0:0$i")
        nics+=(-netdev "hubport,id=spare$i,hubid=$i"
               -device "virtio-net-pci,netdev=spare$i,mac=52:54:00:e2:e0:0$i")
    done
    local nicssaid=""
    if [ "$nspare" -eq 1 ]; then
        nicssaid=", 1 spare NIC"
    elif [ "$nspare" -gt 1 ]; then
        nicssaid=", $nspare spare NICs"
    fi
    # -nic either way, so the NIC is made the same way, keeps its PCI slot,
    # and with it its name in the guest.
    local nic
    if [ "$APPLIANCE_NETWORK" = bridge ]; then
        bridge_up
        nic="tap,ifname=$TAP,script=no,downscript=no,model=virtio-net-pci,mac=$BR_MAC"
    else
        nic="user,model=virtio-net-pci$(hostfwd 80 "$http")$(hostfwd 443 "$https")$(hostfwd 22 "$sshp")"
    fi

    local booted t0
    say "booting $disk as $name: ${memory} MB, $vcpus vCPUs, $ndata data disks of ${datagb}G$extrasaid$nicssaid"
    t0=$(date +%s.%N)
    qemu-system-x86_64 -name "$name" -machine "q35,accel=$accel" -cpu "$cpu" -smp "$vcpus" -m "$memory" \
        -smbios "type=1,serial=$name" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=qcow2,file=$DIR/vars.qcow2" \
        -drive "file=$DIR/os.qcow2,if=none,id=os,format=qcow2,discard=unmap" \
        -device "virtio-blk-pci,drive=os,serial=os,bootindex=0" \
        "${drives[@]}" \
        -nic "$nic" \
        "${nics[@]}" \
        -device virtio-rng-pci \
        -device virtio-serial-pci,id=vser0 \
        -chardev "socket,id=qga0,path=$QGA,server=on,wait=off" \
        -device "virtserialport,bus=vser0.0,chardev=qga0,name=org.qemu.guest_agent.0" \
        -qmp "unix:$QMP,server=on,wait=off" \
        -display none -serial "file:$DIR/console.log" \
        -daemonize -pidfile "$DIR/qemu.pid"
    # The console, each line with the seconds since qemu started, for as
    # long as qemu runs: the boot's milestones below are on the same clock.
    nohup "${TNCTL[@]}" tail-ts "$DIR/console.log" "$DIR/console.ts.log" \
        --since "$t0" --pid "$(cat "$DIR/qemu.pid")" >/dev/null 2>&1 &
    skip_grub "$DIR/console.log" "$QMP"

    if ! booted=$("${TNCTL[@]}" wait "$(url)" "$APPLIANCE_USER" "$APPLIANCE_TEMPLATE_PASSWORD" \
            --since "$t0" --timeout "${APPLIANCE_BOOT_TIMEOUT:-900}"); then
        say "--- its console, last 60 lines"
        console 60 >&2 || true
        if [ "$APPLIANCE_NETWORK" = bridge ]; then
            say "--- dnsmasq"
            cat "$DIR/dnsmasq.log" >&2 2>/dev/null || true
        fi
        die "the appliance's API never came up"
    fi
    say "API up ${booted}s after qemu started"
    "${TNCTL[@]}" rotate "$(url)" "$APPLIANCE_USER" "$APPLIANCE_TEMPLATE_PASSWORD" "$password"
    if [ "${APPLIANCE_SSH:-false}" = true ]; then
        "${TNCTL[@]}" enable-ssh "$(url)" "$APPLIANCE_USER" "$password"
        say "ssh on $(addr 22)"
    fi
    {
        echo "APPLIANCE_PASSWORD_NOW=$(printf %q "$password")"
        echo "APPLIANCE_NETWORK=$APPLIANCE_NETWORK"
        echo "APPLIANCE_HTTP_PORT=$http"
        echo "APPLIANCE_SSH_PORT=$sshp"
    } > "$STATE"

    local snapped=""
    if [ -n "$baseline" ]; then
        local s0
        s0=$(date +%s.%N)
        hmp savevm "$baseline" >&2
        snapped=$(awk -v a="$s0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
        say "snapshot $baseline taken in ${snapped}s"
    fi

    # TN_RUNNER_IP: where the guest reaches this machine. Under qemu's NAT
    # that is 10.0.2.2, which qemu maps to this machine's loopback; on the
    # bridge, what listens on the bridge's address or on every address.
    local runner_ip=10.0.2.2
    [ "$APPLIANCE_NETWORK" = bridge ] && runner_ip=$BR_RUNNER_IP
    cat <<EOF
TN_PROFILE=shipped
TN_HOST=$(addr 443)
TN_HOST_HTTP=$(addr 80)
TN_USERNAME=$APPLIANCE_USER
TN_PASSWORD=$password
TN_DOMAIN=$name
TN_BASELINE=${baseline:-none}
TN_NETWORK=$APPLIANCE_NETWORK
TN_RUNNER_IP=$runner_ip
APPLIANCE_BOOT_SECONDS=$booted
APPLIANCE_SNAPSHOT_SECONDS=$snapped
EOF
    if [ "$APPLIANCE_NETWORK" = bridge ]; then
        echo "TN_APPLIANCE_IP=$BR_APPLIANCE_IP"
    fi
    # Only when it is there to use: a suite may take TN_SSH being set to
    # mean it can ssh in.
    if [ "${APPLIANCE_SSH:-false}" = true ]; then
        echo "TN_SSH=$(addr 22)"
    fi
    if [ "$nspare" -gt 0 ]; then
        echo "TN_SPARE_NICS=${spare_macs[*]}"
    fi
}

snapshot() {
    local name="${1:?snapshot <name>}"
    running || die "no appliance running"
    local rc=0
    hmp savevm "$name" >&2 || rc=$?
    resume
    return "$rc"
}

# revert: loadvm restores memory and disks as they were, so the API is up
# the moment it returns; its connections from before are gone. It restores
# the clock as well, minutes behind by now, so the guest agent sets it to
# this machine's: a suite's two-factor codes, tokens and timestamps are
# made on that clock. A clock left behind is a warning, not a failed revert.
revert() {
    local name="${1:?revert <name>}"
    running || die "no appliance running"
    state
    local t0
    t0=$(date +%s.%N)
    if ! hmp loadvm "$name" >&2; then
        resume
        die "no snapshot $name to revert to; the appliance runs on as it was"
    fi
    resume
    if ! "${TNCTL[@]}" set-time "$QGA"; then
        echo "::warning::truenas-appliance revert: the appliance's clock is the snapshot's, behind this machine's" >&2
    fi
    "${TNCTL[@]}" wait "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" --timeout 120 >/dev/null
    awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f\n", b - a}'
}

# console [lines]: the end of its serial console, timed when it can be.
console() {
    if [ -s "$DIR/console.ts.log" ]; then
        tail -n "${1:-100}" "$DIR/console.ts.log"
    else
        tail -n "${1:-100}" "$DIR/console.log"
    fi
}

# boot_report: where the boot's time went, from inside: systemd's own
# account of it, the chain of units middleware waited on, the slowest
# units, and middleware's log of its own start. Over ssh, as the admin with
# a key made here and sudo; those, and ssh, stay on afterwards.
boot_report() {
    running || die "no appliance running"
    state
    needs ssh openssh-client ssh-keygen openssh-client
    local key="$DIR/report_key"
    [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C appliance-boot-report -f "$key"
    "${TNCTL[@]}" enable-ssh "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" --pubkey "$(cat "$key.pub")" >&2
    local at
    at="$(addr 22)"
    local -a ssh_
    ssh_=(ssh -i "$key" -p "${at##*:}" -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          "$APPLIANCE_USER@${at%:*}")
    local i
    for i in $(seq 1 30); do
        "${ssh_[@]}" true 2>/dev/null && break
        [ "$i" = 30 ] && die "no ssh into the appliance on $at"
        sleep 2
    done
    "${ssh_[@]}" 'bash -s' <<'REPORT'
section() { printf '\n=== %s\n' "$*"; }
cpu_seconds() {
    awk -v hz="$(getconf CLK_TCK)" '/^cpu / {printf "user %.0f  system %.0f  idle %.0f  iowait %.0f  steal %.0f\n", ($2 + $3) / hz, $4 / hz, $5 / hz, $6 / hz, $9 / hz}' /proc/stat
}
section "systemd-analyze"
systemd-analyze || true
section "the critical chain to middlewared"
systemd-analyze critical-chain middlewared.service --no-pager || true
section "the critical chain to the default target"
systemd-analyze critical-chain --no-pager || true
section "the 30 slowest units"
systemd-analyze blame --no-pager | head -n 30 || true
section "middlewared's unit, from the journal"
sudo -n journalctl -b -o short-monotonic -u middlewared --no-pager | head -n 40 || true
section "middlewared's log of this boot's start"
sudo -n awk '/ - Starting TrueNAS/ {n = 0; delete buf} {buf[++n] = $0} END {for (i = 1; i <= n && i <= 120; i++) print buf[i]}' /var/log/middlewared.log || true
section "the journal's pauses over a second (kernel, initrd, userspace)"
sudo -n journalctl -b -o short-monotonic --no-pager |
    awk -F'[][]' 'NF > 2 {t = $2 + 0; if (seen && t - p >= 1) printf "%6.1fs before [%8.3f] %s\n", t - p, t, substr($3, 1, 150); p = t; seen = 1}' || true
section "the kernel's own pauses over half a second"
sudo -n dmesg |
    awk -F'[][]' 'NF > 2 {t = $2 + 0; if (seen && t - p >= 0.5) printf "%6.1fs before [%8.3f] %s\n", t - p, t, substr($3, 1, 150); p = t; seen = 1}' || true
section "the kernel's command line"
cat /proc/cmdline
section "where the guest's CPU time went since boot, in seconds"
cpu_seconds
section "the guest's clocksource"
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
REPORT
    echo
    echo "=== the runner the appliance runs on"
    echo "$(nproc) vCPUs, load $(cut -d' ' -f1-3 /proc/loadavg), $(free -m | awk '/^Mem:/ {print $2 " MB, " $7 " MB available"}')"
    echo "Its CPU time since it booted, in seconds (steal is time its own host held its vCPUs back):"
    cpu_seconds
}

# cpu_seconds: /proc/stat's CPU line in seconds. Steal is time the
# hypervisor kept this machine's vCPUs from running; iowait is time spent
# waiting for disks. Defined here and in the report's script on the
# appliance alike.
cpu_seconds() {
    awk -v hz="$(getconf CLK_TCK)" '/^cpu / {printf "user %.0f  system %.0f  idle %.0f  iowait %.0f  steal %.0f\n", ($2 + $3) / hz, $4 / hz, $5 / hz, $6 / hz, $9 / hz}' /proc/stat
}

# probe <baseline>: that revert works and what it costs. A group is made
# over the API, the appliance reverted to <baseline>, and the group must
# be gone; KEY=value on stdout.
probe() {
    local baseline="${1:-fresh-install}" took left skew
    state
    call() { "${TNCTL[@]}" call "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" "$@"; }
    call group.create '{"name": "e2e_probe"}' >/dev/null
    [ "$(call group.query '[["name", "=", "e2e_probe"]]' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1 ] \
        || die "probe: the group made over the API is not there"
    took="$(revert "$baseline")"
    left="$(call group.query '[["name", "=", "e2e_probe"]]' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    [ "$left" = 0 ] || die "probe: after reverting to $baseline the group is still there"
    # The clock as middleware reads it ({"$date": ms} on the wire), against this machine's.
    # shellcheck disable=SC2016 # $date is the key's name, not a shell variable
    skew="$(call system.info | python3 -c '
import json, sys, time
from datetime import datetime
d = json.load(sys.stdin)["datetime"]
ms = d["$date"] if isinstance(d, dict) else datetime.fromisoformat(d).timestamp() * 1000
print(f"{ms / 1000 - time.time():.1f}")')"
    python3 -c "import sys; sys.exit(abs(float(sys.argv[1])) > 5)" "$skew" \
        || die "probe: after reverting to $baseline the appliance's clock is ${skew}s off"
    say "revert to $baseline took ${took}s, undid the change, and left the clock ${skew}s off"
    echo "APPLIANCE_REVERT_SECONDS=$took"
}

# stop: quit qemu, then take down the bridge network, if there is one: the
# tap is qemu's until it exits.
stop() {
    if running; then
        local pid i
        pid="$(cat "$DIR/qemu.pid")"
        "${TNCTL[@]}" qmp "$QMP" quit >/dev/null || true
        for i in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
    fi
    bridge_down
}

case "${1:-}" in
start)     start ;;
call)      shift; [ $# -gt 0 ] || die "call <method> [params...]"; state
           "${TNCTL[@]}" call "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" "$@" ;;
probe)     shift; probe "$@" ;;
snapshot)  shift; snapshot "$@" ;;
revert)    shift; revert "$@" ;;
snapshots) running || die "no appliance running"; hmp info snapshots ;;
console)   console "${2:-100}" ;;
boot-report) boot_report ;;
stop)      stop ;;
*)         die "usage: appliance.sh start | snapshot <name> | revert <name> | probe [baseline] | call <method> [params...] | boot-report | snapshots | console [lines] | stop" ;;
esac
