#!/usr/bin/env bash
# A TrueNAS HA pair for this job: two appliances booted under qemu inside
# the runner, wired the way middleware needs an HA pair's hardware to be,
# and handed over unconfigured. Licensing it, giving it a VIP, a pool and
# failover is the suite's to do: that is what an HA suite tests.
#
# The runner's pool attaches two appliance disks ("disks" in the pool's
# extra specs: truenas_appliance:<channel> twice), and the pair lives and
# dies with the runner, as appliance.sh's single appliance does.
#
#   ha.sh start                   boot both, wait for both APIs, give both
#                                 this job's admin password and node B ids
#                                 of its own; KEY=value on stdout
#   ha.sh call <a|b> <method> [params...]
#                                 a middleware API call to one node, as the
#                                 admin. A standby refuses logins (it
#                                 answers REDIRECT to the VIP): reach it
#                                 through the other node, failover.call_remote
#   ha.sh ssh <a|b> [command]     a shell on one node, as the admin, with sudo
#   ha.sh console <a|b> [lines]   the end of one node's serial console
#   ha.sh stop
#
# What middleware needs of the hardware, and how this provides it:
#
#   HA identity    SMBIOS manufacturer QEMU and a serial ending _c1 / _c2:
#                  middleware reports IXKVM, node A or B by the last digit
#                  (utils/hardware/detect.py).
#   heartbeat      a NIC the guest names enp1s0 (hard-coded for IXKVM in
#                  failover_/internal_interface.py): the only device behind
#                  a PCIe root port, so on bus 1, slot 0. A bridge of its
#                  own, shared by the two nodes and nothing else.
#   data network   a second bridge, the runner at .1, dnsmasq handing each
#                  node a fixed address by MAC. The VIP is left free for
#                  the suite to configure.
#   shared disks   LIO LUNs on the runner, shown to each node through a
#                  loopback target of its own and attached as scsi-block,
#                  which passes SCSI persistent reservations through:
#                  fenced needs them, and pool.create needs fenced.
#   unique nodes   the two OS disks are clones of one image, so both nodes
#                  boot with one /etc/machine-id, and fenced keys its
#                  reservations by it. Node B gets a new one (and a new
#                  hostid) and reboots, before anything is licensed: a
#                  license's fingerprint includes the machine-id.
#
# No baseline snapshot: savevm is per VM, and the shared disks are LIO's,
# outside both, so a pair cannot be reverted as one.
#
# Settings, environment variables, all optional:
#
#   APPLIANCE_DIR         its state (default $RUNNER_TEMP/truenas-appliance)
#   APPLIANCE_MEMORY_MB   6144 per node    APPLIANCE_VCPUS        4 per node
#   APPLIANCE_DATA_DISKS  4 shared disks   APPLIANCE_DATA_DISK_GB 10 (sparse)
#   APPLIANCE_PASSWORD    the admin password (default: generated)
#   APPLIANCE_BOOT_TIMEOUT 900 seconds
#
# start prints the suite's contract as appliance.sh does, TN_HOST being
# node A, which is where a fresh pair answers until it has a VIP, and
# TN_HA=true, TN_HA_NODE_A, TN_HA_NODE_B, TN_HA_VIP (free, for the suite to
# configure), TN_HA_NETMASK and TN_HA_GATEWAY, the addresses an HA setup
# needs; and APPLIANCE_BOOT_SECONDS.

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(realpath "$0")")/lib.sh"

DIR="${APPLIANCE_DIR:-${RUNNER_TEMP:-/tmp}/truenas-appliance}"
STATE="$DIR/state.env"
KEY="$DIR/ssh_key"
NET=10.231.0
RUNNER_IP=$NET.1
VIP=$NET.10
declare -A IP=([a]=$NET.11 [b]=$NET.12)
declare -A DATA_MAC=([a]=52:54:00:e2:a0:01 [b]=52:54:00:e2:b0:01)
declare -A HB_MAC=([a]=52:54:00:e2:a0:02 [b]=52:54:00:e2:b0:02)
declare -A SERIAL_SUFFIX=([a]=_c1 [b]=_c2)
SHARED="${APPLIANCE_DATA_DISKS:-4}"
SHARED_GB="${APPLIANCE_DATA_DISK_GB:-10}"

