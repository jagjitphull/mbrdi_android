#!/usr/bin/env bash
set -u

R="/opt/cuttlefish/android16"
ADB="$R/bin/adb"
SERIAL="${SERIAL:-0.0.0.0:6520}"

PASS=0
FAIL=0

pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== Android 16 Cuttlefish Post-Setup Verification ==="

if [[ ! -x "$ADB" ]]; then
  echo "[FAIL] ADB not found at $ADB"
  exit 1
fi

"$ADB" connect "$SERIAL" >/dev/null 2>&1 || true

STATE="$("$ADB" -s "$SERIAL" get-state 2>/dev/null || true)"
[[ "$STATE" == "device" ]] && pass "ADB device connected" || fail "ADB device not connected"

if [[ "$STATE" == "device" ]]; then
  RELEASE="$("$ADB" -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
  SDK="$("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
  BOOT="$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed | tr -d '\r')"
  TYPE="$("$ADB" -s "$SERIAL" shell getprop ro.build.type | tr -d '\r')"
  DEBUG="$("$ADB" -s "$SERIAL" shell getprop ro.debuggable | tr -d '\r')"
  SELINUX="$("$ADB" -s "$SERIAL" shell getenforce | tr -d '\r')"

  [[ "$RELEASE" == "16" ]] && pass "Android 16" || fail "Android release is $RELEASE"
  [[ "$SDK" == "36" ]] && pass "API 36" || fail "API level is $SDK"
  [[ "$BOOT" == "1" ]] && pass "Android boot complete" || fail "Android boot incomplete"
  [[ "$TYPE" == "userdebug" ]] && pass "userdebug build" || fail "Build type is $TYPE"
  [[ "$DEBUG" == "1" ]] && pass "Debuggable build" || fail "ro.debuggable=$DEBUG"
  [[ "$SELINUX" == "Enforcing" ]] && pass "SELinux Enforcing" || fail "SELinux is $SELINUX"

  if "$ADB" -s "$SERIAL" shell ip route >/dev/null 2>&1; then
    pass "Android networking command works"
  else
    fail "Android networking command failed"
  fi
fi

if ss -lnt 2>/dev/null | grep -q ':8443'; then
  pass "WebRTC HTTPS port 8443 listening"
else
  fail "WebRTC port 8443 not listening"
fi

echo
echo "Summary: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
