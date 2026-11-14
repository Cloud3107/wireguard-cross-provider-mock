This guide sets up a mock where a "bare-metal" server in Provider B reaches a protected Redis inside Provider A's network, but only through a
   WireGuard tunnel. It includes every fix from our troubleshooting.
 
   Architecture
 
     provider-b-net                                     kind network
     (Provider B)                                       (Provider A "VPC")
    ┌─────────────┐   WireGuard UDP 51820   ┌───────────────────────┐      ┌────────────┐
    │  bm-server  │ ──────────────────────▶ │ wg-gateway-provider-a │ ───▶ │ vpc-redis  │
    │ 10.13.13.2  │      tunnel (wg0)       │ 10.13.13.1            │ NAT  │ port 6379  │
    └─────────────┘                         └───────────────────────┘      └────────────┘
      no direct route                        attached to BOTH networks
      to the kind network                    (acts as its "public IP")
 
   Ground rules (these avoid most of the errors we hit)
 
   - Paste long commands as one line. Multi-line commands with \ broke during pasting, which caused the "1000:latest" and "No such container" errors.
   Every long command below is a single line.
   - Run each part in the same terminal. Variables like $REDIS_IP and $GW_IP are lost when you open a new window.
   - Never delete ~/wg-mock/config once the gateway is running. It holds the gateway's keys. Deleting it means new keys and a key mismatch.
 
   ---
   Part 1: Prepare Windows
 
   1.1 Install WSL2 and Ubuntu
 
   In PowerShell as Administrator:
 
   wsl --install
 
   Restart, then create your Ubuntu username and password when the console window opens. Check the version:
 
   wsl --list --verbose
 
   The VERSION column should say 2. If it says 1, run wsl --set-version Ubuntu 2.
 
   1.2 Install Docker Desktop
 
   1. Install Docker Desktop and tick "Use the WSL 2 based engine" during setup.
   2. Go to Settings → Resources → WSL Integration. Enable the default distro and turn on the Ubuntu switch.
   3. Click Apply & restart.
 
   Then check from the Ubuntu terminal:
 
   docker ps
 
   An empty table with no errors means it works.
 
   ---
   Part 2: Install the tools inside Ubuntu (WSL2)
 
   2.1 Install kubectl (choose one method only)
 
   Method A: apt repository (recommended, updates with apt upgrade)
 
   sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg
   sudo mkdir -p -m 755 /etc/apt/keyrings
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee
   /etc/apt/sources.list.d/kubernetes.list
   sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update && sudo apt-get install -y kubectl
 
   Method B: direct binary download
 
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl
 
   Check it:
 
   kubectl version --client
   which -a kubectl
 
   which -a should show only one real path. /bin/kubectl and /usr/bin/kubectl are the same file, so seeing both is fine.
 
   2.2 Install kind
 
   curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-amd64
   file ./kind
 
   file must say ELF 64-bit. If it says HTML, the download is wrong; see Troubleshooting T4.
 
   chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
   kind version
 
   ---
   Part 3: Provider A (cluster, Redis and WireGuard gateway)
 
   3.1 Create the kind cluster
 
   kind create cluster --name provider-a
   kubectl get nodes
 
   This also creates a Docker network called kind.
 
   3.2 Deploy the protected Redis
 
   docker run -d --name vpc-redis --network kind redis:7-alpine
 
   3.3 Start the WireGuard gateway
 
   mkdir -p ~/wg-mock/config
 
   docker run -d --name wg-gateway-provider-a --cap-add=NET_ADMIN --network kind -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -e
   SERVERURL=host.docker.internal -e SERVERPORT=51820 -e PEERS=baremetal1 -e PEERDNS=auto -e ALLOWEDIPS=0.0.0.0/0 -p 51820:51820/udp -v
   ~/wg-mock/config:/config ghcr.io/linuxserver/wireguard:latest
 
   Unable to find image ... locally is normal; Docker then downloads the image. It worked if the last line is a long container ID. If the download
   fails, change the image to lscr.io/linuxserver/wireguard:latest.
 
   3.4 Wait until the peer config exists
 
   until docker exec wg-gateway-provider-a test -f /config/peer_baremetal1/peer_baremetal1.conf; do echo "waiting..."; sleep 3; done; echo "peer config
   ready"
 
   ---
   Part 4: Provider B (the bare-metal server)
 
   4.1 Create Provider B's network and attach the gateway to it
 
   docker network create provider-b-net
   docker network connect provider-b-net wg-gateway-provider-a
 
   network connect prints nothing when it succeeds. Attaching the gateway gives the client a direct path to it. Going through host.docker.internal
   (192.168.65.254) failed on Docker Desktop.
 
   4.2 Build the client config from the gateway's live copy
 
   Reading the file from inside the gateway means you can't pick up a stale copy with old keys.
 
   mkdir -p ~/wg-mock/bm-config/wg_confs
   docker exec wg-gateway-provider-a cat /config/peer_baremetal1/peer_baremetal1.conf > ~/wg-mock/bm-config/wg_confs/wg0.conf
 
   4.3 Check the keys match
 
   GW_KEY=$(docker exec wg-gateway-provider-a wg show wg0 public-key)
   CL_KEY=$(awk '/^PublicKey/{print $3}' ~/wg-mock/bm-config/wg_confs/wg0.conf)
   [ "$GW_KEY" = "$CL_KEY" ] && echo "KEYS MATCH" || echo "KEYS DIFFER - see Troubleshooting T11"
 
   4.4 Point the client at the gateway and limit the tunnel to the kind network
 
   KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
   GW_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "provider-b-net").IPAddress}}' wg-gateway-provider-a)
   echo "kind=$KIND_SUBNET gw=$GW_IP"
 
   Both values must be filled in, for example kind=172.18.0.0/16 gw=172.19.0.3. The next command refuses to run if either is empty:
 
   [ -n "$KIND_SUBNET" ] && [ -n "$GW_IP" ] && sed -i "s|^AllowedIPs.*|AllowedIPs = 10.13.13.0/24, $KIND_SUBNET|; s|^Endpoint.*|Endpoint =
   $GW_IP:51820|; /^DNS/d" ~/wg-mock/bm-config/wg_confs/wg0.conf && cat ~/wg-mock/bm-config/wg_confs/wg0.conf || echo "STOP: a value is empty"
 
   This makes three changes:
   - Endpoint is set to the gateway's direct IP on provider-b-net.
   - AllowedIPs covers only the tunnel range and the kind subnet. That means the --sysctl flag isn't needed, and that flag was what caused the "OCI
   runtime create failed" error.
   - The DNS line is removed, because it often fails inside containers.
 
   4.5 Start the bare-metal server
 
   The config must be at /config/wg_confs/wg0.conf, so mount bm-config, not the gateway's peer folder.
 
   docker run -d --name bm-server --cap-add=NET_ADMIN --network provider-b-net -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -v ~/wg-mock/bm-config:/config
   ghcr.io/linuxserver/wireguard:latest
 
   4.6 Check the tunnel
 
   sleep 10
   docker exec bm-server wg show
 
   The tunnel is up when:
   - endpoint is 172.19.x.x:51820
   - there's a latest handshake: X seconds ago line
   - transfer shows more than 0 B received
 
   ---
   Part 5: Gateway routing (usually automatic)
 
   The LinuxServer image adds the forwarding and NAT rules itself when the gateway starts. Check that they're there:
 
   docker exec wg-gateway-provider-a iptables -t nat -S POSTROUTING
 
   If you see a MASQUERADE line, you're done. If it's missing, add the rules:
 
   docker exec wg-gateway-provider-a iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth+ -j MASQUERADE
   docker exec wg-gateway-provider-a iptables -A FORWARD -i wg0 -j ACCEPT
   docker exec wg-gateway-provider-a iptables -A FORWARD -o wg0 -j ACCEPT
 
   ---
   Part 6: Verification
 
   6.1 Get the Redis IP
 
   REDIS_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' vpc-redis); echo $REDIS_IP
 
   6.2 Check isolation (tunnel DOWN): this should fail
 
   docker exec bm-server wg-quick down wg0
   docker exec bm-server sh -c "echo PING | nc -w 3 $REDIS_IP 6379"
 
   There should be no output, which means there's no direct path. ping may also say "Network unreachable"; that's correct here.
 
   6.3 Check connectivity (tunnel UP): this should succeed
 
   docker exec bm-server wg-quick up wg0
   docker exec bm-server sh -c "echo PING | nc -w 3 $REDIS_IP 6379"
 
   You should get +PONG. That means Provider B reached Redis in Provider A, but only through the tunnel.
 
   6.4 Check the routes
 
   docker exec bm-server ip route
 
   The kind subnet (for example 172.18.0.0/16) should go via dev wg0, never via eth0.
 
   ---
   Troubleshooting (every problem we hit, and its fix)
 
   Installation
 
   
