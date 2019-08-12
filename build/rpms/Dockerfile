FROM fedora:24

RUN dnf install -y \
      rpm-build \
      rpmdevtools \
      createrepo \
      perl-Digest-SHA \
      gpg \
      rpm-sign \
      wget \
    && dnf clean all

RUN rpmdev-setuptree

USER root

ADD build.sh /root/
COPY . /root/rpmbuild/SPECS

ENTRYPOINT ["/root/build.sh"]
