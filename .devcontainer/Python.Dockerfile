ARG BUILD_ON_IMAGE=glcr.b-data.ch/python/base
ARG PYTHON_VERSION=3.11.4

ARG INSTALL_DEVTOOLS
ARG NODE_VERSION
ARG NV=${INSTALL_DEVTOOLS:+${NODE_VERSION:-16.20.1}}

FROM ${BUILD_ON_IMAGE}:${PYTHON_VERSION} as files

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN mkdir /files

COPY conf/ipython /files
COPY conf/jupyterlab /files
COPY scripts /files

## Ensure file modes are correct when using CI
## Otherwise set to 777 in the target image
RUN find /files -type d -exec chmod 755 {} \; \
  && find /files -type f -exec chmod 644 {} \; \
  && find /files/etc/skel/.local/bin -type f -exec chmod 755 {} \; \
  && find /files/usr/local/bin -type f -exec chmod 755 {} \; \
  && cp -r /files/etc/skel/. /files/root \
  && chmod 700 /files/root

FROM ${BUILD_ON_IMAGE}:${PYTHON_VERSION} as python

ARG DEBIAN_FRONTEND=noninteractive

ARG BUILD_ON_IMAGE
ARG UNMINIMIZE
ARG JUPYTERLAB_VERSION=3.6.5

ENV PARENT_IMAGE=${BUILD_ON_IMAGE}:${PYTHON_VERSION} \
    JUPYTERLAB_VERSION=${JUPYTERLAB_VERSION} \
    PARENT_IMAGE_BUILD_DATE=${BUILD_DATE}

SHELL ["/bin/sh", "-c"]

## Unminimise if the system has been minimised
RUN if [ $(command -v unminimize) ] && [ ! -z "$UNMINIMIZE" ]; then \
    yes | unminimize; \
  fi

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

## Install Python related stuff
  ## Install JupyterLab
RUN pip install \
    jupyterlab==${JUPYTERLAB_VERSION} \
    jupyterlab-git \
    jupyterlab-lsp \
    notebook \
    nbconvert \
    python-lsp-server[all] \
  && if $(! echo ${BUILD_ON_IMAGE} | grep -q "python/base"); then \
    pip install \
      ipympl \
      ipywidgets \
      widgetsnbextension; \
      ## Install facets
      cd /tmp; \
      git clone https://github.com/PAIR-code/facets.git; \
      jupyter nbextension install facets/facets-dist/ --sys-prefix; \
  fi \
  ## Clean up
  && rm -rf /tmp/* \
    /root/.cache \
## Dev Container only
  ## Create folders in root directory
  && mkdir -p /root/.local/bin \
  && mkdir -p /root/projects \
  ## Create folders in skeleton directory
  && mkdir -p /etc/skel/.local/bin \
  && mkdir -p /etc/skel/projects \
  ## Create backup of root directory
  && cp -a /root /var/backups

## Devtools, Docker
FROM glcr.b-data.ch/nodejs/nsi${NV:+/}${NV:-:none}${NV:+/debian}${NV:+:bullseye} as nsi

FROM python

ARG DEBIAN_FRONTEND=noninteractive

ARG NV
ARG INSTALL_DOCKER_CLI

ENV NODE_VERSION=${NV}

  ## Install Node.js...
COPY --from=nsi /usr/local /usr/local

RUN if [ ! -z "$NODE_VERSION" ]; then \
    ## and other requirements
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bats \
      libsecret-1-dev \
      libx11-dev \
      libxkbfile-dev \
      libxt6 \
      quilt \
      rsync; \
    if [ ! -z "$PYTHON_VERSION" ]; then \
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
  && if [ ! -z "$INSTALL_DOCKER_CLI" ]; then \
    ## Install Docker CLI and plugins
    dpkgArch="$(dpkg --print-architecture)"; \
    . /etc/os-release; \
    mkdir -m 0755 -p /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/$ID/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    echo "deb [arch=$dpkgArch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null; \
    apt-get update; \
    apt-get -y install \
      docker-ce-cli \
      docker-buildx-plugin \
      docker-compose-plugin \
      $(test $dpkgArch = "amd64" && echo docker-scan-plugin); \
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
RUN if [ ! -z "$USE_ZSH_FOR_ROOT" ]; then \
    chsh -s /bin/zsh; \
  fi \
  ## Update timezone if needed
  && if [ "$TZ" != "Etc/UTC" ]; then \
    echo "Setting TZ to $TZ"; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
      && echo $TZ > /etc/timezone; \
  fi \
  ## Add/Update locale if needed
  && if [ "$LANG" != "en_US.UTF-8" ]; then \
    sed -i "s/# $LANG/$LANG/g" /etc/locale.gen; \
    locale-gen; \
    echo "Setting LANG to $LANG"; \
    update-locale --reset LANG=$LANG; \
  fi

## Pip: Install to the Python user install directory (1) or not (0)
ARG PIP_USER=1

ENV PIP_USER=${PIP_USER}

## Copy files as late as possible to avoid cache busting
COPY --from=files /files /

## Reset environment variable BUILD_DATE
ARG BUILD_START

ENV BUILD_DATE=${BUILD_START}
