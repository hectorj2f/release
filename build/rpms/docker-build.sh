#!/usr/bin/env bash
set -e

docker build -t kubelet-rpm-builder .
echo "Cleaning output directory..."
sudo rm -rf output/*
mkdir -p output
if [ -z "$GPG_KEY_FILE" ]; then
    echo "gpg key 'GPG_KEY_FILE' env var is required to sign the rpm packages and repo metadata"
    exit 1
fi
docker run -ti --rm -v $GPG_KEY_FILE:/tmp/gpg-key/rpm-gpg-key.asc -v $PWD/output/:/root/rpmbuild/RPMS/ kubelet-rpm-builder $1
sudo chown -R $USER $PWD/output

echo
echo "----------------------------------------"
echo
echo "RPMs written to: "
ls $PWD/output/*/
echo
echo "Yum repodata written to: "
ls $PWD/output/*/repodata/