#	Symptom	Cause	Fix
T1	gpg: no valid OpenPGP data found	The old guide's URL (https://k8s.io) returns a web page, not a key	Use the pkgs.k8s.io/.../Release.key URL from 2.1. Delete the broken file first: 
sudo rm -f /etc/apt/keyrings/kubernetes-archive-keyring.gpg
T2	chmod: cannot access ... kubernetes.list	The echo ... | sudo tee line broke while pasting, so the file was never created	Rerun the echo line as one line, then check with: 
cat /etc/apt/sources.list.d/kubernetes.list
T3	kubectl reports an unexpected version / which -a shows two copies	Both install methods were used	Keep one copy: 
sudo rm /usr/local/bin/kubectl && hash -r (keeps the apt copy) 
or

   Full WireGuard reset (fixes T14, or any mix of old and new keys)
 
   This leaves the kind cluster and Redis alone.
 
   docker rm -f bm-server wg-gateway-provider-a
   sudo rm -rf ~/wg-mock/config ~/wg-mock/bm-config
 
   Then redo 3.3 → 4.6. You can skip docker network create in 4.1 if the network already exists.
 
   One-shot diagnostic (paste the output when asking for help)
 
   REDIS_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' vpc-redis)
   echo "=== REDIS_IP: $REDIS_IP"
   echo "=== containers"; docker ps -a --format '{{.Names}}  {{.Status}}'
   echo "=== client wg"; docker exec bm-server wg show
   echo "=== client routes"; docker exec bm-server ip route
   echo "=== client config"; grep -E 'Address|AllowedIPs|Endpoint|PublicKey' ~/wg-mock/bm-config/wg_confs/wg0.conf
   echo "=== gateway key"; docker exec wg-gateway-provider-a wg show wg0 public-key
   echo "=== gateway wg"; docker exec wg-gateway-provider-a wg show
   echo "=== gateway NAT"; docker exec wg-gateway-provider-a iptables -t nat -S POSTROUTING
   echo "=== redis test"; docker exec bm-server sh -c "echo PING | nc -w 3 $REDIS_IP 6379"
 
   ---
   Day-to-day operations
 
   After a laptop or Docker Desktop restart
 
   docker start vpc-redis wg-gateway-provider-a bm-server
   sleep 10 && docker exec bm-server wg show
 
   If the handshake is gone, the gateway's IP on provider-b-net may have changed. Rerun 4.4, then docker restart bm-server.
 
   Tear everything down
 
   docker rm -f bm-server wg-gateway-provider-a vpc-redis
   docker network rm provider-b-net
   kind delete cluster --name provider-a
   sudo rm -rf ~/wg-mock
   ---
   What changed from your original guide
 
   ┌─────────────────────────────────────┬───────────────────────────────────────────────────┬─────────────────────────────────────────────────────┐
   │           Original guide            │                   Fixed version                   │                         Why                         │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ kubectl key and repo from           │ pkgs.k8s.io/core:/stable:/v1.36/deb/              │ The original URL returns HTML (T1)                  │
   │ https://k8s.io                      │                                                   │                                                     │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ kind from https://k8s.io            │ GitHub releases kind-linux-amd64                  │ The original URL returns HTML (T4)                  │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ Multi-line docker run ... \         │ Single-line commands                              │ Pasting broke them (T7)                             │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ Gateway on the kind network only    │ Also attached to provider-b-net                   │ host.docker.internal UDP failed (T13)               │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ bm-server mounts                    │ Mounts bm-config with wg_confs/wg0.conf           │ The image needs that layout (T10)                   │
   │ peer_baremetal1:/config             │                                                   │                                                     │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ Client AllowedIPs = 0.0.0.0/0       │ 10.13.13.0/24, <kind subnet>                      │ No --sysctl needed, and it's closer to a real       │
   │                                     │                                                   │ private link (T11)                                  │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ Config copied from the host folder  │ Read from inside the gateway, then the keys are   │ Prevents stale keys (T14)                           │
   │                                     │ checked                                           │                                                     │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ Manual iptables MASQUERADE          │ Check first; add only if missing                  │ The image adds the rules automatically              │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ nc -zv connection test              │ echo PING | nc → +PONG                            │ BusyBox nc is silent (T16)                          │
   ├─────────────────────────────────────┼───────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
   │ Isolation test done once            │ Tunnel down → fail, tunnel up → PONG              │ Shows the tunnel is the only path                   │
   └─────────────────────────────────────┴───────────────────────────────────────────────────┴─────────────────────────────────────────────────────┘
