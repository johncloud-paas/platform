# Access a service protected by Pangolin SSO

This scenario describes the path of a public request to a **resource protected by Pangolin
SSO**. Access control is handled by the **`badger`** middleware
(`github.com/fosrl/badger`) loaded in Traefik: on every request, `badger` queries Pangolin
to validate the session and permissions before granting access to the backend.

```mermaid
sequenceDiagram
  autonumber
  Internet->>fail2ban: Allows traffic
  fail2ban->>Gerbil: Pass https traffic and terminate WG
  Gerbil->>Traefik: Pass traffic
  Traefik->>Pangolin: Check SSO through badger MW
  Pangolin->>Traefik: Permission status
  Traefik->>whoami: Terminate SSL and pass clear traffic to service
  whoami->>Traefik: Service response
  Traefik->>Gerbil: Service response
  Gerbil->>Internet: Service response
```

## Step-by-step walkthrough

1. **Internet → fail2ban — `Allows traffic`.** The client's request arrives on the machine.
   **fail2ban** checks that the source IP address is not banned before letting the traffic
   through.

2. **fail2ban → Gerbil — `Pass https traffic and terminate WG`.** The HTTPS traffic reaches
   **Gerbil**, the ingress gateway, which terminates the WireGuard tunnel and forwards the
   traffic.

3. **Gerbil → Traefik — `Pass traffic`.** Gerbil hands the traffic to **Traefik** (reverse
   proxy) via the shared network namespace.

4. **Traefik → Pangolin — `Check SSO through badger MW`.** Since the resource is protected,
   Traefik applies the **`badger`** middleware, which queries **Pangolin** (`VERIFY`) to
   validate the user's session and permissions.

5. **Pangolin → Traefik — `Permission status`.** Pangolin returns the access status:
   - an **unauthenticated** request → redirect to the Pangolin SSO login page;
   - an **authorized** request → Traefik continues to the backend (next step).

6. **Traefik → whoami — `Terminate SSL and pass clear traffic to service`.** Once access is
   validated, Traefik terminates TLS and forwards the request in clear to the `whoami`
   backend container.

7. **whoami → Traefik — `Service response`.** The service processes the request and returns
   its response to Traefik.

8. **Traefik → Gerbil — `Service response`.** Traefik re-encrypts the response and forwards
   it to Gerbil.

9. **Gerbil → Internet — `Service response`.** Gerbil returns the response to the
   authenticated client.