# shellcheck source=/dev/null
state() { [ -r "$STATE" ] || die "no HA pair started here ($STATE)"; . "$STATE"; }
node() {
    case "${1:-}" in a|b) ;; *) die "which node: a or b, not '${1:-}'" ;; esac
}
running() { [ -f "$DIR/$1/qemu.pid" ] && sudo -n kill -0 "$(cat "$DIR/$1/qemu.pid")" 2>/dev/null; }

# boot_disks: every attached disk holding a TrueNAS boot-pool, not the one
# / is on. appliance.sh's attached_disk insists on exactly one.
boot_disks() {
    lsblk -J -p -o NAME,PKNAME,FSTYPE,LABEL,MOUNTPOINT | python3 -c '
import json, sys
devs = []
def walk(ds):
    for d in ds:
        devs.append(d)
        walk(d.get("children") or [])
walk(json.load(sys.stdin)["blockdevices"])
root = {d["pkname"] for d in devs if d.get("mountpoint") == "/"}
for p in sorted({d["pkname"] for d in devs
                 if d.get("fstype") == "zfs_member" and d.get("label") == "boot-pool"
                 and d.get("pkname") and d["pkname"] not in root}):
    print(p)
'
}

network() {
    say "network: bridges tnha-data ($RUNNER_IP/24) and tnha-hb, a tap per node on each"
    local br n
    for br in tnha-data tnha-hb; do
        sudo -n ip link add "$br" type bridge
        sudo -n ip link set "$br" up
    done
    sudo -n ip addr add "$RUNNER_IP/24" dev tnha-data
    for n in a b; do
        sudo -n ip tuntap add dev "tnha-d-$n" mode tap user "$(id -u)"
        sudo -n ip tuntap add dev "tnha-h-$n" mode tap user "$(id -u)"
        sudo -n ip link set "tnha-d-$n" master tnha-data up
        sudo -n ip link set "tnha-h-$n" master tnha-hb up
    done
    # Docker loads br_netfilter and drops FORWARD by default, which would
    # drop frames between the two nodes on these bridges: VRRP, heartbeat.
    for br in tnha-data tnha-hb; do
        sudo -n iptables -I FORWARD -i "$br" -j ACCEPT
        sudo -n iptables -I FORWARD -o "$br" -j ACCEPT
    done
    sudo -n dnsmasq --interface=tnha-data --bind-interfaces --except-interface=lo --port=0 \
        --dhcp-range="$NET.100,$NET.200,12h" \
        --dhcp-host="${DATA_MAC[a]},${IP[a]}" --dhcp-host="${DATA_MAC[b]},${IP[b]}" \
        --dhcp-leasefile="$DIR/dnsmasq.leases" --pid-file="$DIR/dnsmasq.pid" \
        --log-dhcp --log-facility="$DIR/dnsmasq.log"
}

# scsi_disks: this runner's SCSI disks, as "HCTL NAME", one a line.
scsi_disks() { lsblk -dn -o HCTL,NAME,TYPE | awk '$3 == "disk" && $1 ~ /:/ {print $1, $2}' | sort -V; }

