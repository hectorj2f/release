#!/usr/bin/env bash


mkdir -p konvoy-k8s-repo-1.0

wget -O konvoy-k8s-repo-1.0/RPM-GPG-konvoy-k8s-repo https://packages.d2iq.com/konvoy/rpm-gpg-pub-key

cat << EOF > konvoy-k8s-repo-1.0/konvoy-k8s.repo
[kubernetes]
name=Konvoy Kubernetes package repository
baseurl=https://packages.d2iq.com/konvoy/rpm/stable/centos/7/x86_64
#gpgkey=https://packages.d2iq.com/konvoy/rpm-gpg-pub-key
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-konvoy-k8s-repo
gpgcheck=1
enabled=1
EOF

tar --xz -cvf konvoy-k8s-repo-1.0.tar.xz konvoy-k8s-repo-1.0

# Let's build the rpm repository installer

rpmbuild -ba ../SPECS/konvoy-k8s-repo.spec

rpmlint -i ../SPECS/konvoy-k8s-repo.spec
