FROM alpine:3.24.3

# TARGETARCH is provided by buildx (amd64 / arm64).
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.36.5

RUN apk add --no-cache jq curl ca-certificates \
 && KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSLo /usr/local/bin/kubectl "${KUBECTL_URL}" \
 && echo "$(curl -fsSL "${KUBECTL_URL}.sha256")  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl

COPY reaper.sh /usr/local/bin/reaper.sh
RUN chmod +x /usr/local/bin/reaper.sh

# Only reads the mounted ServiceAccount token and calls the API — no local writes.
USER 65534:65534

ENTRYPOINT ["/bin/sh", "/usr/local/bin/reaper.sh"]
