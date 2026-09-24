# Proxy de saída (egress) do dev-sandbox. É o ÚNICO caminho do sandbox para
# a internet: o sandbox só está na rede interna "devnet", sem gateway.
# Libera por nome de domínio (allowlist.txt), não por IP.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends squid \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf.template /etc/squid/squid.conf.template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0644 /etc/squid/squid.conf.template && chmod 0755 /usr/local/bin/entrypoint.sh

# Squid roda direto como o usuário "proxy" (criado pelo pacote), sem root.
USER proxy
EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
