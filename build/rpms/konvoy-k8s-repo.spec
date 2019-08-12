# How to make this archive:
# 0. Create source dir: mkdir konvoy-k8s-repo-1.0
# 1. Download GPG public key and save it as RPM-GPG-konvoy-k8s-repo (or
#    whatever appropriate name such like other ones in /etc/pki/rpm-gpg/)
#    and put it into the source dir.
#
#    - GPG public key: https://konvoy-kubelet-nokmem.s3.amazonaws.com/rpm-signed/rpm-gpg-pub-key
#
# 2. Create the yum .repo file:
#
# cat << EOF > konvoy-k8s-repo-1.0/konvoy-k8s.repo
# [kubernetes]
# name=Konvoy Kubernetes package repository
# baseurl=https://konvoy-kubelet-nokmem.s3.amazonaws.com/rpm-signed/x86_64/
# #gpgkey=https://konvoy-kubelet-nokmem.s3.amazonaws.com/rpm-signed/rpm-gpg-pub-key
# gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-konvoy-k8s-repo
# gpgcheck=1
# enabled=1
# EOF
#
# 3. Create the archive: tar --xz -cvf konvoy-k8s-repo-1.0.tar.xz konvoy-k8s-repo-1.0
#

Summary:        Konvoy Kubernetes package repository
Name:           konvoy-k8s-repo
Version:        1.0
Release:        1%{?dist}
License:        MIT
Group:          System Environment/Base
URL:            https://github.com/mesosphere/konvoy/

Source:         %{name}-%{version}.tar.xz
Provides:       konvoy-k8s-repo
BuildArch:      noarch

%description
Konvoy Kubernetes package repository file for yum and dnf along with gpg public key

%prep
%autosetup

%build

%install
install -d -m 755 %{buildroot}/etc/pki/rpm-gpg
install -m 644 RPM-GPG-* %{buildroot}/etc/pki/rpm-gpg

install -d -m 755 %{buildroot}/etc/yum.repos.d
install -m 644 konvoy-k8s.repo %{buildroot}/etc/yum.repos.d

%files
%defattr(-,root,root,-)
%config(noreplace) /etc/yum.repos.d/*.repo
/etc/pki/rpm-gpg/*

%changelog
* Mon Aug 12 2019 Hector Fernandez <hfernandez@d2iq.com> - 1-0.0
- Initial prototype packaging
