#!/usr/bin/env bash
# build-install-device.sh — CLI build → install → launch on Stan's iPhone 13 Pro
#
# Usage:
#   ./Scripts/build-install-device.sh
#
# Run from the bjj-annotate-ios repo root. No arguments needed; UDIDs are
# baked below. Xcode automatic signing (-allowProvisioningUpdates) re-issues
# the personal-team cert if it has expired (7-day free-team expiry is expected).
#
# TRAPS:
#   Trap 1: CODE_SIGNING_ALLOWED=NO must NOT appear in project.pbxproj.
#           This script never passes that flag — it's for simulator tests only.
#   Trap 2: After install, if iPhone shows "Untrusted Developer", go to
#           Settings → General → VPN & Device Management → trust the cert.
#           That one step genuinely requires the device; you only need it after
#           each re-sign (every 7 days under a free personal team).

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
XCODEBUILD_UDID="00008110-000C50622244801E"          # xcodebuild device id
DEVICECTL_ID="0DDCD5D2-8726-58CC-8A7A-766F7C6AB23F" # xcrun devicectl identifier
BUNDLE_ID="com.stanxxy.bjjannotate"
SCHEME="BJJAnnotate"
WORKSPACE="BJJAnnotate.xcodeproj/project.xcworkspace"
DERIVED_DATA="build"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphoneos/BJJAnnotate.app"
# ───────────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== BJJAnnotate — CLI device build+install+launch ==="
echo "  UDID (xcodebuild):  ${XCODEBUILD_UDID}"
echo "  ID   (devicectl):   ${DEVICECTL_ID}"
echo "  Bundle:             ${BUNDLE_ID}"
echo ""

# Sanity-check: Trap 1
if grep -q "CODE_SIGNING_ALLOWED" BJJAnnotate.xcodeproj/project.pbxproj 2>/dev/null; then
    echo "ERROR: CODE_SIGNING_ALLOWED found in project.pbxproj — device build would fail."
    echo "  Remove it (it belongs only on simulator xcodebuild test CLI flags)."
    exit 1
fi
echo "[trap-1] CODE_SIGNING_ALLOWED absent in project.pbxproj — OK"

# ─── Step 1: Build ─────────────────────────────────────────────────────────────
echo ""
echo "=== Step 1: xcodebuild clean build for device ==="
xcodebuild \
    -scheme "${SCHEME}" \
    -workspace "${WORKSPACE}" \
    -destination "platform=iOS,id=${XCODEBUILD_UDID}" \
    -allowProvisioningUpdates \
    -derivedDataPath "${DERIVED_DATA}" \
    clean build \
    | tee /tmp/bjjannotate-build.log \
    | grep -E "^\*\*|error:|warning:|Build Succeeded|Build FAILED|CompileSwift|Linking" || true

# Check exit status of xcodebuild (not the grep)
if ! grep -q "BUILD SUCCEEDED" /tmp/bjjannotate-build.log 2>/dev/null; then
    echo ""
    echo "ERROR: Build failed. Full log at /tmp/bjjannotate-build.log"
    echo "Last 40 lines:"
    tail -40 /tmp/bjjannotate-build.log
    exit 1
fi
echo ""
echo "=== Step 1 PASSED: Build succeeded ==="

# ─── Step 2: Verify .app exists ────────────────────────────────────────────────
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found after build."
    exit 1
fi
echo "=== Step 2 PASSED: .app at ${APP_PATH} ==="

# ─── Step 3: Install ───────────────────────────────────────────────────────────
echo ""
echo "=== Step 3: xcrun devicectl install ==="
xcrun devicectl device install app \
    --device "${DEVICECTL_ID}" \
    "${APP_PATH}"
echo "=== Step 3 PASSED: Install complete ==="

# ─── Step 4: Launch ────────────────────────────────────────────────────────────
echo ""
echo "=== Step 4: xcrun devicectl launch ==="
xcrun devicectl device process launch \
    --device "${DEVICECTL_ID}" \
    "${BUNDLE_ID}"
echo "=== Step 4 PASSED: App launched on device ==="

echo ""
echo "=== Done. BJJAnnotate is running on iPhone 13 Pro. ==="
echo "  If the app shows 'Untrusted Developer', trust it in:"
echo "  Settings → General → VPN & Device Management → ${BUNDLE_ID}"
