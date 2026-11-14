nano scripts/setup.sh
 
   #!/usr/bin/env bash
   # Builds the WireGuard cross-provider mock lab (Provider A + Provider B).
   # Safe to re-run: reuses what already exists and always rebuilds bm-server.
   set -euo pipefail
 
   IMAGE="${WG_IMAGE:-ghcr.io/linuxserver/wireguard:latest}"
   CONFIG_DIR="$HOME/wg-mock/config"
   BM_DIR="$HOME/wg-mock/bm-config"
 
   exists() { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }
 
   echo "==> [1/7] Provider A: kind cluster"
   kind get clusters 2>/dev/null | grep -qx provider-a || kind create cluster --name provider-a
 
   echo "==> [2/7] Protected Redis"
   exists vpc-redis || docker run -d --name vpc-redis --network kind redis:7-alpine
   docker start vpc-redis >/dev/null
 
   echo "==> [3/7] WireGuard gateway"
   mkdir -p "$CONFIG_DIR"
   exists wg-gateway-provider-a || docker run -d --name wg-gateway-provider-a --cap-add=NET_ADMIN --network kind -e PUID=1000 -e PGID=1000 -e
   TZ=Etc/UTC -e SERVERURL=host.docker.internal -e SERVERPORT=51820 -e PEERS=baremetal1 -e PEERDNS=auto -e ALLOWEDIPS=0.0.0.0/0 -p 51820:51820/udp -v
   "$CONFIG_DIR":/config "$IMAGE"
   docker start wg-gateway-provider-a >/dev/null
   echo "    waiting for peer config and wg0..."
   until docker exec wg-gateway-provider-a test -f /config/peer_baremetal1/peer_baremetal1.conf 2>/dev/null; do sleep 3; done
   until docker exec wg-gateway-provider-a wg show wg0 >/dev/null 2>&1; do sleep 2; done
 
   echo "==> [4/7] Provider B network (gateway attached as its 'public IP')"
   docker network inspect provider-b-net >/dev/null 2>&1 || docker network create provider-b-net
   docker inspect -f '{{json .NetworkSettings.Networks}}' wg-gateway-provider-a | grep -q '"provider-b-net"' || docker network connect provider-b-net
   wg-gateway-provider-a
 
   echo "==> [5/7] Client config (read from the gateway's live copy)"
   mkdir -p "$BM_DIR/wg_confs"
   docker exec wg-gateway-provider-a cat /config/peer_baremetal1/peer_baremetal1.conf > "$BM_DIR/wg_confs/wg0.conf"
 
   KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -v ':' | grep -v '^$' | head -1)
   GW_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "provider-b-net").IPAddress}}' wg-gateway-provider-a)
   echo "    kind subnet=$KIND_SUBNET  gateway ip=$GW_IP"
   if [ -z "$KIND_SUBNET" ] || [ -z "$GW_IP" ]; then echo "ERROR: kind subnet or gateway IP is empty"; exit 1; fi
 
   sed -i "s|^AllowedIPs.|AllowedIPs = 10.13.13.0/24, $KIND_SUBNET|; s|^Endpoint.|Endpoint = $GW_IP:51820|; /^DNS/d" "$BM_DIR/wg_confs/wg0.conf"
 
   GW_KEY=$(docker exec wg-gateway-provider-a wg show wg0 public-key)
   CL_KEY=$(awk '/^PublicKey/{print $3}' "$BM_DIR/wg_confs/wg0.conf")
   if [ "$GW_KEY" != "$CL_KEY" ]; then echo "ERROR: keys differ - run ./scripts/teardown.sh --wg-only, then setup again"; exit 1; fi
   echo "    keys match"
 
   echo "==> [6/7] Bare-metal server (Provider B)"
   docker rm -f bm-server >/dev/null 2>&1 || true
   docker run -d --name bm-server --cap-add=NET_ADMIN --network provider-b-net -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -v "$BM_DIR":/config "$IMAGE"
   >/dev/null
 
   echo "==> [7/7] End-to-end test"
   sleep 10
   REDIS_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' vpc-redis)
   OUT=$(docker exec bm-server sh -c "echo PING | nc -w 3 $REDIS_IP 6379" 2>&1 || true)
   if [[ "$OUT" == PONG ]]; then
     echo "SUCCESS: bm-server reached Redis ($REDIS_IP) through the tunnel"
   else
     echo "FAILED: no PONG. Run ./scripts/diagnose.sh"; exit 1
   fi
