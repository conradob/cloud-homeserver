FROM alpine

WORKDIR /dynamic

ADD entrypoint.sh /bin/entrypoint.sh

RUN chmod +x /bin/entrypoint.sh

ENTRYPOINT /bin/entrypoint.sh
