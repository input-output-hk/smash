ARG UBUNTU_VERSION=20.04
FROM ubuntu:${UBUNTU_VERSION} as haskell-builder
ARG CABAL_VERSION=3.2.0.0
ARG GHC_VERSION=8.6.5
ARG IOHK_LIBSODIUM_GIT_REV=66f017f16633f2060db25e17c170c2afa0f2a8a1
ENV DEBIAN_FRONTEND=nonintercative
RUN mkdir -p /app/src
WORKDIR /app
RUN apt-get update -y && apt-get install -y \
  automake=1:1.16.1-4ubuntu6 \
  build-essential \
  g++=4:9.3.0-1ubuntu2 \
  curl \
  git \
  jq \
  libffi-dev=3.3-4 \
  libghc-postgresql-libpq-dev=0.9.4.2-1build1 \
  libgmp-dev=2:6.2.0+dfsg-4 \
  libncursesw5=6.2-0ubuntu2 \
  libpq-dev=12.4-0ubuntu0.20.04.1 \
  libssl-dev=1.1.1f-1ubuntu2 \
  libsystemd-dev=245.4-4ubuntu3.2 \
  libtinfo-dev=6.2-0ubuntu2 \
  libtool=2.4.6-14 \
  make \
  pkg-config \
  tmux \
  wget \
  zlib1g-dev=1:1.2.11.dfsg-2ubuntu1
RUN wget --secure-protocol=TLSv1_2 \
  https://downloads.haskell.org/~cabal/cabal-install-${CABAL_VERSION}/cabal-install-${CABAL_VERSION}-x86_64-unknown-linux.tar.xz &&\
  tar -xf cabal-install-${CABAL_VERSION}-x86_64-unknown-linux.tar.xz &&\
  rm cabal-install-${CABAL_VERSION}-x86_64-unknown-linux.tar.xz cabal.sig &&\
  mv cabal /usr/local/bin/
RUN cabal update
WORKDIR /app/ghc
RUN wget --secure-protocol=TLSv1_2 \
  https://downloads.haskell.org/~ghc/${GHC_VERSION}/ghc-${GHC_VERSION}-x86_64-deb9-linux.tar.xz &&\
  tar -xf ghc-${GHC_VERSION}-x86_64-deb9-linux.tar.xz &&\
  rm ghc-${GHC_VERSION}-x86_64-deb9-linux.tar.xz
WORKDIR /app/ghc/ghc-${GHC_VERSION}
RUN ./configure && \
  make install
WORKDIR /app/src
RUN git clone https://github.com/input-output-hk/libsodium.git &&\
  cd libsodium &&\
  git fetch --all --tags &&\
  git checkout ${IOHK_LIBSODIUM_GIT_REV}
WORKDIR /app/src/libsodium
RUN ./autogen.sh && \
  ./configure && \
  make && \
  make install ..
ENV LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
ENV PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
COPY . /app/src/smash
WORKDIR /app/src/smash
RUN cabal install smash \
  --install-method=copy \
  --installdir=/usr/local/bin
# Cleanup for runtiume-base copy of /usr/local/lib
RUN rm -rf /usr/local/lib/ghc-${GHC_VERSION} /usr/local/lib/pkgconfig

# Install postgresql
FROM ubuntu:${UBUNTU_VERSION}
RUN apt-get update -y && apt-get install -y \
  curl \
  gnupg \
  wget \
  lsb-release
RUN curl --proto '=https' --tlsv1.2 -sSf -L https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
RUN echo "deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main" | tee  /etc/apt/sources.list.d/pgdg.list
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  postgresql-client-12
COPY --from=haskell-builder /usr/local/lib /usr/local/lib
COPY --from=haskell-builder /usr/local/bin/smash-exe /usr/local/bin/
COPY ./schema /schema
COPY ./scripts/docker-entrypoint.sh /entrypoint.sh
RUN mkdir /ipc
EXPOSE 3100
ENTRYPOINT ["./entrypoint.sh"]
