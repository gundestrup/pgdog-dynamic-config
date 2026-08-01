FROM alpine:3.22

RUN apk add --no-cache postgresql-client tini

WORKDIR /pgdog
COPY pgdog/generate-config.sh /pgdog/generate-config.sh
COPY pgdog/entrypoint.sh /pgdog/entrypoint.sh
RUN chmod +x /pgdog/generate-config.sh /pgdog/entrypoint.sh \
    && adduser -D -H -u 1000 pgdog \
    && chown -R pgdog:pgdog /pgdog

USER pgdog

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/pgdog/entrypoint.sh"]
