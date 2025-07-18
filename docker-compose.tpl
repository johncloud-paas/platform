version: '3.8'

services:
  traefik:
    image: traefik:v2.9
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro    # Swarm API for Docker provider
      - traefik-certs:/letsencrypt                     # Persist ACME certs
    command:
      # Enable Swarm provider and disable default exposure
      - "--providers.docker.swarmmode=true"
      - "--providers.docker.endpoint=unix:///var/run/docker.sock"
      - "--providers.docker.exposedbydefault=false"
      # HTTP entrypoint and redirect to HTTPS
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      # HTTPS entrypoint
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.http.tls=true"
      # Let's Encrypt (ACME) configuration
      - "--certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web"
      - "--entrypoints.websecure.http.tls.certresolver=le"
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        # (Optional) Traefik dashboard on HTTPS
        - "traefik.http.routers.traefik.rule=Host(`traefik.${HOST}`)"
        - "traefik.http.routers.traefik.entrypoints=websecure"
        - "traefik.http.routers.traefik.service=api@internal"
        - "traefik.http.routers.traefik.tls=true"
        - "traefik.http.services.traefik.loadbalancer.server.port=8080"

  whoami:
    image: traefik/whoami
    deploy:
      replicas: 1
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.whoami.rule=Host(`whoami.${HOST}`)"
        - "traefik.http.routers.whoami.entrypoints=websecure"
        - "traefik.http.routers.whoami.tls=true"
        - "traefik.http.routers.whoami.tls.certresolver=le"
        - "traefik.http.services.whoami.loadbalancer.server.port=80"

  portainer:
    image: portainer/portainer-ee:latest
    container_name: portainer
    restart: unless-stopped
    depends_on:
      - traefik
    volumes:
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    deploy:
      replicas: 1
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portainer.rule=Host(`portainer.$HOST`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls.certresolver=le"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

volumes:
  traefik-certs:
  portainer_data:

networks:
  default:
    driver: overlay
    attachable: true
