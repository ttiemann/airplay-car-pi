# Container image for running the Raspberry Pi AirPlay installer.

# Select the base operating system.
ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

# Disable interactive package prompts.
ENV DEBIAN_FRONTEND=noninteractive

# Install tools required by the installer.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends iproute2 systemd \
	&& rm -rf /var/lib/apt/lists/*

# Set the application directory.
WORKDIR /app

# Add the installation and diagnostic scripts.
COPY install.sh /app/install.sh
COPY diagnose.sh /app/diagnose.sh
RUN chmod +x /app/install.sh /app/diagnose.sh

# Run the installer when the container starts.
CMD ["/app/install.sh"]
