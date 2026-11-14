# MapServer (WMS/WFS) with the demo map baked in, so the container needs
# no volumes and no database credentials.
FROM camptocamp/mapserver:8.6-gdal3.13

COPY asterra.map /etc/mapserver/asterra.map
COPY data/ /etc/mapserver/data/

ARG SERVICE_VERSION=dev
LABEL org.opencontainers.image.version=${SERVICE_VERSION}

# Serve this map by default, without a map= parameter in the URL.
ENV MS_MAPFILE=/etc/mapserver/asterra.map

# Run unprivileged. The base image then listens on 8080 (as root it switches to 80).
USER www-data

EXPOSE 8080
