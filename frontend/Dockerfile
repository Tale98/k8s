FROM nginx:alpine

RUN apk add --no-cache keepalived

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
