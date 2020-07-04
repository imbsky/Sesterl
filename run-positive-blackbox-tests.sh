#!/bin/bash

BIN="./sesterl"
SOURCE_DIR="test/pass"
TARGET_DIR="test/_generated"

ERRORS=()

for SOURCE in "$SOURCE_DIR"/*.sest; do
    echo "Compiling '$SOURCE' by sesterl ..."
    "$BIN" "$SOURCE" -o "$TARGET_DIR"
    STATUS=$?
    if [ $STATUS -ne 0 ]; then
        ERRORS+=("$SOURCE")
    fi
done

for TARGET in "$TARGET_DIR"/*.erl; do
    echo "Compiling '$TARGET' by erlc ..."
    erlc -o "$TARGET_DIR" "$TARGET"
    STATUS=$?
    if [ $STATUS -ne 0 ]; then
        ERRORS+=("$TARGET")
    fi
done

RET=0
for X in "${ERRORS[@]}"; do
    RET=1
    echo "[FAIL] $X"
done
if [ $RET -eq 0 ]; then
    echo "All tests have passed."
fi

exit $RET