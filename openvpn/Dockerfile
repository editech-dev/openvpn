# syntax=docker/dockerfile:1
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

ARG VERSION=dev
LABEL org.opencontainers.image.title="openvpn" \
      org.opencontainers.image.description="Servidor OpenVPN configurable por variables de entorno" \
      org.opencontainers.image.source="https://github.com/editech-dev/openvpn" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

# La base está fijada por digest (reproducible); los parches de seguridad de Alpine se
# aplican en cada construcción con "apk upgrade". scripts/auto-update.sh cambia
# PATCH_STAMP para invalidar la caché y compara packages.txt para saber si hubo cambios.
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG PATCH_STAMP=none
# hadolint ignore=DL3017,DL3018
RUN echo "patch-stamp: ${PATCH_STAMP}" \
    && apk upgrade --no-cache \
    && apk add --no-cache bash curl openvpn easy-rsa iptables iproute2 openssl socat tini \
    && rm -rf /etc/openvpn/* \
    && mkdir -p /usr/local/share/ovpn \
    && apk info -v | sort >/usr/local/share/ovpn/packages.txt

COPY --chmod=0755 entrypoint.sh healthcheck.sh duckdns.sh ovpnctl /usr/local/bin/
COPY --chmod=0755 lib/ /usr/local/lib/ovpn/

ENV OVPN_DATA_DIR=/etc/openvpn \
    OVPN_RUN_DIR=/run/openvpn

EXPOSE 1194/udp 1194/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=3s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["server"]
