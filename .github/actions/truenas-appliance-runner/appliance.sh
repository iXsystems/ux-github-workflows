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
#   appliance.sh revert <name>    back to <name>, in seconds, no boot
#   appliance.sh probe [baseline] change it, revert, check the change went
#   appliance.sh call <method> [params...]
#                                 a middleware API call, as the admin, its
#                                 result as JSON on stdout
#   appliance.sh snapshots        the names there are
#   appliance.sh console [lines]  the end of its serial console
#   appliance.sh stop
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
#   APPLIANCE_HTTP_PORT   8080       APPLIANCE_HTTPS_PORT   8443
#   APPLIANCE_SSH_PORT    2222       APPLIANCE_SSH          false
#   APPLIANCE_BASELINE    fresh-install: the snapshot start takes; empty
#                         takes none
#   APPLIANCE_PASSWORD    the claim's admin password (default: generated)
#   APPLIANCE_BOOT_TIMEOUT 900 seconds
#   APPLIANCE_ACCEL       kvm; tcg runs without KVM, too slowly for
#                         anything but testing this script
#
# start prints TN_PROFILE, TN_HOST (host:https port), TN_HOST_HTTP,
# TN_USERNAME, TN_PASSWORD, TN_DOMAIN, TN_BASELINE (the suite's contract,
# as the lab's claim action gives it), TN_SSH, and what it measured:
# APPLIANCE_BOOT_SECONDS, APPLIANCE_SNAPSHOT_SECONDS.

set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib.sh"

DIR="${APPLIANCE_DIR:-${RUNNER_TEMP:-/tmp}/truenas-appliance}"
QMP="$DIR/qmp.sock"
STATE="$DIR/state.env"

hmp() { "${TNCTL[@]}" hmp "$QMP" "$*"; }
# resume: a failed loadvm leaves the VM paused, and later loadvms leave it
# so, however they go; cont is a no-op on one that runs.
resume() { "${TNCTL[@]}" qmp "$QMP" cont >/dev/null; }
url() { echo "ws://127.0.0.1:${APPLIANCE_HTTP_PORT:-8080}"; }
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

start() {
    local disk="${APPLIANCE_DISK:-}"
    local memory="${APPLIANCE_MEMORY_MB:-6144}" vcpus="${APPLIANCE_VCPUS:-4}"
    local ndata="${APPLIANCE_DATA_DISKS:-10}" datagb="${APPLIANCE_DATA_DISK_GB:-10}"
    local http="${APPLIANCE_HTTP_PORT:-8080}" https="${APPLIANCE_HTTPS_PORT:-8443}" sshp="${APPLIANCE_SSH_PORT:-2222}"
    local baseline="${APPLIANCE_BASELINE-fresh-install}"
    local password="${APPLIANCE_PASSWORD:-$(head -c 15 /dev/urandom | base64 | tr -d '/+=')}"
    local name="appliance-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}"

    running && die "an appliance is running already ($DIR)"
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

    local booted
    say "booting $disk as $name: ${memory} MB, $vcpus vCPUs, $ndata data disks of ${datagb}G"
    qemu-system-x86_64 -name "$name" -machine "q35,accel=$accel" -cpu "$cpu" -smp "$vcpus" -m "$memory" \
        -smbios "type=1,serial=$name" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=qcow2,file=$DIR/vars.qcow2" \
        -drive "file=$DIR/os.qcow2,if=none,id=os,format=qcow2,discard=unmap" \
        -device "virtio-blk-pci,drive=os,serial=os,bootindex=0" \
        "${drives[@]}" \
        -nic "user,model=virtio-net-pci$(hostfwd 80 "$http")$(hostfwd 443 "$https")$(hostfwd 22 "$sshp")" \
        -device virtio-rng-pci \
        -qmp "unix:$QMP,server=on,wait=off" \
        -display none -serial "file:$DIR/console.log" \
        -daemonize -pidfile "$DIR/qemu.pid"

    if ! booted=$("${TNCTL[@]}" wait "$(url)" "$APPLIANCE_USER" "$APPLIANCE_TEMPLATE_PASSWORD" \
            --timeout "${APPLIANCE_BOOT_TIMEOUT:-900}"); then
        say "--- its console, last 60 lines"
        tail -n 60 "$DIR/console.log" >&2 || true
        die "the appliance's API never came up"
    fi
    say "API up ${booted}s after qemu started"
    "${TNCTL[@]}" rotate "$(url)" "$APPLIANCE_USER" "$APPLIANCE_TEMPLATE_PASSWORD" "$password"
    if [ "${APPLIANCE_SSH:-false}" = true ]; then
        "${TNCTL[@]}" enable-ssh "$(url)" "$APPLIANCE_USER" "$password"
        say "ssh on 127.0.0.1:$sshp"
    fi
    {
        echo "APPLIANCE_PASSWORD_NOW=$(printf %q "$password")"
        echo "APPLIANCE_HTTP_PORT=$http"
    } > "$STATE"

    local snapped=""
    if [ -n "$baseline" ]; then
        local s0
        s0=$(date +%s.%N)
        hmp savevm "$baseline" >&2
        snapped=$(awk -v a="$s0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
        say "snapshot $baseline taken in ${snapped}s"
    fi

    cat <<EOF
TN_PROFILE=shipped
TN_HOST=127.0.0.1:$https
TN_HOST_HTTP=127.0.0.1:$http
TN_USERNAME=$APPLIANCE_USER
TN_PASSWORD=$password
TN_DOMAIN=$name
TN_BASELINE=${baseline:-none}
TN_SSH=127.0.0.1:$sshp
APPLIANCE_BOOT_SECONDS=$booted
APPLIANCE_SNAPSHOT_SECONDS=$snapped
EOF
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
# the moment it returns; its connections from before are gone, and its
# clock is the snapshot's until it catches up.
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
    "${TNCTL[@]}" wait "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" --timeout 120 >/dev/null
    awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f\n", b - a}'
}

# probe <baseline>: that revert works and what it costs. A group is made
# over the API, the appliance reverted to <baseline>, and the group must
# be gone; KEY=value on stdout.
probe() {
    local baseline="${1:-fresh-install}" took left
    state
    call() { "${TNCTL[@]}" call "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" "$@"; }
    call group.create '{"name": "e2e_probe"}' >/dev/null
    [ "$(call group.query '[["name", "=", "e2e_probe"]]' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1 ] \
        || die "probe: the group made over the API is not there"
    took="$(revert "$baseline")"
    left="$(call group.query '[["name", "=", "e2e_probe"]]' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    [ "$left" = 0 ] || die "probe: after reverting to $baseline the group is still there"
    say "revert to $baseline took ${took}s, and undid the change"
    echo "APPLIANCE_REVERT_SECONDS=$took"
}

case "${1:-}" in
start)     start ;;
call)      shift; [ $# -gt 0 ] || die "call <method> [params...]"; state
           "${TNCTL[@]}" call "$(url)" "$APPLIANCE_USER" "$APPLIANCE_PASSWORD_NOW" "$@" ;;
probe)     shift; probe "$@" ;;
snapshot)  shift; snapshot "$@" ;;
revert)    shift; revert "$@" ;;
snapshots) running || die "no appliance running"; hmp info snapshots ;;
console)   tail -n "${2:-100}" "$DIR/console.log" ;;
stop)      running && "${TNCTL[@]}" qmp "$QMP" quit >/dev/null || true ;;
*)         die "usage: appliance.sh start | snapshot <name> | revert <name> | probe [baseline] | call <method> [params...] | snapshots | console [lines] | stop" ;;
esac
