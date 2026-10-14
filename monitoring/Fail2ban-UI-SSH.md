# fail2ban-ui — SSH connector setup

How the rootless **fail2ban-ui** container controls the host's **rootful** Fail2ban, and
how the ban/unban event callbacks get back to the UI. Most of this is provisioned
automatically by `monitoring/setup_before_up.sh`; the only manual action is adding the
server once in the UI.

See [Monitoring.md](Monitoring.md#ban-management-ui-fail2ban-ui) for where this fits in the
monitoring stack.

## Why SSH (and not the Local connector)

Fail2ban runs rootful on the host. Its control socket (`/var/run/fail2ban/fail2ban.sock`,
`root:root 0600`) and `/etc/fail2ban` are root-owned, so the **Local** connector would need a
**rootful** container (a rootless one maps to an unprivileged host subuid and gets `EACCES` on
the socket). To keep the UI rootless like the rest of the stack, it uses the **SSH connector**:
the container SSHes to the host as a dedicated service account that has *narrow* sudo for
`fail2ban-client`, and edits `/etc/fail2ban` through a filesystem ACL.

```
┌─────────────────────────┐        control path (SSH, port 22)        ┌──────────────────┐
│ fail2ban-ui (rootless)  │ ───────────────────────────────────────▶ │ host sshd        │
│  container in monitoring│   ssh sa_fail2ban@host.docker.internal    │  → sudo          │
│                         │   sudo fail2ban-client … / systemctl …    │    fail2ban-client│
│                         │                                           │  rootful Fail2ban │
│                         │ ◀───────────────────────────────────────  │                  │
│   :<uiPort>             │   event path: ssh -R <tunnelPort>:        │  ui-custom-action │
└─────────────────────────┘      localhost:<uiPort>  (reverse tunnel) │  POST localhost   │
                                                                       └──────────────────┘
```

## What `setup_before_up.sh` provisions (automatic)

Runs on every `./startstack.sh monitoring` (idempotent), when `sudo` is available. Account name
defaults to `sa_fail2ban` (`FAIL2BAN_UI_SSH_USER`).

1. **Service account** — `useradd --system --create-home --shell /bin/bash sa_fail2ban`
   (login shell for SSH, no password, key-only).
2. **SSH key** — generates `ed25519` keypair once at
   `$JOHNCLOUD_ROOT/fail2ban-ui/.ssh/sa_fail2ban_ed25519` — this is the container's
   `/config/.ssh/sa_fail2ban_ed25519`, so the UI reads it directly. The public key is authorized
   in `sa_fail2ban`'s `~/.ssh/authorized_keys`.
3. **Minimal sudo** — `/etc/sudoers.d/fail2ban-ui`, validated with `visudo -cf`:
   ```
   sa_fail2ban ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client *, /usr/bin/systemctl restart fail2ban
   ```
4. **Config ACL** — `setfacl -R [-d] -m u:sa_fail2ban:rwX /etc/fail2ban` so the UI can read/write
   jail and filter config over SSH.
5. **Reverse-tunnel prerequisites** — warns if `sshd` `AllowTcpForwarding` is off (the reverse
   tunnel needs `ssh -R`) or if host `jq`/`curl` are missing (the callback action uses them).

The container reaches the host via `host.docker.internal:host-gateway` (set in the compose
`extra_hosts`).

## The one manual step: add the server in the UI

The server record and the reverse-tunnel toggle live in fail2ban-ui's SQLite and are created
through the UI (or the OIDC-gated `POST /api/servers`), so they are **not** scripted.

1. Open the UI at `https://fail2ban.$HOST` (Authentik login) → **Manage Servers** → add a server:
   - **Host:** `host.docker.internal`
   - **Port:** `22`
   - **User:** `sa_fail2ban`
   - **SSH key:** `/config/.ssh/sa_fail2ban_ed25519`
2. Enable **reverse tunnel for events**. Set the tunnel port to `FAIL2BAN_UI_TUNNEL_PORT`
   (1024–65535) if you set one in `.env`; blank uses the UI's own port.
3. **Test** — should report healthy. Once the tunnel is up, `health.callbackOk` becomes true.

On first connection the connector also installs its own `ui-custom-action.conf` into
`/etc/fail2ban/action.d/` and attaches it to the jails — nothing to hand-author.

## The reverse tunnel / event path

The SSH connector reads live ban state over the control connection. For the **real-time
dashboard**, the UI opens a reverse tunnel over its existing SSH session:

```
ssh -R <tunnelPort>:localhost:<uiPort>
```

Each ban/unban then triggers `ui-custom-action.conf`, which does:

```
POST http://localhost:<tunnelPort>/api/ban   (or /api/unban)
X-Callback-Secret: <secret>
{ "serverId": "...", "ip": "...", "jail": "...", "hostname": "...", ... }
```

Because the callback travels inside the SSH connection, **the UI needs no inbound port** and the
host that can't otherwise reach the container still delivers events. The UI re-checks and
reconnects broken tunnels about every 45 seconds.

## Relevant `.env` variables

| Variable | Default | Purpose |
|---|---|---|
| `FAIL2BAN_UI_SSH_USER` | `sa_fail2ban` | Service account name provisioned on the host. |
| `FAIL2BAN_UI_TUNNEL_PORT` | *(blank)* | Reverse-tunnel port; set the same value in the UI. Blank = UI port. |

(OIDC and port variables are documented in `sample.env` / Monitoring.md.)

## Verification

```bash
bash -n monitoring/setup_before_up.sh        # script syntax

# after ./startstack.sh monitoring:
getent passwd sa_fail2ban                     # account exists
sudo -l -U sa_fail2ban                        # shows ONLY the two allowed commands
getfacl /etc/fail2ban | grep sa_fail2ban      # rwX ACL present
ls -l $JOHNCLOUD_ROOT/fail2ban-ui/.ssh        # sa_fail2ban_ed25519{,.pub}
```

End-to-end event (UI must show it live):

```bash
sudo fail2ban-client set suricata banip 203.0.113.9
sudo fail2ban-client set suricata unbanip 203.0.113.9
```

## Troubleshooting

- **Test fails / host unreachable.** The container must reach the host `sshd` via
  `host.docker.internal`. Confirm the rootless Docker network has host connectivity and `sshd`
  listens on an interface reachable from it.
- **Host key prompt / strict checking.** First connection needs the host key trusted; accept the
  fingerprint when adding the server (persisted in `/config/.ssh/known_hosts`).
- **Callbacks don't arrive (`callbackOk` false).** Ensure `sshd` has `AllowTcpForwarding yes`
  (the script warns if not) and that host `jq`/`curl` are installed. Check that the chosen
  `FAIL2BAN_UI_TUNNEL_PORT` is free on the host.
- **Permission denied running fail2ban-client.** Re-run `./startstack.sh monitoring` to reinstall
  the sudoers file; verify with `sudo -l -U sa_fail2ban`.
- **UI can't edit jails.** `setfacl` must be installed; re-run the setup so the `/etc/fail2ban`
  ACL is applied.

## Security notes

- The key is passphraseless (unattended SSH) but the account is tightly scoped: only two sudo
  commands, and `/etc/fail2ban` write is granted via ACL — no general root.
- The callback endpoint is authenticated by `X-Callback-Secret` and travels encrypted inside the
  SSH tunnel; it is never exposed as an inbound port.
- Do not expose the UI directly to the internet — it sits behind Authentik OIDC and Traefik.
