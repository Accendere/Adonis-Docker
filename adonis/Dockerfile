# Use Debian-based Home Assistant base image
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:trixie
FROM ${BUILD_FROM}

# Supervisor already passes this at build time (see its `docker buildx
# build --build-arg BUILD_VERSION=...` invocation in the Supervisor log) -
# just carry it through to a runtime ENV so bootstrap.sh can print it in its
# startup banner without a third place to keep in sync.
ARG BUILD_VERSION=unknown
ENV BUILD_VERSION=${BUILD_VERSION}

#### ********************************************** ####
#### REMEMBER to bump versions also in config.yaml! ####
#### ********************************************** ####
LABEL io.hass.version="5.0.1" \
      io.hass.type="addon" \
      io.hass.arch="aarch64|amd64"

# This image only carries packages and a small bootstrap. All boot logic,
# access policy and service config come from the app repo's addon/ directory
# at the configured tag (see files/bootstrap.sh), so changing them never
# needs an image rebuild.

# Install required base packages
RUN apt-get update && apt-get install -y \
    ca-certificates curl lsb-release apt-transport-https gnupg2 && \
    rm -rf /var/lib/apt/lists/*

# Install Sury keyring (this automatically installs the correct source.list entry)
RUN curl -sSLo /tmp/debsuryorg-archive-keyring.deb \
      https://packages.sury.org/debsuryorg-archive-keyring.deb && \
    dpkg -i /tmp/debsuryorg-archive-keyring.deb && \
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list && \
    rm /tmp/debsuryorg-archive-keyring.deb


# Install Apache + PHP 8.4 with modules + Utilities
#
# apache2's postinst drops the stock "Apache2 Debian Default Page" at
# /var/www/html/index.html (Debian bug #821313); remove it so it doesn't sit
# as an untracked file in the app's git working tree once it's checked out.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        openssh-server apache2 apache2-utils libapache2-mod-php8.4 \
        php8.4 php8.4-cli php8.4-dev php8.4-fpm php8.4-xdebug php8.4-curl php8.4-xml\
        php8.4-sqlite3 php8.4-pdo sqlite3 supervisor \
        unzip git curl wget nano nodejs composer bash-completion mc \
        nmap acl wireguard-tools iproute2 ncdu tmux && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /var/www/html/index.html

# Configure PHP Timezone
RUN find /etc/php/8.4/ -name "php.ini" -exec sed -i 's/;date.timezone =/date.timezone = "Europe\/Lisbon"/g' {} \;

# Install Zabbix Agent 2 and Zabbix Sender
RUN wget https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb && \
    dpkg -i zabbix-release_latest_7.4+debian12_all.deb && \
    apt-get update && \
    apt-get install -y zabbix-agent2 zabbix-agent2-plugin-* zabbix-sender && \
    rm -rf /var/lib/apt/lists/* zabbix-release_latest_7.4+debian12_all.deb && \
    ln -s /usr/bin/zabbix_sender /etc/zabbix/zabbix_sender

# Install GitHub CLI
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

RUN a2dismod php8.4 mpm_prefork && a2enmod mpm_event proxy_fcgi setenvif rewrite ssl headers proxy proxy_http

# SSH: no keys, no password, no policy here. The host key is generated and
# persisted per host at boot, and sshd's whole policy (who may log in, how)
# is a drop-in written by the app repo's addon/ scripts. Until that runs,
# Debian's defaults apply and root has no password.
RUN mkdir -p /run/sshd && rm -f /etc/ssh/ssh_host_*

# Configure Apache logging to stdout/stderr
RUN sed -i -r 's@ErrorLog .*@ErrorLog /dev/stderr@i' /etc/apache2/apache2.conf && \
    echo "CustomLog /dev/stdout combined" >> /etc/apache2/apache2.conf

# Copy files into container (remember that .dockerignore file affects this):
# bootstrap.sh plus /root/.ssh/{config,known_hosts}, which the bootstrap
# needs to reach GitHub before anything from the app repo exists. Both are
# public: GitHub's published host keys and its SSH-over-443 redirect.
COPY files/ /

RUN chmod 700 /root/.ssh && \
    chmod 644 /root/.ssh/known_hosts && \
    chmod 600 /root/.ssh/config && \
    chmod +x /bootstrap.sh

CMD ["/bootstrap.sh"]
