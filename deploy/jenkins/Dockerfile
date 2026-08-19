FROM jenkins/jenkins:2.568.1-jdk21

ARG KUBECTL_VERSION=v1.36.1
ARG HELM_VERSION=v4.2.0

USER root

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      gosu \
      jq \
      make \
      python3 \
      python3-pip \
      python3-venv \
      shellcheck \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl --fail --silent --show-error --location \
      https://download.docker.com/linux/debian/gpg \
      --output /etc/apt/keyrings/docker.asc \
    && chmod 0644 /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && printf '%s\n' \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install --yes --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

RUN architecture="$(dpkg --print-architecture)" \
    && curl --fail --silent --show-error --location \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${architecture}/kubectl" \
      --output /usr/local/bin/kubectl \
    && curl --fail --silent --show-error --location \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${architecture}/kubectl.sha256" \
      --output /tmp/kubectl.sha256 \
    && printf '%s  %s\n' "$(cat /tmp/kubectl.sha256)" /usr/local/bin/kubectl \
      | sha256sum --check --status \
    && chmod 0755 /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl.sha256

RUN architecture="$(dpkg --print-architecture)" \
    && helm_archive="helm-${HELM_VERSION}-linux-${architecture}.tar.gz" \
    && curl --fail --silent --show-error --location \
      "https://get.helm.sh/${helm_archive}" --output "/tmp/${helm_archive}" \
    && curl --fail --silent --show-error --location \
      "https://get.helm.sh/${helm_archive}.sha256sum" --output "/tmp/${helm_archive}.sha256sum" \
    && cd /tmp \
    && sha256sum --check --status "${helm_archive}.sha256sum" \
    && tar --extract --gzip --file "$helm_archive" \
    && install -m 0755 "linux-${architecture}/helm" /usr/local/bin/helm \
    && rm -rf "/tmp/${helm_archive}" "/tmp/${helm_archive}.sha256sum" "/tmp/linux-${architecture}"

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
ENV JENKINS_UC=https://archives.jenkins.io/updates/dynamic-stable-2.568.1/update-center.actual.json \
    JENKINS_PLUGIN_INFO=https://archives.jenkins.io/updates/current/plugin-versions.json \
    JENKINS_UC_DOWNLOAD_URL=https://archives.jenkins.io/plugins
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY --chown=root:root entrypoint.sh /usr/local/bin/devops-jenkins-entrypoint
RUN chmod 0755 /usr/local/bin/devops-jenkins-entrypoint

USER root
ENTRYPOINT ["/usr/local/bin/devops-jenkins-entrypoint"]
