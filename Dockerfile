FROM alpine:3.20

RUN apk add --no-cache bash curl iputils util-linux

COPY watchdog.sh /watchdog.sh
RUN chmod +x /watchdog.sh

ENTRYPOINT ["/watchdog.sh"]