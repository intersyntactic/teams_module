# syntax=docker/dockerfile:1
# The Teams relay as a scratch image. `dart compile exe` produces a
# standalone AOT binary, but it still dynamically links against libc, the
# ICU data and CA roots that live under dart:stable's /runtime/ — copying
# that whole tree is what makes a `FROM scratch` runtime work at all.
FROM dart:stable AS build
WORKDIR /app

# is_annotation_shapes is a git dependency over SSH (see pubspec.yaml), so
# `dart pub get` below needs an agent-forwarded key — see --ssh in the
# workflow's build step. known_hosts has to be seeded first or that clone
# fails on an interactive host-key prompt that a CI run can never answer.
RUN mkdir -p -m 0700 /root/.ssh && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts

COPY pubspec.yaml pubspec.lock ./
RUN --mount=type=ssh dart pub get

COPY bin/teams_relay.dart bin/teams_relay.dart
COPY lib/ lib/
RUN dart compile exe bin/teams_relay.dart -o /app/teams_relay

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/teams_relay /app/teams_relay

EXPOSE 8087
ENTRYPOINT ["/app/teams_relay"]
