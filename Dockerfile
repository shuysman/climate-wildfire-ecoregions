FROM docker.io/rocker/r-ver:4.5.1

# Install System Dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    cargo \
    cdo \
    cmake \
    gdal-bin \
    imagemagick \
    nco \
    netcdf-bin \
    yq \
    libcurl4-openssl-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libfribidi-dev \
    libgdal-dev \
    libharfbuzz-dev \
    libicu-dev \
    libnetcdf-dev \
    libpng-dev \
    libssl-dev \
    libudunits2-dev \
    libx11-dev \
    libxml2-dev \
    pandoc \
    rustc \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN wget "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -O "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws/

# Set timezone for pipeline scripts, else timezone is GMT
# and dates don't work. Going to use mountain time to coincide with gridMET
ENV TZ=America/Denver
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Suppress renv startup messages (kept as fallback, though .Rprofile is deleted after restore)
# May want to remove these after chattiness bug (renv issue 2211) is fixed
ENV RENV_CONFIG_STARTUP_QUIET=TRUE
ENV RENV_CONFIG_SYNCHRONIZED_CHECK=FALSE


# Set up Working Directory
WORKDIR /app

# Restore R Environment with renv
# Remote renv after setup to prevent pollution from renv version mismatch bug.
# https://github.com/rstudio/renv/issues/2211
# Can remove rm .Rprofile line once bug is fixed
COPY renv.lock .Rprofile .
COPY renv/activate.R renv/activate.R
RUN R -e "install.packages('renv')" && \
    R -e "renv::restore()" && \
    rm .Rprofile

# Point R to the renv library (renv no longer activates since .Rprofile is gone)
# May want to remove these after chattiness bug (renv issue 2211) is fixed
ENV R_LIBS=/app/renv/library/linux-ubuntu-noble/R-4.5/x86_64-pc-linux-gnu

# Copy Project Files
COPY ./src /app/src
COPY ./config /app/config


# Make Scripts Executable
RUN find /app/src -name "*.sh" -type f -exec chmod +x {} \;

# Set Default Command
# You can override this at runtime if you want to run a different script.
CMD ["/app/src/operational/pipeline/daily_forecast.sh"]