# storage: the shared disks. LIO's loopback fabric shows the same LUNs on
# this runner twice, through one loopback target per node: two I_T nexuses
# to LIO, so it tells the nodes' reservations apart, and two sets of
# /dev/sd* here, one handed to each node as scsi-block.
storage() {
    say "storage: $SHARED LIO LUNs of ${SHARED_GB}G, shown to each node through a loopback target of its own"
    local i n wwn before dbroot
    # LIO writes <db_root>/pr/aptpl_<serial> after every reservation change,
    # and answers the change with LOGICAL UNIT COMMUNICATION FAILURE when it
    # cannot, though the change is already made: fenced's every REGISTER
    # fails that way. Debian's targetcli points db_root at
    # /etc/rtslib-fb-target the first time it runs, and nothing makes the
    # pr/ in it: so make it under whatever db_root ends up being.
    sudo -n modprobe target_core_mod
    sudo -n targetcli ls / >/dev/null
    dbroot="$(sudo -n cat /sys/kernel/config/target/dbroot)"
    sudo -n mkdir -p "$dbroot/pr" "$dbroot/alua"
    sudo -n modprobe tcm_loop
    for i in $(seq 1 "$SHARED"); do
        truncate -s "${SHARED_GB}G" "$DIR/shared$i.img"
        sudo -n targetcli /backstores/fileio create "name=tnha$i" "file_or_dev=$DIR/shared$i.img" write_back=false >/dev/null
    done
    for n in a b; do
        wwn="naa.50014050000e2${n}00"
        before="$(scsi_disks)"
        sudo -n targetcli /loopback create "$wwn" >/dev/null
        for i in $(seq 1 "$SHARED"); do
            sudo -n targetcli "/loopback/$wwn/luns" create "/backstores/fileio/tnha$i" >/dev/null
        done
        sudo -n udevadm settle
        # The new disks, in LUN order: lun 0 is tnha1.
        scsi_disks | grep -vxF -f <(echo "$before") | sort -t: -k4,4n | awk '{print "/dev/" $2}' > "$DIR/shared-$n.list"
        [ "$(wc -l < "$DIR/shared-$n.list")" = "$SHARED" ] \
            || die "node $n's loopback target showed $(wc -l < "$DIR/shared-$n.list") disks, not $SHARED: $(cat "$DIR/shared-$n.list")"
    done
}

boot() {
    local n="$1" disk="$2" memory="$3" vcpus="$4" name="$5"
    local d="$DIR/$n" i=0 dev
    mkdir -p "$d"
    qemu-img create -q -f qcow2 -F raw -b "$disk" "$d/os.qcow2"
    vars_qcow2 "$d/vars.qcow2"
    local shared=(-device "virtio-scsi-pci,id=scsi0,bus=pcie.0,addr=0x5")
    while read -r dev; do
        i=$((i + 1))
        shared+=(-blockdev "{\"driver\":\"host_device\",\"filename\":\"$dev\",\"node-name\":\"sh$i\"}"
                 -device "scsi-block,bus=scsi0.0,channel=0,scsi-id=$i,lun=0,drive=sh$i")
    done < "$DIR/shared-$n.list"
    say "booting node $n from $disk as ${name}${SERIAL_SUFFIX[$n]}: ${memory} MB, $vcpus vCPUs"
    # As root: SG_IO passes PERSISTENT RESERVE OUT through only for a
    # process with CAP_SYS_RAWIO. Its socket and files are handed back.
    sudo -n qemu-system-x86_64 -name "$name-$n" -machine q35,accel=kvm -cpu host -smp "$vcpus" -m "$memory" \
        -uuid "$(python3 -c 'import uuid; print(uuid.uuid4())')" \
        -smbios "type=1,manufacturer=QEMU,serial=${name}${SERIAL_SUFFIX[$n]}" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=qcow2,file=$d/vars.qcow2" \
        -drive "file=$d/os.qcow2,if=none,id=os,format=qcow2,discard=unmap" \
        -device "virtio-blk-pci,drive=os,serial=os,bootindex=0,bus=pcie.0,addr=0x4" \
        "${shared[@]}" \
        -netdev "tap,id=data,ifname=tnha-d-$n,script=no,downscript=no" \
        -device "virtio-net-pci,netdev=data,mac=${DATA_MAC[$n]},bus=pcie.0,addr=0x3" \
        -device pcie-root-port,id=rp1,bus=pcie.0,chassis=1,addr=0x1c \
        -netdev "tap,id=hb,ifname=tnha-h-$n,script=no,downscript=no" \
        -device "virtio-net-pci,netdev=hb,mac=${HB_MAC[$n]},bus=rp1,addr=0x0" \
        -device virtio-rng-pci \
        -qmp "unix:$d/qmp.sock,server=on,wait=off" \
        -display none -serial "file:$d/console.log" \
        -daemonize -pidfile "$d/qemu.pid"
    sudo -n chown "$(id -u)" "$d/qmp.sock" "$d/qemu.pid" "$d/console.log"
    skip_grub "$d/console.log" "$d/qmp.sock"
}

