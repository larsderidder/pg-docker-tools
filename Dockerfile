FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

ARG PG_CLIENT_VERSION=16
ARG YQ_VERSION=v4.44.1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    unzip \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt \
    $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    "postgresql-client-${PG_CLIENT_VERSION}" \
  && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/awscliv2.zip /tmp/aws

# Install yq v4
RUN ARCH="$(dpkg --print-architecture)" \
  && curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
  && chmod +x /usr/local/bin/yq

WORKDIR /opt/pgtools

COPY bin/ ./
COPY config.yaml ./

RUN chmod +x /opt/pgtools/*.sh

ENTRYPOINT ["/bin/bash"]
