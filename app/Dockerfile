# Fixed-response HTTP service for the AI-DLC reference deployment.
#
# Base: nginx-unprivileged, stable line, Alpine. Runs as a non-root user (uid 101)
# and listens on 8080, so no capability to bind a low port is needed.
# Pinned by multi-arch index digest: the tag is for humans, the digest is what is
# pulled. Update both together. 1.30.6-alpine3.24 == stable-alpine on 2026-11-18.
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03

# The whole application: one static file served at /.
COPY index.html /usr/share/nginx/html/index.html

# The base image already sets a non-root USER; nothing here changes it.
EXPOSE 8080