ssh_() {
    local n="$1"; shift
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$APPLIANCE_USER@${IP[$n]}" "$@"
}

# ids <node>: what a clone shares with the disk it was cloned from.
# shellcheck disable=SC2016 # expanded on the node
ids() { ssh_ "$1" 'echo "$(cat /etc/machine-id) $(hostid)"'; }

# unique: node B's machine-id and hostid made its own, and B rebooted onto
# them. fenced keys reservations by the machine-id's first 8 hex digits:
# with the two alike, the standby would take the master's reservation for
# its own.
unique() {
    local password="$1" a b
    a="$(ids a)" b="$(ids b)"
    if [ "$a" != "$b" ]; then
        say "nodes already differ (A: $a, B: $b)"
        return
    fi
    say "both nodes have machine-id and hostid $a: giving B its own, and rebooting it"
    # shellcheck disable=SC2016
    ssh_ b 'set -e
        head -c 16 /dev/urandom | od -An -tx1 | tr -d " \n" | sudo tee /etc/machine-id >/dev/null
        sudo rm -f /var/lib/dbus/machine-id
        sudo zgenhostid -f'
    local boot now i
    boot="$(ssh_ b cat /proc/sys/kernel/random/boot_id)"
    ssh_ b 'sudo systemctl reboot' || true
    # Back once B answers ssh from a new boot. Neither "ssh stopped answering"
    # nor "the API answers" proves that: the API answers for a while after the
    # reboot is asked for, and on the new boot it can answer before sshd does
    # (run 39251437564 read B's ids over ssh and was refused).
    for i in $(seq 1 120); do
        now="$(ssh_ b cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || now=
        [ -n "$now" ] && [ "$now" != "$boot" ] && break
        sleep 5
    done
    if [ -z "$now" ] || [ "$now" = "$boot" ]; then
        die "node B did not come back over ssh from its reboot within 10 minutes"
    fi
    "${TNCTL[@]}" wait "ws://${IP[b]}" "$APPLIANCE_USER" "$password" --timeout 600 >/dev/null
    b="$(ids b)"
    [ "$a" != "$b" ] || die "node B still has A's ids after its reboot: $b"
    say "node B now has $b"
}

