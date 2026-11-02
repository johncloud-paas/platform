# Troubleshooting: core stack unreachable after reboot (2026-11-01 / 2026-11-02)

## Symptom

After a host reboot (2026-10-31 14:08), every service behind Traefik was unreachable from the
internet. Traefik's ACME HTTP-01 challenge failed with `Timeout during connect (likely firewall
problem)`. Nothing in the compose files had changed.

## Root cause

`netfilter-persistent` (enabled) restores `/etc/iptables/rules.v4` at boot. That file was saved in
July 2024 while an old **rootful** Docker setup was running, so it contains Docker-generated NAT
rules for containers that no longer exist:

```
*nat
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
-A DOCKER ! -i br-48b6f44e9e25 -p tcp --dport 80  -j DNAT --to-destination 192.168.205.10:80
-A DOCKER ! -i br-48b6f44e9e25 -p tcp --dport 443 -j DNAT --to-destination 192.168.205.10:443
(+ 8082, mail ports 25/110/143/465/587/993/995, Couchbase ports)
```

Every inbound SYN to the host on 80/443 is DNATed to `192.168.205.10`, which doesn't exist, and is
dropped (`FORWARD policy DROP`). It never reaches rootlesskit's listener on `0.0.0.0:80/443`, so
Gerbil/Traefik never see it.

Proof: `iptables -t nat -L DOCKER -nv` showed 11,795 packets DNATed on dpt:80 and 34,357 on dpt:443
since boot.

Why it worked before the reboot (likely): rootful Docker (used for Suricata) rebuilds its own `DOCKER`
nat chain when it starts, wiping these stale entries. After this reboot rootful Docker had not
started, so the stale rules from `rules.v4` stayed active.

## How it was narrowed down

| Check | Result |
|---|---|
| `ss -tlnp` | rootlesskit listens on `0.0.0.0:80/443`; Gerbil publishes them |
| `curl 127.0.0.1:80` | Traefik answers (404). Loopback is excluded from Docker's OUTPUT DNAT jump |
| `curl 188.165.234.144:80` from host | stuck in `SYN-SENT` |
| Plain `ncat` listener on public IP port 19999 | reachable. No DNAT rule for that port |
| `ss` on 80/443 | zero connections from the internet while SSH (22) has many |
| `lsmod` | nf_tables + ~2,200 iptables-nft rules loaded (an earlier "no firewall" conclusion was wrong: `sudo` had silently failed) |
| Rootless network driver | ruled out. Previous working boot used the same `gvisor-tap-vsock` + `builtin` (from user journal `-b -1`) |
| Fail2ban | only the `sshd` jail (port 22); Suricata jail not installed |
| CrowdSec bouncer | disabled; CrowdSec not installed |
| OVH network firewall | disabled |
| `iptables -t nat -L DOCKER -nv` | stale DNAT rules for 80/443 with large packet counters, which confirms the cause |

## Fix procedure

Run each step and check its result before going to the next one. All commands run on the host.

### Step 1: Unblock 80/443 now (until the next reboot)

```
sudo iptables -t nat -F DOCKER
```

This is safe because rootful Docker isn't running, so nothing current uses this chain. Check that the stale rules are
gone (expect no output):

```
sudo iptables -t nat -S DOCKER | grep DNAT
```

### Step 2: Check it's reachable from outside

From a machine other than the server:

```
curl -v http://pangolin.johncloud.fr/
```

Expected: an HTTP response from Traefik (a 404 or a redirect is fine), not a timeout.

### Step 3: Let the certificates be issued

Traefik retries ACME on its own. To watch it:

```
cd ~/repos/johncloud_paas/platform/core
infisical run --env=prod --path=core -- docker compose logs -f traefik | grep -iE 'acme|certificate'
```

Expected: the `Timeout during connect` errors stop. If nothing happens after about 10 minutes:

```
infisical run --env=prod --path=core -- docker compose restart traefik
```

### Step 4: Back up the saved firewall rules

```
sudo cp -a /etc/iptables/rules.v4 /etc/iptables/rules.v4.bak-2026-11-02
sudo cp -a /etc/iptables/rules.v6 /etc/iptables/rules.v6.bak-2026-11-02
```

### Step 5: Make a cleaned copy without the Docker-generated rules

```
sudo grep -vE 'DOCKER|br-[0-9a-f]{12}|docker0|-s 192\.168\.20[0-9]\.[0-9./]+ .*-j MASQUERADE' \
  /etc/iptables/rules.v4 | sudo tee /root/rules.v4.clean >/dev/null
sudo grep -vE 'DOCKER|br-[0-9a-f]{12}|docker0' \
  /etc/iptables/rules.v6 | sudo tee /root/rules.v6.clean >/dev/null
```

### Step 6: Review what was removed

```
sudo diff /etc/iptables/rules.v4 /root/rules.v4.clean
sudo diff /etc/iptables/rules.v6 /root/rules.v6.clean
```

Check:

- Only Docker lines are removed (`:DOCKER…` chains, `-j DOCKER`, `br-…`, the `192.168.20x` MASQUERADE lines).
- These lines are still in the clean file: `-A INPUT -s 178.215.236.0/24 -j DROP`, `194.169.175.0/24`, `80.94.95.0/24`,
  and the `f2b-sshd` lines.
- Each table (`*filter`, `*nat`, …) still ends with `COMMIT`.

If anything else was removed, stop and review before going further.

### Step 7: Check the syntax

```
sudo iptables-restore --test < /root/rules.v4.clean && echo v4 OK
sudo ip6tables-restore --test < /root/rules.v6.clean && echo v6 OK
```

### Step 8: Install the cleaned files

```
sudo install -m 640 -o root -g root /root/rules.v4.clean /etc/iptables/rules.v4
sudo install -m 640 -o root -g root /root/rules.v6.clean /etc/iptables/rules.v6
```

Don't run `netfilter-persistent save` or restart it now. That would reload or overwrite the live Fail2ban
chains. The new files take effect at the next boot.

### Step 9: Fix Newt (a separate issue)

Newt fails with `No newt found with that newtId`: the `NEWT_ID`/`NEWT_SECRET` in Infisical don't match
any Newt in Pangolin's database.

1. Open `https://pangolin.johncloud.fr`. If the setup page appears, complete it with the setup token printed
   in the Pangolin logs.
2. Under **Sites**, create a Newt site (or regenerate the credentials of the existing one), and copy the **ID** and **Secret**.
3. Update `NEWT_ID` and `NEWT_SECRET` in Infisical, env `prod`, path `/core`.
4. Restart Newt and check that it connects:

   ```
   infisical run --env=prod --path=core -- docker compose up -d newt
   infisical run --env=prod --path=core -- docker compose logs -f newt
   ```

   Expected: no more `No newt found with that newtId` errors.

### Step 10: Check after the next reboot

```
sudo iptables -t nat -S | grep -c DNAT     # expect 0 (or only rules from a running rootful Docker)
curl -v http://pangolin.johncloud.fr/      # from outside
```

### Rollback

```
sudo cp -a /etc/iptables/rules.v4.bak-2026-11-02 /etc/iptables/rules.v4
sudo cp -a /etc/iptables/rules.v6.bak-2026-11-02 /etc/iptables/rules.v6
```
