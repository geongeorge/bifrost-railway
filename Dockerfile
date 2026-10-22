# Bifrost AI Gateway, packaged for Railway.
#
# Upstream's image is already Railway-shaped: it binds 0.0.0.0:8080, reads APP_PORT,
# and keeps every store external. Three things are added on top of it:
#
#   1. config.json           seeds admin auth, the Postgres config/logs stores, the
#                            Redis vector store and the semantic-cache plugin, so a
#                            fresh deploy is password-protected from its first request
#                            instead of after someone remembers to turn auth on.
#   2. postgresql-client     used once per boot to create Bifrost's own scoped role and
#                            its UTF8 database. Bifrost requires a UTF8 database created
#                            from template0; Railway's managed Postgres hands out the
#                            superuser and the `railway` database instead.
#   3. railway-entrypoint.sh runs that bootstrap, sizes GOMEMLIMIT from the cgroup, then
#                            execs the image's own entrypoint unchanged.
#
# The upstream version is pinned so a redeploy never picks up a release by surprise.
# Bump it deliberately after reading that release's notes for database migrations.
FROM maximhq/bifrost:v2.3.2

USER root

RUN apk upgrade --no-cache \
 && apk add --no-cache postgresql-client

COPY config.json /app/config.json
COPY railway-entrypoint.sh /app/railway-entrypoint.sh
RUN chmod +x /app/railway-entrypoint.sh \
 && chown appuser:0 /app/config.json /app/railway-entrypoint.sh

# Back to the image's own non-root user. The bootstrap needs psql, not privileges.
USER 1000:0

ENTRYPOINT ["/app/railway-entrypoint.sh"]
CMD ["/app/main"]
