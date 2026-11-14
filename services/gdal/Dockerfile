# Official GDAL image, extended with GeoPandas (assignment III.D.1).
FROM ghcr.io/osgeo/gdal:ubuntu-small-3.13.3

# The base image ships Python and the GDAL bindings but no pip.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /srv/requirements.txt
# --break-system-packages: this container has exactly one Python application,
# so a virtual environment would only hide the system GDAL bindings.
RUN pip install --no-cache-dir --break-system-packages -r /srv/requirements.txt

COPY app.py /srv/app.py

ARG SERVICE_VERSION=dev
ENV SERVICE_VERSION=${SERVICE_VERSION} PORT=8080 PYTHONUNBUFFERED=1

# Run as an unprivileged user.
RUN useradd --system --no-create-home geo
USER geo

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python3 -c "import urllib.request,os; urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ['PORT'], timeout=3)"

CMD ["python3", "/srv/app.py"]
