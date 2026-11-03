#!/system/bin/sh
# droid_lkm install helper for the SM-A366E (A36) 6.6.118 kernel.
#
# Safety rules baked in:
#   - refuses to load when the module vermagic does not match uname -r;
#   - never passes --force (the device has no CONFIG_MODULE_FORCE_LOAD);
#   - never edits the vermagic string;
#   - never removes loading / insmod.inflight / insmod.crash / load.log;
#   - dry-run by default: prints the exact command and exits.
#
# Usage:
#   sh install.sh [--ko PATH] [--apply]
#
# Without --apply nothing is loaded. With --apply the script runs insmod
# only after every preflight check passes.

set -u

MODDIR=${MODDIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}
KO=""
APPLY=0

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case $1 in
        --ko) [ $# -ge 2 ] || { echo "--ko needs a path" >&2; exit 64; }; KO=$2; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --force|--degrade|degrade=*) echo "refused: forcing vermagic/degrade is not allowed" >&2; exit 64 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

die() { echo "FAIL: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (su -c 'sh install.sh ...')"

if [ -z "$KO" ]; then
    if [ -f "$MODDIR/droid_lkm.ko" ]; then
        KO=$MODDIR/droid_lkm.ko
    elif [ -f "$MODDIR/out/android15-6.6/droid_lkm.ko" ]; then
        KO=$MODDIR/out/android15-6.6/droid_lkm.ko
    else
        die "module not found; pass --ko PATH"
    fi
fi
[ -f "$KO" ] || die "no such file: $KO"

MACHINE=$(uname -m)
case $MACHINE in aarch64|arm64) ;; *) die "unexpected machine: $MACHINE" ;; esac

DEVREL=$(uname -r)
[ -n "$DEVREL" ] || die "cannot read uname -r"

VM=$(grep -a -o 'vermagic=[ -~]*' "$KO" 2>/dev/null | head -n 1)
[ -n "$VM" ] || die "cannot read vermagic from $KO (no strings/grep support?)"
VM=${VM#vermagic=}
VMREL=${VM%% *}

echo "module : $KO"
echo "vermagic: $VM"
echo "kernel : $DEVREL"

[ "$VMREL" = "$DEVREL" ] || {
    echo >&2
    echo "FAIL: vermagic release mismatch" >&2
    echo "  module needs: $VMREL" >&2
    echo "  device has  : $DEVREL" >&2
    echo "  check_modinfo() rejects this before any hook runs." >&2
    echo "  CONFIG_MODULE_FORCE_LOAD is not set on this kernel;" >&2
    echo "  forcing or patching the vermagic is out of scope." >&2
    echo "  rebuild against the device's 6.6.118 headers instead." >&2
    exit 2
}

for marker in insmod.inflight loading insmod.crash; do
    if [ -e "$MODDIR/$marker" ]; then
        echo >&2
        echo "FAIL: $MODDIR/$marker exists; a previous load may be in flight." >&2
        echo "  Inspect it and the logs first. This script will not delete it." >&2
        exit 3
    fi
done

if command -v lsmod >/dev/null 2>&1 && lsmod 2>/dev/null | grep -q '^droid_lkm'; then
    echo "note: droid_lkm already loaded; insmod will fail with EEXIST" >&2
fi

if [ "$APPLY" != 1 ]; then
    echo
    echo "dry-run only. exact command to run:"
    echo "  insmod $KO verbose=1"
    echo "then:"
    echo "  dmesg | tail -n 60"
    echo "re-run with --apply to execute after these checks."
    exit 0
fi

echo
echo "loading..."
insmod "$KO" verbose=1
RC=$?
echo "insmod exit: $RC"
if [ $RC -eq 0 ] && command -v dmesg >/dev/null 2>&1; then
    dmesg | tail -n 60
fi
exit $RC
