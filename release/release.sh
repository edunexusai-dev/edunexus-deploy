#!/usr/bin/env bash
# Builds and switches one production service from a pushed Git commit. Run on the MacBook. See ../RELEASE_HANDBOOK.md.
#   ./release.sh status
#   ./release.sh build   <api|campuscore|strapi> <commit>   source → EC2 → docker build; the live service is not touched
#   ./release.sh backup  <api|campuscore|strapi>            pg_dump of that service's production database
#   ./release.sh migrate <api|campuscore> <tag>             prisma migrate deploy, using the new image
#   ./release.sh switch  <api|campuscore|strapi> <tag>      recreates the service on that image (also the rollback)
# Add --print as the last word to see the script that would run on the server, without running anything.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
ACTION=${1:-}; SERVICE=${2:-}; ARG=${3:-}; PRINT=no
for last; do [ "$last" = --print ] && PRINT=yes; done
[ "$ARG" = --print ] && ARG=; [ "$SERVICE" = --print ] && SERVICE=
die() { echo "release: $*" >&2; exit 1; }

service_settings() {
  case "$SERVICE" in
    api)        REPO=edunexus;      PATHS="backend shared"; DOCKERFILE="-f backend/Dockerfile"; IMAGE=edunexusai-api; TAGVAR=API_TAG;        COMPOSE=api;        DIR=edunexusai; ENVFILE=edunexusai.env; CONTAINER=edunexusai-api; URL=https://api.edunexusai.online/api/v1/health ;;
    campuscore) REPO=campuscoresis; PATHS="";               DOCKERFILE="";                      IMAGE=campuscore-sis; TAGVAR=CAMPUSCORE_TAG; COMPOSE=campuscore; DIR=campuscore; ENVFILE=campuscore.env; CONTAINER=campuscore;     URL=https://sis.edunexusai.online/ ;;
    strapi)     REPO=feddrick-cms;  PATHS="";               DOCKERFILE="";                      IMAGE=feddrick-cms;   TAGVAR=STRAPI_TAG;     COMPOSE=strapi;     DIR=strapi;     ENVFILE=strapi.env;     CONTAINER=strapi;         URL=https://cms.edunexusai.online/_health ;;
    *) die "service must be api, campuscore or strapi" ;;
  esac
}

run_remote() { # $1: script file, $2: timeout
  if [ "$PRINT" = yes ]; then grep -vE '^[A-Za-z0-9+/=]{60,}$' "$1"; return 0; fi
  printf 'About to run "%s %s" on PRODUCTION. Type the word production to continue: ' "$ACTION" "$SERVICE"
  read -r answer; [ "$answer" = production ] || die "cancelled"
  python3 -I "$HERE/ssm-run.py" "$1" "$2"
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
OUT=$WORK/remote.sh

case "$ACTION" in
  status)
    cat > "$OUT" <<'REMOTE'
docker ps --format '{{.Names}} | {{.Image}} | {{.Status}}'
for d in edunexusai campuscore strapi; do grep -H _TAG= /opt/edunexus/$d/.env; done
for c in edunexusai-api campuscore strapi; do echo "--- images of $c"; docker images --format '{{.Repository}}:{{.Tag}} {{.CreatedSince}}' | grep "^$(docker inspect $c --format '{{.Config.Image}}' | cut -d: -f1):"; done
df -h / | tail -1
REMOTE
    SERVICE=all; run_remote "$OUT" 120 ;;

  build)
    service_settings; [ -n "$ARG" ] || die "give a commit"
    REPO_DIR=$ROOT/$REPO
    SHA=$(git -C "$REPO_DIR" rev-parse --verify "$ARG^{commit}")
    [ -n "$(git -C "$REPO_DIR" branch -r --contains "$SHA" 2>/dev/null)" ] || die "$SHA is not on GitHub yet: push it first, so production stays traceable to a commit"
    # shellcheck disable=SC2086
    git -C "$REPO_DIR" archive --format=tar.gz -o "$WORK/src.tgz" "$SHA" $PATHS
    SUM=$(shasum -a 256 "$WORK/src.tgz" | cut -c1-64)
    {
      echo 'set -euo pipefail'
      echo "SHA=$SHA; D=/opt/edunexus/$DIR/src/\$SHA; TAG=$IMAGE:\${SHA:0:12}"
      echo "mkdir -p /opt/edunexus/$DIR/src"
      echo "base64 -d > /tmp/.rel-src.tgz <<'B64'"
      base64 < "$WORK/src.tgz"
      echo 'B64'
      echo "[ \"\$(sha256sum /tmp/.rel-src.tgz | cut -c1-64)\" = $SUM ] && echo 'checksum ok' || { echo CHECKSUM_MISMATCH; exit 1; }"
      echo 'rm -rf "$D"; mkdir -p "$D"; tar -xzf /tmp/.rel-src.tgz -C "$D"; rm -f /tmp/.rel-src.tgz; echo "$SHA" > "$D/.release-sha"'
      echo 'cd "$D"; export DOCKER_BUILDKIT=0'
      echo "set +e; nice -n 10 docker build --pull $DOCKERFILE -t \"\$TAG\" --label org.opencontainers.image.revision=\$SHA . > /opt/edunexus/$DIR/build-\$SHA.log 2>&1; rc=\$?; set -e"
      echo "[ \$rc = 0 ] || { echo BUILD_FAILED; tail -25 /opt/edunexus/$DIR/build-\$SHA.log; exit 1; }"
      echo 'echo "built $TAG (the live service is unchanged)"'
    } > "$OUT"
    run_remote "$OUT" 1500
    echo "Next tag: ${SHA:0:12}" ;;

  backup)
    service_settings
    cat > "$OUT" <<REMOTE
