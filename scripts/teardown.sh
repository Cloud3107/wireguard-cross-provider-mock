#!/usr/bin/env bash
   # Removes the lab. Use --wg-only to reset just WireGuard (fixes key mismatches).
   set -uo pipefail
 
   docker rm -f bm-server wg-gateway-provider-a 2>/dev/null
   sudo rm -rf "$HOME/wg-mock/config" "$HOME/wg-mock/bm-config"
 
   if [ "${1:-}" = "--wg-only" ]; then
     echo "WireGuard reset done. Run ./scripts/setup.sh again."
     exit 0
   fi
 
   docker rm -f vpc-redis 2>/dev/null
   docker network rm provider-b-net 2>/dev/null
   kind delete cluster --name provider-a
   sudo rm -rf "$HOME/wg-mock"
   echo "Everything removed."
