FROM debian:bookworm

ARG FQDN

ENV fqdn=$FQDN
ENV basename='echo "${fqdn}" | rev | cut -d. -f -2 |rev'
ENV DEBIAN_FRONTEND noninteractive

RUN echo "postfix postfix/mailname string ${fqdn}" | debconf-set-selections
RUN echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
RUN apt update --allow-releaseinfo-change && apt upgrade -y && apt install -yqq --no-install-recommends postfix dovecot-core dovecot-imapd dovecot-lmtpd postfix-policyd-spf-python opendkim opendkim-tools opendmarc
RUN envsubst <"./conf/postfix/main.cf" >"/etc/postfix/main.cf"
RUN envsubst <"./conf/postfix/master.cf" >"/etc/postfix/master.cf"

EXPOSE 25
EXPOSE 143
EXPOSE 993
