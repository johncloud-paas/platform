# Accéder à un service protégé par le SSO Pangolin

Ce scénario décrit le parcours d'une requête publique vers une **ressource protégée par le
SSO Pangolin**. Le contrôle d'accès est assuré par le middleware **`badger`**
(`github.com/fosrl/badger`) chargé dans Traefik : à chaque requête, `badger` interroge
Pangolin pour valider la session et les droits avant d'autoriser l'accès au backend.

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

## Déroulé étape par étape

1. **Internet → fail2ban — `Allows traffic`.** La requête du client arrive sur la machine.
   **fail2ban** vérifie que l'adresse IP source n'est pas bannie avant de laisser passer le
   trafic.

2. **fail2ban → Gerbil — `Pass https traffic and terminate WG`.** Le trafic HTTPS atteint
   **Gerbil**, la passerelle d'ingress, qui termine le tunnel WireGuard et transmet le
   trafic.

3. **Gerbil → Traefik — `Pass traffic`.** Gerbil remet le trafic à **Traefik** (reverse
   proxy) via le namespace réseau partagé.

4. **Traefik → Pangolin — `Check SSO through badger MW`.** La ressource étant protégée,
   Traefik applique le middleware **`badger`**, qui interroge **Pangolin** (`VERIFY`) pour
   valider la session et les droits de l'utilisateur.

5. **Pangolin → Traefik — `Permission status`.** Pangolin renvoie le statut d'accès :
   - requête **non authentifiée** → redirection vers la page de connexion SSO Pangolin ;
   - requête **autorisée** → Traefik poursuit vers le backend (étape suivante).

6. **Traefik → whoami — `Terminate SSL and pass clear traffic to service`.** Une fois
   l'accès validé, Traefik termine le TLS et transmet la requête en clair au conteneur
   backend `whoami`.

7. **whoami → Traefik — `Service response`.** Le service traite la requête et renvoie sa
   réponse à Traefik.

8. **Traefik → Gerbil — `Service response`.** Traefik rechiffre la réponse et la transmet à
   Gerbil.

9. **Gerbil → Internet — `Service response`.** Gerbil renvoie la réponse au client
   authentifié.
