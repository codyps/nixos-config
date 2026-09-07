FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40
RUN apk add --no-cache nix openssh-server openssh-keygen procps ca-certificates \
    && mkdir -p /run/sshd /etc/nix /builder-keys \
    && passwd -d root
COPY nix.conf /etc/nix/nix.conf
COPY sshd_config /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
