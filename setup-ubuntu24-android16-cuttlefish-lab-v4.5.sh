#!/usr/bin/env bash
# Ubuntu 24.04 + Android 16 Cuttlefish one-command lab bootstrap v4.5
# Target: x86_64 Ubuntu 24.04 VM with nested KVM
# Android 16 artifacts: https://ci.android.com/
# AOSP Cuttlefish download instructions: https://source.android.com/docs/devices/cuttlefish/get-started
# Use branch android16-release, target aosp_cf_x86_64_only_phone-userdebug,
# and download cvd-host_package.tar.gz + the x86_64 phone image from the SAME green build.
# v4.4 launches local CI bundles with bin/cvd_internal_start (current) or bin/launch_cvd (legacy).
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
CURRENT_STAGE="startup"
LOG_FILE="${HOME}/android16-cuttlefish-setup.log"
RUNTIME="/opt/cuttlefish/android16"
MIN_VCPU=6
MIN_MEM_KB=$((15 * 1024 * 1024))
MIN_DISK_TOTAL_KB=$((75 * 1024 * 1024))
MIN_DISK_FREE_KB=$((28 * 1024 * 1024))
EXPECTED_ANDROID_RELEASE="${EXPECTED_ANDROID_RELEASE:-16}"
EXPECTED_ANDROID_API="${EXPECTED_ANDROID_API:-36}"
CVD_IMAGE_ZIP="${CVD_IMAGE_ZIP:-}"

exec > >(tee -a "$LOG_FILE") 2>&1

say()  { printf '\n[%s] %s\n' "$1" "$2"; }
pass() { printf '[PASS] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n[FAIL] Setup stopped during stage: %s\n' "$CURRENT_STAGE" >&2
  printf '[FAIL] Exit code: %s\n' "$rc" >&2
  printf '[INFO] Full log: %s\n' "$LOG_FILE" >&2
  if [[ -n "${CVD_USER:-}" ]]; then
    if [[ -x "$RUNTIME/bin/cvd_internal_stop" ]]; then
      sudo -u "$CVD_USER" env HOME="$RUNTIME" \
        "$RUNTIME/bin/cvd_internal_stop" >/dev/null 2>&1 || true
    elif [[ -x "$RUNTIME/bin/stop_cvd" ]]; then
      sudo -u "$CVD_USER" env HOME="$RUNTIME" \
        "$RUNTIME/bin/stop_cvd" >/dev/null 2>&1 || true
    fi
  fi
  exit "$rc"
}
trap on_error ERR

if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" ]]; then
  fail "Run this script as the regular learner account, not as root. Example: ./$SCRIPT_NAME"
fi

CVD_USER="${CVD_USER:-${SUDO_USER:-$USER}}"
[[ "$CVD_USER" != "root" ]] || fail "Cuttlefish must not run as root."

CVD_HOME="$(getent passwd "$CVD_USER" | cut -d: -f6)"
[[ -n "$CVD_HOME" && -d "$CVD_HOME" ]] ||
  fail "Could not determine home directory for $CVD_USER."

CURRENT_STAGE="minimal host prerequisite checks"
say PRECHECK "Checking only prerequisites that the script cannot create"

[[ -r /etc/os-release ]] || fail "/etc/os-release is unavailable."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] ||
  fail "Ubuntu 24.04 is required. Detected: ${PRETTY_NAME:-unknown}"

[[ "$(uname -m)" == "x86_64" ]] ||
  fail "x86_64 is required. Detected: $(uname -m)"

VIRT_COUNT="$(grep -Eoc '\b(vmx|svm)\b' /proc/cpuinfo || true)"
(( VIRT_COUNT > 0 )) ||
  fail "VMX/SVM is not visible. Enable nested virtualization / host-passthrough on the KVM host."

[[ -e /dev/kvm ]] ||
  fail "/dev/kvm is missing. Nested KVM must be exposed to this Ubuntu VM."

VCPU="$(nproc)"
(( VCPU >= MIN_VCPU )) ||
  fail "At least ${MIN_VCPU} vCPU are required. Detected: ${VCPU}"

MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
(( MEM_KB >= MIN_MEM_KB )) ||
  fail "At least 16 GB RAM is required for the lab VM."

