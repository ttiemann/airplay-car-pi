FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

COPY install.sh /app/install.sh
RUN chmod +x /app/install.sh

CMD ["/app/install.sh"]