set -euo pipefail
umask 077; W=\$(mktemp -d); trap 'rm -rf "\$W"' EXIT
F=/opt/edunexus/secrets/$ENVFILE; B=/opt/edunexus/backups/$DIR-pre-release-\$(date -u +%Y%m%dT%H%M%SZ).dump
python3 -I - "\$F" "\$W" <<'PY'
import sys, urllib.parse as u
env = dict(l.rstrip('\n').split('=', 1) for l in open(sys.argv[1]) if '=' in l and not l.startswith('#'))
env = {k: v.strip('"') for k, v in env.items()}
if 'DATABASE_URL' in env:
    p = u.urlsplit(env['DATABASE_URL']); host, port, name, user, pw = p.hostname, p.port or 5432, p.path.lstrip('/'), u.unquote(p.username), u.unquote(p.password or '')
else:
    host, port, name, user, pw = env['DATABASE_HOST'], env.get('DATABASE_PORT', 5432), env['DATABASE_NAME'], env['DATABASE_USERNAME'], env['DATABASE_PASSWORD']
open(sys.argv[2] + '/pw', 'w').write(pw)
open(sys.argv[2] + '/conn', 'w').write(f'host={host} port={port} dbname={name} user={user}')
PY
PGPASSWORD="\$(cat \$W/pw)" pg_dump "\$(cat \$W/conn) sslmode=verify-full sslrootcert=/opt/edunexus/$DIR/rds-ca.pem" -Fc --no-owner -f "\$B"
chmod 600 "\$B"; echo "backup \$B \$(stat -c %s "\$B") bytes, table-data sections: \$(pg_restore --list "\$B" | grep -c 'TABLE DATA')"
REMOTE
    run_remote "$OUT" 600 ;;

  migrate)
    service_settings; [ -n "$ARG" ] || die "give the new image tag"
    case "$SERVICE" in
      api) CMD='npx --no-install prisma migrate' ;;
      campuscore) CMD='cd server && npx --no-install prisma migrate' ;;
      strapi) die "Strapi has no Prisma migrations: it updates its own tables when it starts" ;;
    esac
    cat > "$OUT" <<REMOTE
set -euo pipefail
cd /opt/edunexus/$DIR
docker image inspect $IMAGE:$ARG >/dev/null
echo '== before'; $TAGVAR=$ARG docker compose run --rm --no-deps -T --entrypoint sh $COMPOSE -c '$CMD status 2>&1' | grep -E 'migrations found|up to date|not yet applied|failed|^[0-9]{14}_' || true
echo '== deploy'; $TAGVAR=$ARG docker compose run --rm --no-deps -T --entrypoint sh $COMPOSE -c '$CMD deploy 2>&1' | grep -vE 'prisma-config|deprecated|npm notice|^\$'
echo '== after'; $TAGVAR=$ARG docker compose run --rm --no-deps -T --entrypoint sh $COMPOSE -c '$CMD status 2>&1' | grep -E 'up to date|not yet applied|failed'
REMOTE
    run_remote "$OUT" 600 ;;

  switch)
    service_settings; [ -n "$ARG" ] || die "give the image tag"
    cat > "$OUT" <<REMOTE
set -uo pipefail
cd /opt/edunexus/$DIR
docker image inspect $IMAGE:$ARG >/dev/null || { echo "no image $IMAGE:$ARG on the server"; exit 1; }
OLD=\$(grep '^$TAGVAR=' .env | cut -d= -f2)
cp -p .env /opt/edunexus/backups/$DIR-compose.env.pre-switch-\$(date -u +%Y%m%dT%H%M%SZ)
sed -i 's/^$TAGVAR=.*/$TAGVAR=$ARG/' .env
docker compose up -d --no-build $COMPOSE 2>&1 | tail -2
for i in \$(seq 1 60); do h=\$(docker inspect $CONTAINER --format '{{.State.Health.Status}}'); [ "\$h" = healthy ] && break; sleep 3; done
echo "health: \$h  image: \$(docker inspect $CONTAINER --format '{{.Config.Image}}')  previous tag: \$OLD"
echo "public check: \$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 $URL) $URL"
docker logs --since 3m $CONTAINER 2>&1 | grep -iE 'error|fatal' | tail -8 | cut -c1-200 || true
[ "\$h" = healthy ] || { echo "NOT HEALTHY. Roll back with: ./release.sh switch $SERVICE \$OLD"; exit 1; }
REMOTE
    run_remote "$OUT" 300 ;;

  *) sed -n 2,8p "$0"; exit 1 ;;
esac
