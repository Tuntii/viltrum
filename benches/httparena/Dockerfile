FROM debian:bookworm-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends ca-certificates curl unzip git gcc libc6-dev libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# V 0.5.2 release (the version viltrum's CI pins).
RUN curl -fsSL -o /tmp/v.zip https://github.com/vlang/v/releases/download/0.5.2/v_linux.zip && \
    unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip
ENV PATH=/opt/v:$PATH

# The entry parks /async-db on Ctx.suspend and App.wake, so this ref has to be a
# viltrum that contains them. ce28bc7 is that commit. After this branch merges,
# point it at the merge commit or the release tag that includes it.
ARG VILTRUM_REF=33d6612d8e7d3f3ed3c8cad1da4aa7aec7372e78
RUN git clone --depth 1 --branch ${VILTRUM_REF} https://github.com/Tuntii/viltrum /root/.vmodules/viltrum

WORKDIR /app
COPY main.v pg.h ./
RUN v -cc gcc -prod -o server main.v

FROM debian:bookworm-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080 8081 8082 8443 9000
CMD ["/server"]