DISK_LINE="$(df -Pk / | awk 'NR==2{print $2" "$4}')"
DISK_TOTAL_KB="${DISK_LINE%% *}"
DISK_FREE_KB="${DISK_LINE##* }"
(( DISK_TOTAL_KB >= MIN_DISK_TOTAL_KB )) ||
  fail "Use an 80 GB or larger VM disk."
(( DISK_FREE_KB >= MIN_DISK_FREE_KB )) ||
  fail "At least 28 GB free space is required before setup."

command -v sudo >/dev/null 2>&1 ||
  fail "sudo is required for the learner account."

sudo -v

pass "Ubuntu 24.04 x86_64"
pass "Nested virtualization visible"
pass "/dev/kvm present"
pass "Resources: ${VCPU} vCPU, $((MEM_KB/1024/1024)) GB RAM"
pass "Disk free: $((DISK_FREE_KB/1024/1024)) GB"

CURRENT_STAGE="artifact discovery"
say ARTIFACTS "Finding the two matching Android 16 CI artifacts"

find_artifact_pair() {
  local dir
  for dir in "$PWD" "$CVD_HOME"; do
    [[ -d "$dir" ]] || continue
    local host="$dir/cvd-host_package.tar.gz"
    [[ -f "$host" ]] || continue

    if [[ -n "$CVD_IMAGE_ZIP" ]]; then
      local explicit="$CVD_IMAGE_ZIP"
      [[ "$explicit" = /* ]] || explicit="$dir/$explicit"
      if [[ -f "$explicit" ]]; then
        ARTIFACT_DIR="$dir"
        HOST_PACKAGE="$host"
        IMAGE_ZIP="$explicit"
        return 0
      fi
    fi

    local -a images=()
    shopt -s nullglob
    images+=("$dir"/aosp_cf_x86_64_phone-img-*.zip)
    images+=("$dir"/aosp_cf_x86_64_only_phone-img-*.zip)
    shopt -u nullglob

    if [[ ${#images[@]} -eq 1 ]]; then
      ARTIFACT_DIR="$dir"
      HOST_PACKAGE="$host"
      IMAGE_ZIP="${images[0]}"
      return 0
    elif [[ ${#images[@]} -gt 1 ]]; then
      echo "[FAIL] Multiple Cuttlefish phone image ZIPs were found in $dir:" >&2
      printf '  %s\n' "${images[@]}" >&2
      echo >&2
      echo "Choose one explicitly, for example:" >&2
      echo "  CVD_IMAGE_ZIP='${images[0]}' ./$SCRIPT_NAME" >&2
      return 2
    fi
  done
  return 1
}

ARTIFACT_DISCOVERY_RC=0
find_artifact_pair || ARTIFACT_DISCOVERY_RC=$?
if [[ "$ARTIFACT_DISCOVERY_RC" -ne 0 ]]; then
  if [[ "$ARTIFACT_DISCOVERY_RC" -eq 2 ]]; then
    exit 1
  fi
  cat >&2 <<EOF

[FAIL] The Android artifacts were not found.

Official download site:
  https://ci.android.com/

For this Android 16 lab:
  1. Open https://ci.android.com/
  2. Search/select the Android 16 branch:
       android16-release
     Do NOT use a moving "latest" branch for this pinned Android 16 lab.
  3. Open the x86_64 Cuttlefish phone target:
       aosp_cf_x86_64_only_phone-userdebug
  4. Click a GREEN successful build.
  5. Open the build's Artifacts panel.
  6. Download BOTH files from that SAME build:
       cvd-host_package.tar.gz
       aosp_cf_x86_64_phone-img-<BUILD_ID>.zip
     Some CI builds may display a closely related x86_64 phone-image name.

Official AOSP instructions:
  https://source.android.com/docs/devices/cuttlefish/get-started

Place those TWO files either:
  1. beside this script, or
  2. in $CVD_HOME

Do not mix host and image artifacts from different CI builds.
EOF
  exit 1
fi

IMAGE_NAME="$(basename "$IMAGE_ZIP")"
BUILD_ID="$(
  printf '%s\n' "$IMAGE_NAME" |
    sed -nE 's/^aosp_cf_x86_64(_only)?_phone-img-([^.]*)\.zip$/\2/p'
)"
info "Artifact directory: $ARTIFACT_DIR"
info "Image artifact: $IMAGE_NAME"
[[ -n "$BUILD_ID" ]] && info "Image build ID: $BUILD_ID"
warn "The host package filename does not contain the build ID; it must have been downloaded from the same green CI build."

CURRENT_STAGE="minimal package installation"
say PACKAGES "Installing only software required to set up and run Cuttlefish"

sudo env DEBIAN_FRONTEND=noninteractive apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  jq \
  unzip \
  tar \
  iproute2 \
  procps

CURRENT_STAGE="artifact integrity checks"
say VERIFY "Checking the supplied host and Android image archives"

tar -tzf "$HOST_PACKAGE" >/dev/null
unzip -tq "$IMAGE_ZIP" >/dev/null

HOST_TAR_LIST="$(mktemp)"
tar -tzf "$HOST_PACKAGE" > "$HOST_TAR_LIST"

# Newer Cuttlefish releases can use /usr/bin/cvd from cuttlefish-base.
# Therefore bin/launch_cvd is NOT a required archive member.
if grep -Eq '(^|^\./)bin/(cvd_internal_start|assemble_cvd|run_cvd|launch_cvd)$' "$HOST_TAR_LIST"; then
  pass "Cuttlefish host executables detected in host archive"
else
  echo "[INFO] Relevant archive entries:" >&2
  grep -E '(^|/)(cvd|launch_cvd|cvd_internal_start|assemble_cvd|run_cvd|adb|crosvm)$' \
    "$HOST_TAR_LIST" | head -n 60 >&2 || true
  rm -f "$HOST_TAR_LIST"
  fail "Host archive does not look like a Cuttlefish host package."
fi

if grep -Eq '(^|^\./)bin/adb$' "$HOST_TAR_LIST"; then
  HOST_ARCHIVE_HAS_ADB=1
  pass "Host archive contains bin/adb"
else
  HOST_ARCHIVE_HAS_ADB=0
  warn "Host archive does not contain bin/adb; Ubuntu adb will be installed only if required."
fi

info "Detected Cuttlefish launcher-related archive entries:"
grep -E '(^|/)(cvd|launch_cvd|stop_cvd|cvd_internal_start|assemble_cvd|run_cvd)$' \
  "$HOST_TAR_LIST" | head -n 30 || true
rm -f "$HOST_TAR_LIST"

unzip -Z1 "$IMAGE_ZIP" | grep -qx 'boot.img' ||
  fail "Phone image ZIP does not contain boot.img."
unzip -Z1 "$IMAGE_ZIP" | grep -qx 'super.img' ||
  fail "Phone image ZIP does not contain super.img."
unzip -Z1 "$IMAGE_ZIP" | grep -qx 'android-info.txt' ||
  fail "Phone image ZIP does not contain android-info.txt."

pass "Host archive readable"
pass "Phone image archive readable"
pass "Required Cuttlefish files present"

CURRENT_STAGE="official Cuttlefish repository"
say CUTTLEFISH "Installing official Cuttlefish host support"

sudo curl -fsSL \
  https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
  -o /etc/apt/trusted.gpg.d/artifact-registry.asc
sudo chmod a+r /etc/apt/trusted.gpg.d/artifact-registry.asc

printf '%s\n' \
  'deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main' |
  sudo tee /etc/apt/sources.list.d/android-cuttlefish-artifacts.list \
  >/dev/null

sudo env DEBIAN_FRONTEND=noninteractive apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  cuttlefish-base \
  cuttlefish-user

if [[ "${HOST_ARCHIVE_HAS_ADB:-0}" != "1" ]] && ! command -v adb >/dev/null 2>&1; then
  info "Installing Ubuntu adb because this host archive does not ship bin/adb"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y adb
fi

for pkg in cuttlefish-base cuttlefish-user; do
  dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null |
    grep -q '^ii' ||
    fail "$pkg did not install correctly."
  pass "$pkg installed"
done

CURRENT_STAGE="kernel devices and runtime groups"
say KERNEL "Activating Cuttlefish kernel support without requiring a reboot"

sudo modprobe kvm >/dev/null 2>&1 || true
sudo modprobe tun >/dev/null 2>&1 || true
sudo modprobe vhost_net
sudo modprobe vhost_vsock

printf '%s\n' vhost_net vhost_vsock |
  sudo tee /etc/modules-load.d/cuttlefish-lab.conf >/dev/null

for group in kvm cvdnetwork render; do
  if ! getent group "$group" >/dev/null; then
    sudo groupadd --system "$group"
  fi
done

sudo usermod -aG kvm,cvdnetwork,render "$CVD_USER"

if command -v udevadm >/dev/null 2>&1; then
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  sudo udevadm settle || true
fi

for dev in /dev/kvm /dev/net/tun /dev/vhost-net /dev/vhost-vsock; do
  [[ -e "$dev" ]] || fail "Required device is missing after module activation: $dev"
  pass "$dev"
done

# Linux interface names are limited to 15 characters.
# Use a short, PID-suffixed name and always clean it up safely.
TUN_TEST="cvdtun$(( $$ % 100000 ))"
sudo ip link delete "$TUN_TEST" >/dev/null 2>&1 || true
sudo ip tuntap add dev "$TUN_TEST" mode tun
sudo ip link set "$TUN_TEST" up
sudo ip link show "$TUN_TEST" >/dev/null
sudo ip link delete "$TUN_TEST"
pass "TUN/TAP creation works"

for group in kvm cvdnetwork render; do
  sudo -u "$CVD_USER" id -nG |
    tr ' ' '\n' |
    grep -qx "$group" ||
    fail "$CVD_USER does not receive supplementary group $group."
  pass "$CVD_USER group: $group"
done

CURRENT_STAGE="runtime extraction"
say RUNTIME "Preparing /opt/cuttlefish/android16"

sudo install -d -o "$CVD_USER" -g "$CVD_USER" -m 0755 "$RUNTIME"

RUNTIME_MARKER="$RUNTIME/.bootstrap-image"
NEED_EXTRACT=1
if [[ -f "$RUNTIME_MARKER" ]] &&
   grep -qxF "$IMAGE_NAME" "$RUNTIME_MARKER" &&
   [[ -f "$RUNTIME/boot.img" ]] &&
   [[ -f "$RUNTIME/super.img" ]] &&
   { [[ -x "$RUNTIME/bin/cvd_internal_start" ]] ||
     [[ -x "$RUNTIME/bin/assemble_cvd" ]] ||
     [[ -x "$RUNTIME/bin/launch_cvd" ]]; }; then
  NEED_EXTRACT=0
  info "Matching runtime is already extracted; preserving existing Android data."
fi

if (( NEED_EXTRACT )); then
  if [[ -x "$RUNTIME/bin/cvd_internal_stop" ]]; then
    sudo -u "$CVD_USER" env HOME="$RUNTIME" \
      "$RUNTIME/bin/cvd_internal_stop" >/dev/null 2>&1 || true
  elif [[ -x "$RUNTIME/bin/stop_cvd" ]]; then
    sudo -u "$CVD_USER" env HOME="$RUNTIME" \
      "$RUNTIME/bin/stop_cvd" >/dev/null 2>&1 || true
  fi

  sudo find "$RUNTIME" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

  sudo -u "$CVD_USER" tar -xzf "$HOST_PACKAGE" -C "$RUNTIME"
  sudo -u "$CVD_USER" unzip -q "$IMAGE_ZIP" -d "$RUNTIME"
  printf '%s\n' "$IMAGE_NAME" |
    sudo -u "$CVD_USER" tee "$RUNTIME_MARKER" >/dev/null
fi

sudo chown -R "$CVD_USER:$CVD_USER" "$RUNTIME"

for item in \
  boot.img \
  super.img \
  vbmeta.img \
  android-info.txt
do
  [[ -e "$RUNTIME/$item" ]] ||
    fail "Runtime item missing after extraction: $item"
done

if [[ -x "$RUNTIME/bin/cvd_internal_start" ]] ||
   [[ -x "$RUNTIME/bin/assemble_cvd" ]] ||
   [[ -x "$RUNTIME/bin/launch_cvd" ]]; then
  pass "Cuttlefish internal host launcher components extracted"
else
  fail "No usable Cuttlefish launcher component found after extraction."
fi

if [[ -x "$RUNTIME/bin/adb" ]]; then
  pass "Runtime adb available"
elif command -v adb >/dev/null 2>&1; then
  pass "System adb available: $(command -v adb)"
else
  fail "No adb binary available after package installation/extraction."
fi

if [[ -x "$RUNTIME/bin/cvd_internal_start" ]]; then
  pass "Current local-bundle launcher: $RUNTIME/bin/cvd_internal_start"
elif [[ -x "$RUNTIME/bin/launch_cvd" ]]; then
  pass "Legacy local-bundle launcher: $RUNTIME/bin/launch_cvd"
else
  fail "No local Cuttlefish launcher found after extraction."
fi

pass "Host and Android image artifacts extracted"

CURRENT_STAGE="runtime filesystem and configuration checks"
sudo -u "$CVD_USER" bash -c '
  set -Eeuo pipefail
  cd "$1"

  if [[ -e fetcher_config.json ]] &&
     { [[ ! -s fetcher_config.json ]] ||
       ! jq empty fetcher_config.json >/dev/null 2>&1; }; then
    mv fetcher_config.json \
      "fetcher_config.json.invalid.$(date +%Y%m%d-%H%M%S)"
    echo "[PASS] Invalid fetcher_config.json quarantined"
  else
    echo "[PASS] No invalid fetcher_config.json"
  fi

  touch .cvd-group-test
  chgrp cvdnetwork .cvd-group-test
  rm -f .cvd-group-test
  echo "[PASS] Runtime supports cvdnetwork group ownership"
' _ "$RUNTIME"

CURRENT_STAGE="installing lifecycle helpers"
say HELPERS "Installing start, stop and validation commands"

sudo tee /usr/local/bin/stop-android16-cvd >/dev/null <<'STOP_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
R='/opt/cuttlefish/android16'
CVD_USER='__CVD_USER__'

if [[ -x "$R/bin/cvd_internal_stop" ]]; then
  sudo -u "$CVD_USER" env HOME="$R" \
    "$R/bin/cvd_internal_stop" >/dev/null 2>&1 || true
elif [[ -x "$R/bin/stop_cvd" ]]; then
  sudo -u "$CVD_USER" env HOME="$R" \
    "$R/bin/stop_cvd" >/dev/null 2>&1 || true
fi

pkill -u "$(id -u "$CVD_USER")" \
  -f 'cvd_internal_start|launch_cvd|assemble_cvd|run_cvd|crosvm|process_restarter|secure_env|webRTC' \
  >/dev/null 2>&1 || true

echo '[PASS] Cuttlefish stop requested' 
STOP_HELPER

sudo tee /usr/local/bin/start-android16-cvd >/dev/null <<'START_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
R='/opt/cuttlefish/android16'
CVD_USER='__CVD_USER__'
RESET_CVD="${RESET_CVD:-0}"

fail(){ echo "[FAIL] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }

if [[ -x "$R/bin/adb" ]]; then
  ADB="$R/bin/adb"
elif command -v adb >/dev/null 2>&1; then
  ADB="$(command -v adb)"
else
  fail "No adb binary is available."
fi

discover_serial() {
  local config env_file serial=''
  config="$(
    find "$R/cuttlefish/instances" \
      -type f -name cuttlefish_config.json \
      -print -quit 2>/dev/null
  )"

  if [[ -n "$config" ]]; then
    serial="$(
      jq -r '.. | objects | .adb_ip_and_port? // empty' \
        "$config" 2>/dev/null |
      head -n 1
    )"
  fi

  if [[ -z "$serial" ]]; then
    env_file="$(
      find "$R/cuttlefish" \
        -type f -name cuttlefish.env \
        -print -quit 2>/dev/null
    )"
    if [[ -n "$env_file" ]]; then
      serial="$(
        sed -nE 's/^export ANDROID_SERIAL="?([^"]+)"?$/\1/p' \
          "$env_file" |
        head -n 1
      )"
    fi
  fi

  printf '%s\n' "$serial"
}

for dev in /dev/kvm /dev/net/tun /dev/vhost-net /dev/vhost-vsock; do
  [[ -e "$dev" ]] || fail "Missing $dev"
done

for file in "$R/boot.img" "$R/super.img"; do
  [[ -e "$file" ]] || fail "Missing $file"
done

sudo -u "$CVD_USER" bash -c '
  cd "$1"
  if [[ -e fetcher_config.json ]] &&
     { [[ ! -s fetcher_config.json ]] ||
       ! jq empty fetcher_config.json >/dev/null 2>&1; }; then
    mv fetcher_config.json \
      "fetcher_config.json.invalid.$(date +%Y%m%d-%H%M%S)"
  fi
' _ "$R"

FLAGS=(
  --daemon
  --report_anonymous_usage_stats=n
  --enable_sandbox=false
  --enable_audio=false
  --gpu_mode=guest_swiftshader
  --start_webrtc=true
)
[[ "$RESET_CVD" == "1" ]] && FLAGS+=(--resume=false)

# Local CI artifacts are launched by the launcher shipped in the
# extracted host package. Do not use the system /usr/bin/cvd database
# frontend for this workflow: it may have no registered device group.
if [[ -x "$R/bin/cvd_internal_start" ]]; then
  info "Using current local-bundle launcher: $R/bin/cvd_internal_start"
  sudo -u "$CVD_USER" env \
    HOME="$R" \
    ANDROID_HOST_OUT="$R" \
    ANDROID_SOONG_HOST_OUT="$R" \
    ANDROID_PRODUCT_OUT="$R" \
    "$R/bin/cvd_internal_start" "${FLAGS[@]}"
elif [[ -x "$R/bin/launch_cvd" ]]; then
  info "Using legacy local-bundle launcher: $R/bin/launch_cvd"
  sudo -u "$CVD_USER" env \
    HOME="$R" \
    ANDROID_HOST_OUT="$R" \
    ANDROID_SOONG_HOST_OUT="$R" \
    ANDROID_PRODUCT_OUT="$R" \
    "$R/bin/launch_cvd" "${FLAGS[@]}"
else
  fail "No local Cuttlefish launcher found in $R/bin."
fi

SERIAL=''
for n in $(seq 1 180); do
  DETECTED="$(discover_serial)"
  for candidate in "$DETECTED" '0.0.0.0:6520' '127.0.0.1:6520'; do
    [[ -n "$candidate" ]] || continue
    sudo -u "$CVD_USER" env HOME="$R" \
      "$ADB" connect "$candidate" >/dev/null 2>&1 || true
    state="$(
      sudo -u "$CVD_USER" env HOME="$R" \
        "$ADB" -s "$candidate" get-state 2>/dev/null || true
    )"
    if [[ "$state" == device ]]; then
      SERIAL="$candidate"
      break 2
    fi
  done

  if (( n > 15 )); then
    pgrep -u "$(id -u "$CVD_USER")" -f 'crosvm|run_cvd' >/dev/null ||
      fail "Cuttlefish VM process exited during startup"
  fi
  sleep 2
done

[[ -n "$SERIAL" ]] ||
  fail "Timed out waiting for a usable Cuttlefish ADB serial"

for n in $(seq 1 180); do
  boot="$(
    sudo -u "$CVD_USER" env HOME="$R" \
      "$ADB" -s "$SERIAL" shell getprop sys.boot_completed \
      2>/dev/null | tr -d '\r'
  )"
  [[ "$boot" == 1 ]] && break
  (( n < 180 )) || fail "Android connected through ADB but did not finish booting"
  sleep 2
done

echo "[PASS] Cuttlefish ADB serial: $SERIAL"
echo '[PASS] Android framework boot completed'
echo "WebRTC: https://$(hostname -I | awk '{print $1}'):8443" 
START_HELPER

sudo tee /usr/local/bin/validate-android16-lab >/dev/null <<'VALIDATE_HELPER'
#!/usr/bin/env bash
set -u

R='/opt/cuttlefish/android16'
CVD_USER='__CVD_USER__'
if [[ -x "$R/bin/adb" ]]; then
  ADB="$R/bin/adb"
elif command -v adb >/dev/null 2>&1; then
  ADB="$(command -v adb)"
else
  ADB=""
fi
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass(){ echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail(){ echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
skip(){ echo "[SKIP] $1"; SKIP_COUNT=$((SKIP_COUNT+1)); }

adb_cmd() {
  sudo -u "$CVD_USER" env HOME="$R" "$ADB" "$@"
}

discover_serial() {
  local config env_file serial=''
  config="$(
    find "$R/cuttlefish/instances" \
      -type f -name cuttlefish_config.json \
      -print -quit 2>/dev/null
  )"
  if [[ -n "$config" ]]; then
    serial="$(
      jq -r '.. | objects | .adb_ip_and_port? // empty' \
        "$config" 2>/dev/null | head -n 1
    )"
  fi
  if [[ -z "$serial" ]]; then
    env_file="$(
      find "$R/cuttlefish" \
        -type f -name cuttlefish.env \
        -print -quit 2>/dev/null
    )"
    if [[ -n "$env_file" ]]; then
      serial="$(
        sed -nE 's/^export ANDROID_SERIAL="?([^"]+)"?$/\1/p' \
          "$env_file" | head -n 1
      )"
    fi
  fi
  printf '%s\n' "$serial"
}

# shellcheck disable=SC1091
. /etc/os-release
[[ "$VERSION_ID" == 24.04 ]] && pass "Ubuntu 24.04" || fail "Ubuntu $VERSION_ID"
[[ "$(uname -m)" == x86_64 ]] && pass "x86_64" || fail "$(uname -m)"
(( $(grep -Eoc '\b(vmx|svm)\b' /proc/cpuinfo || true) > 0 )) &&
  pass "Nested virtualization visible" || fail "No VMX/SVM"

for dev in /dev/kvm /dev/net/tun /dev/vhost-net /dev/vhost-vsock; do
  [[ -e "$dev" ]] && pass "$dev exists" || fail "$dev missing"
done

for group in kvm cvdnetwork render; do
  sudo -u "$CVD_USER" id -nG |
    tr ' ' '\n' | grep -qx "$group" &&
    pass "$CVD_USER group $group" ||
    fail "$CVD_USER missing group $group"
done

for pkg in cuttlefish-base cuttlefish-user; do
  dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null |
    grep -q '^ii' &&
    pass "$pkg installed" ||
    fail "$pkg missing"
done

for file in boot.img super.img android-info.txt; do
  [[ -e "$R/$file" ]] && pass "$file" || fail "Missing $file"
done

if [[ -x "$R/bin/cvd_internal_start" ]]; then
  pass "Local launcher cvd_internal_start"
elif [[ -x "$R/bin/launch_cvd" ]]; then
  pass "Local launcher launch_cvd"
else
  fail "No local Cuttlefish launcher"
fi

[[ -n "$ADB" ]] && pass "ADB $ADB" || fail "No adb binary"

SERIAL="$(discover_serial)"
DEVICE=''
for candidate in "$SERIAL" '0.0.0.0:6520' '127.0.0.1:6520'; do
  [[ -n "$candidate" ]] || continue
  adb_cmd connect "$candidate" >/dev/null 2>&1 || true
  state="$(adb_cmd -s "$candidate" get-state 2>/dev/null || true)"
  if [[ "$state" == device ]]; then
    SERIAL="$candidate"
    DEVICE="$candidate"
    break
  fi
done

if [[ -n "$DEVICE" ]]; then
  pass "ADB device $DEVICE"
else
  fail "No Cuttlefish ADB device"
fi

if [[ -n "$DEVICE" ]]; then
  RELEASE="$(adb_cmd -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
  SDK="$(adb_cmd -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
  TYPE="$(adb_cmd -s "$SERIAL" shell getprop ro.build.type | tr -d '\r')"
  DEBUG="$(adb_cmd -s "$SERIAL" shell getprop ro.debuggable | tr -d '\r')"
  BOOT="$(adb_cmd -s "$SERIAL" shell getprop sys.boot_completed | tr -d '\r')"
  SELINUX="$(adb_cmd -s "$SERIAL" shell getenforce | tr -d '\r')"

  if [[ "$RELEASE" == "__EXPECTED_RELEASE__" ]]; then
    pass "Android $RELEASE"
  else
    fail "Android release $RELEASE (expected __EXPECTED_RELEASE__)"
  fi

  if [[ "$SDK" == "__EXPECTED_API__" ]]; then
    pass "API $SDK"
  else
    fail "API $SDK (expected __EXPECTED_API__)"
  fi
  [[ "$TYPE" == userdebug ]] && pass "userdebug" || fail "Build type $TYPE"
  [[ "$DEBUG" == 1 ]] && pass "Debuggable" || fail "Not debuggable"
  [[ "$BOOT" == 1 ]] && pass "Boot complete" || fail "Boot incomplete"
  [[ "$SELINUX" == Enforcing ]] && pass "SELinux Enforcing" || fail "$SELINUX"

  if adb_cmd -s "$SERIAL" root >/dev/null 2>&1; then
    adb_cmd -s "$SERIAL" wait-for-device >/dev/null 2>&1 || true
    pass "adb root"
  else
    fail "adb root"
  fi

  if adb_cmd -s "$SERIAL" \
      shell cmd netpolicy get restrict-background >/dev/null 2>&1; then
    pass "netpolicy query"
  else
    fail "netpolicy query"
  fi

  if adb_cmd -s "$SERIAL" \
      shell dumpsys connectivity >/dev/null 2>&1; then
    pass "connectivity dump"
  else
    fail "connectivity dump"
  fi

  if adb_cmd -s "$SERIAL" \
      shell dumpsys connectivity trafficcontroller >/dev/null 2>&1; then
    pass "TrafficController dump"
  else
    skip "TrafficController subcommand not exposed by this build"
  fi
fi

if ss -lntH 2>/dev/null | grep -qE ':[0-9]*8443\b|:8443\b'; then
  pass "WebRTC TCP 8443 listener"
else
  skip "WebRTC TCP 8443 listener not detected"
fi

echo
echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT SKIP=$SKIP_COUNT"
(( FAIL_COUNT == 0 ))
VALIDATE_HELPER

sudo sed -i "s/__CVD_USER__/$CVD_USER/g" \
  /usr/local/bin/start-android16-cvd \
  /usr/local/bin/stop-android16-cvd \
  /usr/local/bin/validate-android16-lab

sudo sed -i \
  -e "s/__EXPECTED_RELEASE__/$EXPECTED_ANDROID_RELEASE/g" \
  -e "s/__EXPECTED_API__/$EXPECTED_ANDROID_API/g" \
  /usr/local/bin/validate-android16-lab

sudo chmod 0755 \
  /usr/local/bin/start-android16-cvd \
  /usr/local/bin/stop-android16-cvd \
  /usr/local/bin/validate-android16-lab

CURRENT_STAGE="first Cuttlefish launch"
say LAUNCH "Launching Android 16 from the extracted CI host package"

sudo /usr/local/bin/stop-android16-cvd >/dev/null 2>&1 || true

RESET_CVD=0
if (( NEED_EXTRACT )); then
  RESET_CVD=1
fi

sudo env RESET_CVD="$RESET_CVD" \
  /usr/local/bin/start-android16-cvd

CURRENT_STAGE="Android 16 acceptance validation"
say VALIDATE "Checking Android version, API, ADB, SELinux and networking diagnostics"

if ! sudo /usr/local/bin/validate-android16-lab; then
  RELEASE="$(
    sudo -u "$CVD_USER" env HOME="$RUNTIME"       "$RUNTIME/bin/adb" -s 0.0.0.0:6520       shell getprop ro.build.version.release 2>/dev/null |
      tr -d '' || true
  )"
  SDK="$(
    sudo -u "$CVD_USER" env HOME="$RUNTIME"       "$RUNTIME/bin/adb" -s 0.0.0.0:6520       shell getprop ro.build.version.sdk 2>/dev/null |
      tr -d '' || true
  )"

  if [[ -n "$RELEASE" && "$RELEASE" != "$EXPECTED_ANDROID_RELEASE" ]]; then
    cat >&2 <<EOF

[FAIL] ANDROID ARTIFACT VERSION MISMATCH

The Cuttlefish platform itself is working, but the selected device image is:
  Android release : ${RELEASE:-unknown}
  API level       : ${SDK:-unknown}

This lab expects:
  Android release : $EXPECTED_ANDROID_RELEASE
  API level       : $EXPECTED_ANDROID_API

Selected image:
  $IMAGE_ZIP

Remediation:
  1. Download the x86_64 Cuttlefish phone image from the Android 16
     branch/build in Android CI, not a moving latest/Android 17 build.
  2. Keep cvd-host_package.tar.gz from that SAME build.
  3. Move the Android 17 ZIP out of the setup directory, or choose the
     correct ZIP explicitly with CVD_IMAGE_ZIP=/path/to/android16.zip.
  4. Re-run this script. A different image filename forces a clean
     runtime extraction automatically.

The KVM/Cuttlefish host setup does NOT need to be rebuilt manually.
EOF
  fi
  exit 1
fi

CURRENT_STAGE="complete"
say READY "Android 16 Cuttlefish lab setup completed"

VM_IP="$(hostname -I | awk '{print $1}')"

cat <<EOF

============================================================
 LAB READY
============================================================
Runtime:
  $RUNTIME

Android target:
  Android $EXPECTED_ANDROID_RELEASE / API $EXPECTED_ANDROID_API / userdebug

Lifecycle:
  sudo start-android16-cvd
  sudo stop-android16-cvd
  sudo env RESET_CVD=1 start-android16-cvd
  sudo validate-android16-lab

Browser:
  https://${VM_IP}:8443

Setup log:
  $LOG_FILE

No reboot is required by this bootstrap. It reloads groups, modules
and udev state itself, and always launches Cuttlefish as $CVD_USER.
============================================================
EOF
