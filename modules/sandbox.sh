# shellcheck shell=bash
# @cortado-module sandbox
# @default true
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 1
# @description Sandbox lock indicator
# @config SANDBOX_ICON:string
# ABOUTME: Sandbox indicator module - shows a lock icon when running in an macOS app sandbox
# ABOUTME: Detects sandbox via the APP_SANDBOX_CONTAINER_ID environment variable

# =============================================================================
# Sandbox Module - Shows lock icon when in macOS app sandbox
# =============================================================================
# Configuration options:
#   SANDBOX_ICON - Icon to display (default: 🔒)
# =============================================================================

module_sandbox() {
    # Only show when running in a sandbox
    [ -n "${APP_SANDBOX_CONTAINER_ID:-}" ] || return

    local icon=$(get_icon "${SANDBOX_ICON:-🔒}" "SANDBOX")
    echo "$icon"
}
