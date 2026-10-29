# The self-hosted server image plus the bot box's tools (docs/bot-box.md):
# bubblewrap and socat, and the shell tools the Cloud image gives bots.
ARG BASE_IMAGE=openmausbot-server:local
FROM ${BASE_IMAGE}
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends bubblewrap socat python3 poppler-utils unzip \
  && rm -rf /var/lib/apt/lists/* \
  && bwrap --version
USER maus
