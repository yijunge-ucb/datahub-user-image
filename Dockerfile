FROM buildpack-deps:jammy-scm as base

# Set up common env variables
ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV NB_USER=jovyan
ENV NB_UID=1000

# These are used by the python, R, and final stages
ENV CONDA_DIR=/srv/conda
ENV R_LIBS_USER=/srv/r

# capture default path so we can set the path succinctly later
ENV DEFAULT_PATH=${PATH}

# needed for webpdf notebook exports in the jovyan's environment
ENV PLAYWRIGHT_BROWSERS_PATH=${CONDA_DIR}

RUN apt-get -qq update --yes && \
    apt-get -qq install --yes locales && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

RUN adduser --disabled-password --gecos "Default Jupyter user" ${NB_USER}

# Do not exclude manpages from being installed.
RUN sed -i '/usr.share.man/s/^/#/' /etc/dpkg/dpkg.cfg.d/excludes

# Reinstall coreutils so that basic man pages are installed. Due to dpkg's
# exclusion, they were not originally installed.
RUN apt --reinstall install coreutils

# Install all apt packages
COPY apt.txt /tmp/apt.txt
RUN apt-get -qq update --yes && \
    apt-get -qq install --yes --no-install-recommends \
        $(grep -v ^# /tmp/apt.txt) && \
    apt-get -qq purge && \
    apt-get -qq clean && \
    rm -rf /var/lib/apt/lists/*

# From docker-ce-packaging
# Remove diverted man binary to prevent man-pages being replaced with "minimized" message. See docker/for-linux#639
RUN if  [ "$(dpkg-divert --truename /usr/bin/man)" = "/usr/bin/man.REAL" ]; then \
        rm -f /usr/bin/man; \
        dpkg-divert --quiet --remove --rename /usr/bin/man; \
    fi

RUN mandb -c

# Install R.

# These apt packages must be installed into the base stage since they are in
# system paths rather than /srv.
#
# Pre-built R packages from Posit Package Manager are built against system libs
# in jammy.
#
# After updating R_VERSION and rstudio-server, update Rprofile.site too.
ENV R_VERSION=4.4.2-1.2204.0
ENV LITTLER_VERSION=0.3.20-2.2204.0
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E298A3A825C0D65DFD57CBB651716619E084DAB9
RUN echo "deb https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/" > /etc/apt/sources.list.d/cran.list
RUN curl --silent --location --fail https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc > /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc
RUN apt-get update --yes > /dev/null && \
    apt-get install --yes -qq r-base-core=${R_VERSION} r-base-dev=${R_VERSION} littler=${LITTLER_VERSION} r-cran-littler=${LITTLER_VERSION} > /dev/null

# RStudio Server and Quarto
ENV RSTUDIO_URL=https://download2.rstudio.org/server/jammy/amd64/rstudio-server-2024.12.0-467-amd64.deb
RUN curl --silent --location --fail ${RSTUDIO_URL} > /tmp/rstudio.deb && \
    apt install --no-install-recommends --yes /tmp/rstudio.deb && \
    rm /tmp/rstudio.deb

# For command-line access to quarto, which is installed by rstudio.
RUN ln -s /usr/lib/rstudio-server/bin/quarto/bin/quarto /usr/local/bin/quarto

# Shiny Server
ENV SHINY_SERVER_URL https://download3.rstudio.org/ubuntu-18.04/x86_64/shiny-server-1.5.22.1017-amd64.deb
RUN curl --silent --location --fail ${SHINY_SERVER_URL} > /tmp/shiny-server.deb && \
    apt install --no-install-recommends --yes /tmp/shiny-server.deb && \
    rm /tmp/shiny-server.deb

# Install our custom Rprofile.site file
COPY Rprofile.site /usr/lib/R/etc/Rprofile.site
# Create directory for additional R/RStudio setup code
RUN mkdir /etc/R/Rprofile.site.d
# RStudio needs its own config
COPY rsession.conf /etc/rstudio/rsession.conf

# R_LIBS_USER is set by default in /etc/R/Renviron, which RStudio loads.
# We uncomment the default, and set what we wanna - so it picks up
# the packages we install. Without this, RStudio doesn't see the packages
# that R does.
# Stolen from https://github.com/jupyterhub/repo2docker/blob/6a07a48b2df48168685bb0f993d2a12bd86e23bf/repo2docker/buildpacks/r.py
# To try fight https://community.rstudio.com/t/timedatectl-had-status-1/72060,
# which shows up sometimes when trying to install packages that want the TZ
# timedatectl expects systemd running, which isn't true in our containers
RUN sed -i -e '/^R_LIBS_USER=/s/^/#/' /etc/R/Renviron && \
    echo "R_LIBS_USER=${R_LIBS_USER}" >> /etc/R/Renviron && \
    echo "TZ=${TZ}" >> /etc/R/Renviron

# =============================================================================
# This stage exists to build /srv/r.
FROM base as srv-r

USER root
# Create user owned R libs dir
# This lets users temporarily install packages
RUN install -d -o ${NB_USER} -g ${NB_USER} ${R_LIBS_USER}

# Install R libraries as our user
USER ${NB_USER}

# Install R packages
COPY install-r-packages.r /tmp/
RUN /usr/bin/Rscript /tmp/install-r-packages.r

# =============================================================================
# This stage exists to build /srv/conda.
FROM base as srv-conda

USER root
# Create user owned conda dir
# This lets users temporarily install packages
RUN install -d -o ${NB_USER} -g ${NB_USER} ${CONDA_DIR}

# Install conda environment as our user
USER ${NB_USER}

# Install conda 
COPY --chown=${NB_USER}:${NB_USER} install-miniforge.bash /tmp/install-miniforge.bash
RUN /tmp/install-miniforge.bash

# Install Conda packages
ENV PATH=${CONDA_DIR}/bin:$PATH
COPY environment.yml /tmp/environment.yml
RUN mamba env update -q -p ${CONDA_DIR} -f /tmp/environment.yml
RUN mamba clean -afy

#ESPM, FA 24
# https://github.com/berkeley-dsep-infra/datahub/issues/5827
ENV VSCODE_EXTENSIONS=${CONDA_DIR}/share/code-server/extensions
RUN mkdir -p ${VSCODE_EXTENSIONS}

# Install Code Server Jupyter extension
RUN /srv/conda/bin/code-server --extensions-dir ${VSCODE_EXTENSIONS} --install-extension ms-toolsai.jupyter
# Install Code Server Python extension
RUN /srv/conda/bin/code-server --extensions-dir ${VSCODE_EXTENSIONS} --install-extension ms-python.python

# TODO:  there's a good chance we may not need this, jon f 2025-01-24
ENV NLTK_DATA=${CONDA_DIR}/nltk_data
COPY connectors/text.bash /tmp/connector-text.bash
RUN /tmp/connector-text.bash

# install chromium browser for playwright
# https://github.com/berkeley-dsep-infra/datahub/issues/5062
# playwright is only availalbe in nbconvert[webpdf], via pip/pypi.
# see also environment.yaml
# DH-164
RUN playwright install chromium

RUN mamba list
# =============================================================================
# This stage consumes base and import /srv/r and /srv/conda.
FROM base as final

USER root
COPY --from=srv-r /srv/r /srv/r
COPY --from=srv-conda /srv/conda /srv/conda
ENV REPO_DIR=/srv/repo
COPY --chown=${NB_USER}:${NB_USER} image-tests ${REPO_DIR}/image-tests

RUN chown ${NB_USER}:${NB_USER} /srv/r /srv/conda 

USER ${NB_USER}
ENV PATH=${CONDA_DIR}/bin:${R_LIBS_USER}/bin:${DEFAULT_PATH}:/usr/lib/rstudio-server/bin

# Install IR kernelspec. Requires python and R.
RUN R -e "IRkernel::installspec(user = FALSE, prefix='${CONDA_DIR}')"

# clear out /tmp
USER root
RUN rm -rf /tmp/*


USER ${NB_USER}
WORKDIR /home/${NB_USER}


EXPOSE 8888

ENTRYPOINT ["tini", "--"]
