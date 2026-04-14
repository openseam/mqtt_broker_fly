FROM emqx/emqx:5.8.9

# Install jq for JSON parsing in the bootstrap script
USER root
RUN apt-get update -qq && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*

# Copy bootstrap script — runs as emqx user
COPY --chown=emqx:emqx bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh

USER emqx

# Override entrypoint with bootstrap wrapper.
# CMD is preserved from base image: ["/opt/emqx/bin/emqx", "foreground"]
# bootstrap.sh passes CMD args through to the original docker-entrypoint.sh.
ENTRYPOINT ["/bootstrap.sh"]
CMD ["/opt/emqx/bin/emqx", "foreground"]
