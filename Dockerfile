FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

COPY install.sh /app/install.sh
COPY diagnose.sh /app/diagnose.sh
RUN chmod +x /app/install.sh /app/diagnose.sh

CMD ["/app/install.sh"]
