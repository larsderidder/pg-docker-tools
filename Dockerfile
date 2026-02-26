FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

ARG PG_CLIENT_VERSION=16
ARG YQ_VERSION=v4.44.1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    "postgresql-client-${PG_CLIENT_VERSION}" \
  && rm -rf /var/lib/apt/lists/*

# Install yq v4
RUN curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  && chmod +x /usr/local/bin/yq

WORKDIR /opt/pgtools

COPY bin/ ./
COPY config.yaml ./

RUN chmod +x /opt/pgtools/*.sh

ENTRYPOINT ["/bin/bash"]
