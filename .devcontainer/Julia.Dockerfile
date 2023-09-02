ARG BUILD_ON_IMAGE=glcr.b-data.ch/julia/base
ARG JULIA_VERSION=1.9.3

ARG INSTALL_DEVTOOLS
ARG NODE_VERSION
ARG NV=${INSTALL_DEVTOOLS:+${NODE_VERSION:-16.20.2}}

ARG NSI_SFX=${NV:+/}${NV:-:none}${NV:+/debian}${NV:+:bullseye}

FROM ${BUILD_ON_IMAGE}:${JULIA_VERSION} as files

RUN mkdir /files

COPY conf/ipython /files
COPY conf/jupyterlab /files
COPY julia-base/conf/user /files
COPY julia-base/scripts /files
COPY scripts /files

## Ensure file modes are correct when using CI
## Otherwise set to 777 in the target image
RUN find /files -type d -exec chmod 755 {} \; \
  && find /files -type f -exec chmod 644 {} \; \
  && find /files/etc/skel/.local/bin -type f -exec chmod 755 {} \; \
  && find /files/usr/local/bin -type f -exec chmod 755 {} \; \
  && cp -r /files/etc/skel/. /files/root \
  && chmod 700 /files/root

FROM docker.io/koalaman/shellcheck:stable as sci

FROM ${BUILD_ON_IMAGE}:${JULIA_VERSION} as julia

ARG DEBIAN_FRONTEND=noninteractive

ARG BUILD_ON_IMAGE
ARG UNMINIMIZE
ARG JUPYTERLAB_VERSION=3.6.5

ENV PARENT_IMAGE=${BUILD_ON_IMAGE}:${JULIA_VERSION} \
    JUPYTERLAB_VERSION=${JUPYTERLAB_VERSION} \
    PARENT_IMAGE_BUILD_DATE=${BUILD_DATE}

## Unminimise if the system has been minimised
RUN if [ "$(command -v unminimize)" ] && [ -n "$UNMINIMIZE" ]; then \
    yes | unminimize; \
  fi

## Install Python related stuff
  ## Install JupyterLab
RUN pip install --no-cache-dir \
    jupyterlab=="$JUPYTERLAB_VERSION" \
    jupyterlab-git \
    jupyterlab-lsp \
    notebook \
    nbconvert \
    "python-lsp-server[all]" \
