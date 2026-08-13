FROM swift:6.3.3-noble AS build

WORKDIR /source
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Migrations ./Migrations
RUN swift build -c release --product snippets-server \
    && swift build -c release --product snippets-migrate \
    && install -D -m 0755 .build/release/snippets-server /output/snippets-server \
    && install -D -m 0755 .build/release/snippets-migrate /output/snippets-migrate

FROM swift:6.3.3-noble-slim

COPY --from=build /output/snippets-server /usr/local/bin/snippets-server
COPY --from=build /output/snippets-migrate /usr/local/bin/snippets-migrate
COPY --from=build /source/Migrations /opt/snippets/Migrations
# Dedicated unprivileged numeric identity; no writable home or shell is needed.
USER 65532:65532
WORKDIR /opt/snippets
EXPOSE 8080
ENTRYPOINT ["snippets-server"]
