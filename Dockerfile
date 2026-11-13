FROM alpine:latest

RUN apk add --no-cache ca-certificates curl bash python3 tar

WORKDIR /render

ARG TS_VERSION=1.104.5
RUN curl -fsSL https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz | tar -xz -C /tmp && \
    mv /tmp/tailscale_${TS_VERSION}_amd64/tailscaled /render/tailscaled && \
    mv /tmp/tailscale_${TS_VERSION}_amd64/tailscale /render/tailscale && \
    chmod +x /render/tailscaled /render/tailscale && \
    rm -rf /tmp/*

COPY entrypoint.sh /render/entrypoint.sh
COPY server.py /render/server.py
RUN chmod +x /render/entrypoint.sh

ENV PORT=10000
EXPOSE 10000

CMD ["/render/entrypoint.sh"]
