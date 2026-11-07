#!/data/data/com.termux/files/usr/bin/sh
# rish_setup.sh - install Shizuku's rish into Termux and check it works.
#
# Run inside Termux:
#   sh /sdcard/Download/rish_setup.sh
#
# Requires: Shizuku app running (adb / wireless-debugging mode) and
#           /sdcard/Download/shizuku_rish/{rish,rish_shizuku.dex} present.

set -e

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if [ -f /sdcard/Download/rish/rish ]; then
    SRC="/sdcard/Download/rish"          # exported by the Shizuku app
else
    SRC="/sdcard/Download/shizuku_rish"  # pre-extracted copy
fi
DEST="$PREFIX/bin"

if [ ! -f "$SRC/rish" ] || [ ! -f "$SRC/rish_shizuku.dex" ]; then
    echo "missing $SRC/rish or $SRC/rish_shizuku.dex" >&2
    exit 1
fi

mkdir -p "$DEST"
cp "$SRC/rish" "$DEST/rish"
cp "$SRC/rish_shizuku.dex" "$DEST/rish_shizuku.dex"

chmod 700 "$DEST/rish"
# Android 14+ refuses to load a writable dex, so make it read-only.
chmod 400 "$DEST/rish_shizuku.dex"

# Fill in the terminal package id (the asset ships with the literal "PKG").
sed -i 's/"PKG"/"com.termux"/' "$DEST/rish"

echo "installed: $DEST/rish"
echo "dex:       $DEST/rish_shizuku.dex"
echo
echo "first run will pop a Shizuku permission dialog for Termux - tap Allow"
echo

exec "$DEST/rish" -c 'id; getprop ro.product.model'
