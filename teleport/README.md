# Teleport

Teleport Community Edition — certificate-based SSH, web terminal, Kubernetes, and database access behind Traefik.

Traefik terminates external TLS; Teleport's web proxy listens on port 3080 and always serves **HTTPS** (self-signed cert when ACME is disabled). Traefik connects to it as an HTTPS backend — this works because `serversTransport.insecureSkipVerify: true` is set globally in Traefik's static config. The auth service (port 3025) is internal only — nodes reach it via the proxy's reverse tunnel, never directly.

## Configuration

`config/teleport.yaml` is generated from `config/teleport.template.yaml` by `setup_before_up.sh` using `envsubst`. Edit the template, never the generated file. `startstack.sh` runs the setup script automatically before bringing the stack up.

## Prerequisites

- `teleport` entry in Infisical at path `/teleport` with the variables listed in `sample.env`
- DNS record `teleport.<HOST>` pointing at the server

## Deploy

**1. Create the data directory:**
```bash
mkdir -p $JOHNCLOUD_ROOT/teleport/data
```

**2. Start the stack:**
```bash
./startstack.sh teleport prod
```

**3. Create the first admin user** (one-time, after the container is healthy):
```bash
docker exec -it teleport-teleport-1 tctl users add admin \
  --roles=editor,access \
  --logins=<your-linux-username>
```

Open the invite URL it prints to set up MFA and a password.

## Register the host as a node

Run this on the Ubuntu host itself (install the `teleport` binary v17 from https://goteleport.com/docs/installation/):

```bash
# Generate a one-time join token
TOKEN=$(docker exec teleport-teleport-1 tctl tokens add --type=node --format=text)

# Write the node config
teleport node configure \
  --auth-server=teleport.<HOST>:443 \
  --token="$TOKEN" \
  --output=file:///etc/teleport/teleport-node.yaml

# Enable and start the node agent
sudo systemctl enable --now teleport
```

The node connects outbound via reverse tunnel — no extra ports need to be opened on Gerbil.

## Add more nodes

For any other host reachable from the internet (or via WireGuard):

```bash
# On the Teleport server
TOKEN=$(docker exec teleport-teleport-1 tctl tokens add --type=node --format=text)
```

Then on the target host:
```bash
teleport node configure \
  --auth-server=teleport.<HOST>:443 \
  --token="$TOKEN" \
  --output=file:///etc/teleport/teleport-node.yaml
sudo systemctl enable --now teleport
```

## Day-2 operations

| Task | Command |
|------|---------|
| List nodes | `docker exec -it teleport-teleport-1 tctl nodes ls` |
| List users | `docker exec -it teleport-teleport-1 tctl users ls` |
| Create join token | `docker exec -it teleport-teleport-1 tctl tokens add --type=node` |
| Reset user password | `docker exec -it teleport-teleport-1 tctl users reset <user>` |
| View audit log | Teleport web UI → Activity |

## Architecture

```
Internet
  └── Gerbil :443
        └── Traefik (shared netns, TLS termination)
              └── teleport.<HOST> → teleport container :3080 (HTTPS, self-signed)
                                      ├── web UI + tsh
                                      ├── WebSocket SSH sessions
                                      └── reverse tunnels from nodes :3025 (internal)
```

Key notes:
- The distroless image's ENTRYPOINT is `dumb-init -- teleport start`, so the compose `command` only passes flags (`--config ...`), not the `teleport start` prefix.
- Teleport v17 always serves HTTPS on port 3080 via TLS ALPN SNI multiplexing — there is no plain HTTP mode. Pangolin's `targets[0].method=https` is required; Traefik's global `insecureSkipVerify: true` handles the self-signed cert.
- `public_addr` is set to `teleport.<HOST>:443` so `tsh` and the web UI generate correct links despite TLS being terminated by Traefik.
