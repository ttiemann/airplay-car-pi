ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends iproute2 systemd \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY install.sh /app/install.sh
COPY diagnose.sh /app/diagnose.sh
RUN chmod +x /app/install.sh /app/diagnose.sh

CMD ["/app/install.sh"]
