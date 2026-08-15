FROM swift:6.3.3-noble@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea AS build

WORKDIR /source
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
COPY Migrations ./Migrations
RUN swift build -c release --product snippets-server \
    && swift build -c release --product snippets-migrate \
    && install -D -m 0755 .build/release/snippets-server /output/snippets-server \
    && install -D -m 0755 .build/release/snippets-migrate /output/snippets-migrate

FROM swift:6.3.3-noble-slim@sha256:39b558fbd38edb169c94b009286e84e9dd08d509f11eff332ca148e5fd453971 AS runtime

FROM runtime AS migrate

COPY --from=build /output/snippets-migrate /usr/local/bin/snippets-migrate
COPY --from=build /source/Migrations /opt/snippets/Migrations
USER 65532:65532
WORKDIR /opt/snippets
ENTRYPOINT ["snippets-migrate"]

# Keep the public service as the final/default target. It contains neither the
# migration executable nor SQL even when an operator runs plain `docker build`.
FROM runtime AS server

COPY --from=build /output/snippets-server /usr/local/bin/snippets-server
# Dedicated unprivileged numeric identity; no writable home or shell is needed.
USER 65532:65532
WORKDIR /opt/snippets
EXPOSE 8080
ENTRYPOINT ["snippets-server"]
