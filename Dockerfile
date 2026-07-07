FROM alpine:3.20

# TARGETARCH is provided by buildx (amd64 / arm64).
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.31.4

RUN apk add --no-cache jq curl ca-certificates \
 && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl

COPY reaper.sh /usr/local/bin/reaper.sh
RUN chmod +x /usr/local/bin/reaper.sh

# Only reads the mounted ServiceAccount token and calls the API — no local writes.
USER 65534:65534

ENTRYPOINT ["/bin/sh", "/usr/local/bin/reaper.sh"]
