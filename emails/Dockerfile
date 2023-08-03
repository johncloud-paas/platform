# docker build -t emails .
# docker run -e FQDN='app.johncloud.fr' -it emails bash
FROM debian:bookworm

ARG FQDN mail.poney.com
ENV FQDN $FQDN
ENV DEBIAN_FRONTEND noninteractive

WORKDIR /app
COPY . /app/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN echo "postfix postfix/mailname string $FQDN" | debconf-set-selections
RUN echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
RUN apt update --allow-releaseinfo-change && apt upgrade -y && apt install -yqq --no-install-recommends gettext-base tzdata postfix dovecot-core dovecot-imapd dovecot-lmtpd postfix-policyd-spf-python opendkim opendkim-tools opendmarc bash && echo "Europe/Paris" > /etc/timezone && dpkg-reconfigure -f noninteractive tzdata
RUN mkdir /etc/postfix -p && cp /app/conf/postfix/master.cf /etc/postfix/master.cf
# RUN source ~/.bashrc && export BASENAME=$(echo $FQDN | rev | cut -d. -f -2 | rev) && envsubst < "/app/conf/postfix/main.cf" > "/etc/postfix/main.cf"

EXPOSE 25
EXPOSE 143
EXPOSE 993

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD []
