# syntax=docker/dockerfile:1
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

ARG VERSION=dev
LABEL org.opencontainers.image.title="openvpn" \
      org.opencontainers.image.description="Servidor OpenVPN configurable por variables de entorno" \
      org.opencontainers.image.source="https://github.com/editech-dev/openvpn" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

# Versiones fijadas por la imagen base (digest); Dependabot la actualiza.
# hadolint ignore=DL3018
RUN apk add --no-cache bash openvpn easy-rsa iptables iproute2 openssl socat tini \
    && rm -rf /etc/openvpn/*

COPY --chmod=0755 entrypoint.sh healthcheck.sh ovpnctl /usr/local/bin/
COPY --chmod=0755 lib/ /usr/local/lib/ovpn/

ENV OVPN_DATA_DIR=/etc/openvpn \
    OVPN_RUN_DIR=/run/openvpn

EXPOSE 1194/udp 1194/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["server"]
