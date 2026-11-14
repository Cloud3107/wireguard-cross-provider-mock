  #!/usr/bin/env bash
   # Proves the tunnel is the ONLY path: down = no access, up = +PONG.
   set -uo pipefail
 
   REDIS_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' vpc-redis)
   redis_ping() { docker exec bm-server sh -c "echo PING | nc -w 3 $REDIS_IP 6379" 2>&1 || true; }
 
   echo "Redis IP: $REDIS_IP"
 
   echo "==> Tunnel DOWN (expect no access)"
   docker exec bm-server wg-quick down wg0 >/dev/null 2>&1
   if [[ "$(redis_ping)" == PONG ]]; then echo "FAIL: Redis reachable without tunnel - isolation broken"; ISO=1; else echo "PASS: isolated"; ISO=0;
   fi
 
   echo "==> Tunnel UP (expect +PONG)"
   docker exec bm-server wg-quick up wg0 >/dev/null 2>&1
   sleep 3
   if [[ "$(redis_ping)" == PONG ]]; then echo "PASS: +PONG through tunnel"; TUN=0; else echo "FAIL: no PONG - run ./scripts/diagnose.sh"; TUN=1; fi
 
   echo "==> Routes on bm-server"
   docker exec bm-server ip route
 
   exit $((ISO + TUN))
