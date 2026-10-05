#!/usr/bin/env bash
# Run only on the authorized Linux test host with native Ruby and Docker access.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
mkdir -p .artifacts
receipt=$(mktemp -d "$root/.artifacts/woot59-protocol.XXXXXX")
name="woot59-$(basename "$receipt" | tr '[:upper:]' '[:lower:]')"
containers=()
network=''
cleanup() {
  status=$?
  trap - EXIT
  for container in "${containers[@]}"; do
    docker logs "$container" > "$receipt/$container.log" 2>&1 || true
    docker rm -f -v "$container" >/dev/null
  done
  if [[ -n "$network" ]]; then docker network rm "$network" >/dev/null; fi
  printf '%s\n' "$status" > "$receipt/exit-status"
  echo "Receipt: $receipt (exit $status)"
  exit "$status"
}
trap cleanup EXIT
exec > >(tee "$receipt/run.log") 2>&1

dovecot='dovecot/dovecot@sha256:723e3392fe16c6fad8ddc605ea767cc01b4bad9cd9f13eb1dbac15e79c89b2d4'
postgres='pgvector/pgvector@sha256:7b822b0aac60967beb1ea5e576b8602c94c300a157d187f385ae3e0da199b90a'
redis='redis@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0'
for image in "$dovecot" "$postgres" "$redis"; do docker image inspect "$image" --format '{{.Id}} {{json .RepoDigests}}'; done
date -u
hostname
uname -sr
git rev-parse HEAD
git diff --binary HEAD | sha256sum
sha256sum Gemfile.lock .ruby-version ops/imap-message-id/dovecot.conf ops/imap-message-id/run.sh ops/imap-message-id/imap/*.rb app/services/imap/message_id_matcher.rb \
  app/services/imap/mailbox_command/standard.rb app/services/imap/sent_mailbox.rb

eval "$(rbenv init -)"
ruby --version
bundle check
bundle exec ruby -e 'require "bundler/setup"; %w[rails rspec-core net-imap mail].each { |n| puts "#{n}=#{Gem.loaded_specs.fetch(n).version}" }'
network=$(docker network create --internal "$name")
for service in postgres redis dovecot; do
  case "$service" in
    postgres)
      id=$(docker create --name "$name-$service" --network "$network" --cpus 1 --memory 1g --pids-limit 128 \
        -e POSTGRES_PASSWORD=woot59-synthetic-only -e POSTGRES_DB=woot59_test "$postgres") ;;
    redis)
      id=$(docker create --name "$name-$service" --network "$network" --cpus .5 --memory 256m --pids-limit 128 "$redis") ;;
    dovecot)
      id=$(docker create --name "$name-$service" --network "$network" --cpus .5 --memory 256m --memory-swap 256m --pids-limit 128 \
        --tmpfs /srv/vmail:uid=1000,gid=1000 \
        --mount "type=bind,src=$root/ops/imap-message-id/dovecot.conf,dst=/etc/dovecot/dovecot.conf,readonly" "$dovecot") ;;
  esac
  containers+=("$id")
  docker start "$id"
  docker inspect "$id" > "$receipt/$service-inspect.json"
done
address() { docker inspect "$name-$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }
export RAILS_ENV=test
export POSTGRES_HOST="$(address postgres)" POSTGRES_PORT=5432 POSTGRES_DATABASE=woot59_test
export POSTGRES_USERNAME=postgres POSTGRES_PASSWORD=woot59-synthetic-only
export REDIS_URL="redis://$(address redis):6379/0" WOOT59_IMAP_HOST="$(address dovecot)"
# Do not inherit a host database URL in preference to these private synthetic settings.
unset DATABASE_URL
for attempt in {1..30}; do
  if docker exec "$name-postgres" pg_isready -U postgres && docker exec "$name-redis" redis-cli ping; then break; fi
  sleep 1
done
docker exec "$name-dovecot" /dovecot/sbin/dovecot --version
docker exec "$name-dovecot" /dovecot/bin/doveconf -n > "$receipt/dovecot-effective.conf"
bundle exec rails db:schema:load
bundle exec rspec ops/imap-message-id/imap/message_id_matcher_real_spec.rb spec/services/imap --format documentation
