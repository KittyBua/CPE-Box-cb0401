FROM ghcr.io/home-assistant/base:latest

# cpe-box is CGO-free (static), so the prebuilt binary runs on the Alpine base;
# it just needs an OpenSSH client + sshpass to reach the router, and bash/git/
# curl for the setup scripts. No Go, no build.
RUN apk add --no-cache bash git curl openssh-client sshpass openssl lsof

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
