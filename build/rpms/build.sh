#!/usr/bin/env bash

# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

# TODO: Allow running this script locally. Right now, this can only be used as a docker entrypoint.

declare -a ARCHS

if [ $# -gt 0 ]; then
  IFS=','; ARCHS=($1); unset IFS;
else
  #GOARCH/RPMARCH
  ARCHS=(
    amd64/x86_64
  )
fi

gpg --import /tmp/gpg-key/rpm-gpg-key.asc

gpg --export -a 'Kubernetes Konvoy nokmem' > /tmp/rpm-gpg-pub-key

for ARCH in "${ARCHS[@]}"; do
  IFS=/ read -r GOARCH RPMARCH<<< "${ARCH}"; unset IFS;
  SRC_PATH="/root/rpmbuild/SOURCES/${RPMARCH}"
  mkdir -p "${SRC_PATH}"
  cp -r /root/rpmbuild/SPECS/* "${SRC_PATH}"
  echo "Building RPM's for ${GOARCH}....."
  sed -i "s/\%global ARCH.*/\%global ARCH ${GOARCH}/" "${SRC_PATH}/kubelet.spec"
  # Download sources if not already available
  cd "${SRC_PATH}" && spectool -gf kubelet.spec
  echo ${SRC_PATH}
  /usr/bin/rpmbuild --target "${RPMARCH}" --define "_sourcedir ${SRC_PATH}" -bb "${SRC_PATH}/kubelet.spec"
  mkdir -p "/root/rpmbuild/RPMS/${RPMARCH}"

  rpm --import /tmp/rpm-gpg-pub-key

  rpm -q gpg-pubkey --qf '%{name}-%{version}-%{release} --> %{summary}\n'


cat <<EOF >>/root/.rpmmacros
%_topdir %(echo $HOME)/rpmbuild

%_signature gpg
%_gpg_path /root/.gnupg
%_gpg_name Kubernetes Konvoy nokmem
%_gpgbin /usr/bin/gpg
%__gpg_sign_cmd %{__gpg} gpg --force-v3-sigs --batch --verbose --no-armor --passphrase-fd 3 --no-secmem-warning -u "%{_gpg_name}" -sbo %{__signature_filename} --digest-algo sha256 %{__plaintext_filename}'

%__arch_install_post \
    [ "%{buildarch}" = "noarch" ] || QA_CHECK_RPATHS=1 ; \
    case "${QA_CHECK_RPATHS:-}" in [1yY]*) /usr/lib/rpm/check-rpaths ;; esac \
    /usr/lib/rpm/check-buildroot
EOF

  rpm --addsign /root/rpmbuild/RPMS/${RPMARCH}/*.rpm

  createrepo -o "/root/rpmbuild/RPMS/${RPMARCH}/" "/root/rpmbuild/RPMS/${RPMARCH}"

  gpg --detach-sign --armor /root/rpmbuild/RPMS/${RPMARCH}/repodata/repomd.xml

done


echo "Copying public key to output"
cp /tmp/rpm-gpg-pub-key /root/rpmbuild/RPMS/${RPMARCH}/rpm-gpg-pub-key
