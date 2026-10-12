# shellcheck shell=bash disable=SC2034
# Shared by appliance.sh, which boots an appliance in a runner, and by the
# image build in iXsystems/github-truenas-runner, which installs one and
# fetches this from here: how a TrueNAS appliance runs under qemu, and the
# admin it is built with. Sourced, not run.

# The admin the image is built with, and its password until a claim
# rotates it. Not a secret: the image is booted only by qemu inside a
# runner, its ports bound there alone, and every claim changes the
# password before handing the appliance out.
APPLIANCE_USER=truenas_admin
APPLIANCE_TEMPLATE_PASSWORD=truenas-appliance-template

APPLIANCE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TNCTL=(python3 "$APPLIANCE_LIB/tnctl.py")

die() { echo "appliance: $*" >&2; exit 1; }
say() { echo "appliance: $*" >&2; }

# ovmf: the UEFI firmware, as Debian and Ubuntu install it.
ovmf() {
    local d try
    for try in 1 2; do
        for d in /usr/share/OVMF /usr/share/ovmf /usr/share/qemu; do
            if [ -r "$d/OVMF_CODE_4M.fd" ] && [ -r "$d/OVMF_VARS_4M.fd" ]; then
                OVMF_CODE="$d/OVMF_CODE_4M.fd" OVMF_VARS="$d/OVMF_VARS_4M.fd"
                return
            fi
        done
        [ "$try" = 1 ] && needs __no_such_command__ ovmf
    done
    die "no OVMF firmware (OVMF_CODE_4M.fd), even after installing ovmf"
}

# needs <command> <debian package>...: install what is missing, when this
# runner can (passwordless sudo and apt).
needs() {
    local missing=() pkg cmd
    while [ $# -gt 0 ]; do
        cmd="$1" pkg="$2"; shift 2
        command -v "$cmd" >/dev/null || missing+=("$pkg")
    done
    [ ${#missing[@]} -eq 0 ] && return
    if ! command -v apt-get >/dev/null || ! sudo -n true 2>/dev/null; then
        die "missing ${missing[*]}, and no sudo and apt here to install them"
    fi
    say "installing ${missing[*]}"
    sudo -n apt-get update -qq
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
}

# vars_qcow2 <out>: a fresh UEFI variable store, as qcow2. savevm snapshots
# every writable disk, and refuses one that is not qcow2: the variable
# store is one.
vars_qcow2() {
    qemu-img convert -q -f raw -O qcow2 "$OVMF_VARS" "$1"
}

# binds: where the appliance's forwarded ports listen. This machine's
# loopback, and Docker's bridge when there is one, so that a container
# reaches it as host.docker.internal; never the runner's network.
binds() {
    echo 127.0.0.1
    ip -4 -o addr show dev docker0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'
}

# hostfwd <guest port> <host port>: qemu's forward of it, on every bind.
hostfwd() {
    local a out=""
    for a in $(binds); do
        out+=",hostfwd=tcp:$a:$2-:$1"
    done
    echo "$out"
}