## Install Julia related stuff
  && export JULIA_DEPOT_PATH="$JULIA_PATH/local/share/julia" \
  ## Install the Julia kernel for Jupyter
  && julia -e 'using Pkg; Pkg.add(["IJulia", "LanguageServer"]); Pkg.precompile()' \
  && mv /root/.local/share/jupyter/kernels/julia* /usr/local/share/jupyter/kernels/ \
  ## Make installed packages available system-wide
  && julia -e 'using Pkg; Pkg.add(readdir("$(ENV["JULIA_DEPOT_PATH"])/packages"))' \
  && rm -rf "$JULIA_DEPOT_PATH/registries"/* \
  && chmod -R ugo+rx "$JULIA_DEPOT_PATH" \
  ## Clean up
  && rm -rf /tmp/* \
    /root/.cache \
    /root/.ipython \
    /root/.local \
## Dev Container only
  && dpkgArch="$(dpkg --print-architecture)" \
  ## Install hadolint
  && case "$dpkgArch" in \
    amd64) tarArch="x86_64" ;; \
    arm64) tarArch="arm64" ;; \
    *) echo "error: Architecture $dpkgArch unsupported"; exit 1 ;; \
  esac \
  && apiResponse="$(curl -sSL \
    https://api.github.com/repos/hadolint/hadolint/releases/latest)" \
  && downloadUrl="$(echo "$apiResponse" | grep -e \
    "browser_download_url.*Linux-$tarArch\"" | cut -d : -f 2,3 | tr -d \")" \
  && echo "$downloadUrl" | xargs curl -sSLo /usr/local/bin/hadolint \
  && chmod 755 /usr/local/bin/hadolint \
  ## Create folders in root directory
  && mkdir -p /root/.local/bin \
  && mkdir -p /root/projects \
  ## Create folders in skeleton directory
  && mkdir -p /etc/skel/.local/bin \
  && mkdir -p /etc/skel/projects \
  ## Create backup of root directory
  && cp -a /root /var/backups \
  ## Copy user-specific startup file to skeleton directory
  && mkdir -p /etc/skel/.julia/config \
  && cp /var/backups/skel/.julia/config/startup.jl /etc/skel/.julia/config/

## Devtools, Docker
FROM glcr.b-data.ch/nodejs/nsi${NSI_SFX} as nsi

FROM julia

ARG DEBIAN_FRONTEND=noninteractive

ARG NV
ARG INSTALL_DOCKER_CLI

ENV NODE_VERSION=${NV}

  ## Install Node.js...
COPY --from=nsi /usr/local /usr/local

RUN if [ -n "$NV" ]; then \
    ## and other requirements
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bats \
      libkrb5-dev \
      libsecret-1-dev \
      libx11-dev \
      libxkbfile-dev \
      libxt6 \
      quilt \
      rsync; \
    if [ -n "$PYTHON_VERSION" ]; then \
      ## make some useful symlinks that are expected to exist
      ## ("/usr/bin/python" and friends)
      for src in pydoc3 python3; do \
        dst="$(echo "$src" | tr -d 3)"; \
        [ -s "/usr/bin/$src" ]; \
        [ ! -e "/usr/bin/$dst" ]; \
        ln -svT "$src" "/usr/bin/$dst"; \
      done; \
    fi; \
    ## Clean up Node.js installation
    bash -c 'rm -f /usr/local/bin/{docker-entrypoint.sh,yarn*}'; \
    bash -c 'mv /usr/local/{CHANGELOG.md,LICENSE,README.md} \
      /usr/local/share/doc/node'; \
    ## Enable corepack (Yarn, pnpm)
    corepack enable; \
    ## Install nFPM
    echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' \
      | tee /etc/apt/sources.list.d/goreleaser.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nfpm; \
    ## Clean up
    rm -rf /tmp/*; \
    rm -rf /var/lib/apt/lists/* \
      /root/.config \
      /root/.local; \
  fi \
  && if [ -n "$INSTALL_DOCKER_CLI" ]; then \
    ## Install Docker CLI and plugins
    dpkgArch="$(dpkg --print-architecture)"; \
    . /etc/os-release; \
    mkdir -p /etc/apt/keyrings; \
    chmod 0755 /etc/apt/keyrings; \
    pgpKey="$(curl -fsSL "https://download.docker.com/linux/$ID/gpg")"; \
    echo "$pgpKey" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    echo "deb [arch=$dpkgArch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null; \
    apt-get update; \
    apt-get -y install --no-install-recommends \
      docker-ce-cli \
      docker-buildx-plugin \
      docker-compose-plugin \
      "$(test "$dpkgArch" = "amd64" && echo docker-scan-plugin)"; \
    ln -s /usr/libexec/docker/cli-plugins/docker-compose \
      /usr/local/bin/docker-compose; \
    ## Clean up
    rm -rf /var/lib/apt/lists/* \
      /root/.config; \
  fi

## Update environment
ARG USE_ZSH_FOR_ROOT
ARG SET_LANG
ARG SET_TZ

ENV LANG=${SET_LANG:-$LANG} \
    TZ=${SET_TZ:-$TZ}

  ## Change root's shell to ZSH
RUN if [ -n "$USE_ZSH_FOR_ROOT" ]; then \
    chsh -s /bin/zsh; \
  fi \
  ## Update timezone if needed
  && if [ "$TZ" != "Etc/UTC" ]; then \
    echo "Setting TZ to $TZ"; \
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime \
      && echo "$TZ" > /etc/timezone; \
  fi \
  ## Add/Update locale if needed
  && if [ "$LANG" != "en_US.UTF-8" ]; then \
    sed -i "s/# $LANG/$LANG/g" /etc/locale.gen; \
    locale-gen; \
    echo "Setting LANG to $LANG"; \
    update-locale --reset LANG="$LANG"; \
  fi

## Unset environment variable BUILD_DATE
ENV BUILD_DATE=

## Copy files as late as possible to avoid cache busting
COPY --from=files /files /

## Copy shellcheck as late as possible to avoid cache busting
COPY --from=sci --chown=root:root /bin/shellcheck /usr/local/bin