start() {
    local memory="${APPLIANCE_MEMORY_MB:-6144}" vcpus="${APPLIANCE_VCPUS:-4}"
    local password="${APPLIANCE_PASSWORD:-$(head -c 15 /dev/urandom | base64 | tr -d '/+=')}"
    local name="ha-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

    running a 2>/dev/null && die "an HA pair is running already ($DIR)"
    [ -w /dev/kvm ] || die "no /dev/kvm this user can use: the runner needs nested virtualization (cpu_mode HOST-PASSTHROUGH) and to be in the kvm group"
    needs qemu-system-x86_64 qemu-system-x86 qemu-img qemu-utils python3 python3 \
        targetcli targetcli-fb dnsmasq dnsmasq-base iptables iptables ssh openssh-client
    ovmf
    say "runner: $(nproc) vCPUs, $(free -m | awk '/^Mem:/ {print $2 " MB, " $7 " MB available"}')"

    local disks d
    mapfile -t disks < <(boot_disks)
    if [ "${#disks[@]}" -ne 2 ]; then
        lsblk -p -o NAME,SIZE,SERIAL,FSTYPE,LABEL,MOUNTPOINT >&2 || true
        die "an HA pair needs two attached appliance disks, and this runner has ${#disks[@]}: give its pool {\"disks\": [\"truenas_appliance:nightly\", \"truenas_appliance:nightly\"]}"
    fi
    for d in "${disks[@]}"; do
        [ -r "$d" ] || sudo -n chown "$(id -u)" "$d"
    done

    rm -rf "$DIR"
    mkdir -p "$DIR"
    network
    storage

    local t0 n booted
    t0=$(date +%s.%N)
    boot a "${disks[0]}" "$memory" "$vcpus" "$name"
    boot b "${disks[1]}" "$memory" "$vcpus" "$name"
    for n in a b; do
        if ! booted=$("${TNCTL[@]}" wait "ws://${IP[$n]}" "$APPLIANCE_USER" "$APPLIANCE_TEMPLATE_PASSWORD" \
                --since "$t0" --timeout "${APPLIANCE_BOOT_TIMEOUT:-900}"); then
            say "--- node $n's console, last 60 lines"
            tail -n 60 "$DIR/$n/console.log" >&2 || true
            say "--- dnsmasq"
            cat "$DIR/dnsmasq.log" >&2 2>/dev/null || true
            die "node $n's API never came up at ${IP[$n]}"
        fi
        say "node $n: API up at ${IP[$n]}"
    done

    # ssh with a key and sudo, on both: unique below needs it, and a failed
    # HA setup is read from fenced's log and the disks' reservations.
    ssh-keygen -q -t ed25519 -N '' -C truenas-appliance-ha -f "$KEY"
    for n in a b; do
        "${TNCTL[@]}" rotate "ws://${IP[$n]}" "$APPLIANCE_USER" "$APPLIANCE_TEMPLATE_PASSWORD" "$password"
        "${TNCTL[@]}" enable-ssh "ws://${IP[$n]}" "$APPLIANCE_USER" "$password" --pubkey "$(cat "$KEY.pub")"
    done
    for _ in $(seq 1 30); do
        ssh_ a true 2>/dev/null && ssh_ b true 2>/dev/null && break
        sleep 2
    done
    unique "$password"
    echo "APPLIANCE_PASSWORD_NOW=$(printf %q "$password")" > "$STATE"
    booted=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
    say "HA pair up in ${booted}s: A at ${IP[a]}, B at ${IP[b]}, VIP $VIP free for the suite"

    cat <<EOF
TN_PROFILE=shipped
TN_HOST=${IP[a]}:443
TN_HOST_HTTP=${IP[a]}:80
TN_USERNAME=$APPLIANCE_USER
TN_PASSWORD=$password
TN_DOMAIN=$name
TN_BASELINE=none
TN_HA=true
TN_HA_NODE_A=${IP[a]}
TN_HA_NODE_B=${IP[b]}
TN_HA_VIP=$VIP
TN_HA_NETMASK=24
TN_HA_GATEWAY=$RUNNER_IP
APPLIANCE_BOOT_SECONDS=$booted
EOF
}

stop() {
    local n
    for n in a b; do
        if running "$n"; then sudo -n kill "$(cat "$DIR/$n/qemu.pid")" || true; fi
    done
}

case "${1:-}" in
start)   start ;;
call)    shift; node "${1:-}"; n="$1"; shift
         [ $# -gt 0 ] || die "call <a|b> <method> [params...]"; state
         "${TNCTL[@]}" call "ws://${IP[$n]}" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" "$@" ;;
ssh)     shift; node "${1:-}"; n="$1"; shift; ssh_ "$n" "$@" ;;
console) node "${2:-}"; tail -n "${3:-100}" "$DIR/$2/console.log" ;;
stop)    stop ;;
*)       die "usage: ha.sh start | call <a|b> <method> [params...] | ssh <a|b> [command] | console <a|b> [lines] | stop" ;;
esac
