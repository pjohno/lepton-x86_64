#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify opt-in unmasking is restricted to the private runtime network path.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=/dev/null
source "$ROOT/compat_tool/liblepton/networking.sh"
podman_cmdline() { printf '%s\n' "$*"; }
is_sysbake() { [[ "$MOCK_SYSBAKE" == true ]]; }
setup_podman_port_forwards() { :; }
lepton_port_offset() { echo 0; }
podman_subnet() { echo 192.0.2; }
podman_ip() { echo 192.0.2.2; }
print() { printf '%s\n' "$*"; }
MOCK_SYSBAKE=false
export LEPTON_NETWORK_SYSCTLS=false
normal="$(setup_podman_network)"
[[ "$normal" == *'--network=pasta:'* && "$normal" != *unmask* ]]
export LEPTON_NETWORK_SYSCTLS=true
enabled="$(setup_podman_network)"
[[ "$enabled" == *'--network=pasta:'* && "$enabled" == *'--security-opt unmask=/proc/sys'* ]]
[[ "$enabled" != *'unmask=ALL'* && "$enabled" != *'--network=host'* ]]
MOCK_SYSBAKE=true
bake="$(setup_podman_network)"
[[ "$bake" == '--network=none' ]]
export LEPTON_NO_PORT_FORWARDING=true LEPTON_NO_DEBUG_PORTS=true
isolated="$(podman_network_options)"
[[ "$isolated" == *'-t,none,-u,none'* ]]
echo 'PASS: network sysctls require opt-in and stay outside sysbake/host network paths'
