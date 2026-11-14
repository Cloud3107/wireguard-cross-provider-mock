   #!/usr/bin/env bash
   # One-shot diagnostic - paste the full output when asking for help.
   REDIS_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' vpc-redis 2>/dev/null)
   echo "=== REDIS_IP: $REDIS_IP"
   echo "=== containers"; docker ps -a --format '{{.Names}}  {{.Status}}'
   echo "=== client wg"; docker exec bm-server wg show
   echo "=== client routes"; docker exec bm-server ip route
   echo "=== client config"; grep -E 'Address|AllowedIPs|Endpoint|PublicKey' ~/wg-mock/bm-config/wg_confs/wg0.conf
   echo "=== gateway key"; docker exec wg-gateway-provider-a wg show wg0 public-key
   echo "=== gateway wg"; docker exec wg-gateway-provider-a wg show
   echo "=== gateway ip_forward"; docker exec wg-gateway-provider-a cat /proc/sys/net/ipv4/ip_forward
   echo "=== gateway NAT"; docker exec wg-gateway-provider-a iptables -t nat -S POSTROUTING
   echo "=== redis test"; docker exec bm-server sh -c "echo PING | nc -w 3 $REDIS_IP 6379"
   echo "=== bm-server logs"; docker logs bm-server 2>&1 | tail -15
 
   Note that wg show prints private keys only for the interface, and this script calls it without showkeys, so the private keys are hidden. Still, look
   over the output before you paste it anywhere public.
