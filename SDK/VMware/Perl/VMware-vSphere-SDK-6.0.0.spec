# $Id$
%define debug_package %{nil}

%define app_dir /opt/vmware
%define perl_vendorlib /usr/lib64/perl5/vendor_perl

Summary:   A Perl SDK for interacting with VMware vSphere infrastructure
Name:      VMware-vSphere
Version:   6.0.0.3561779
Release:   3%{?dist}
License:   GPLv2+
Group:     Applications/System
Source:    VMware-vSphere-Perl-SDK-6.0.0-3561779.x86_64.tar.gz
Patch0:    VMware-vSphere-Perl-SDK-%{version}-makefile.patch
URL:       http://www.vmware.com
BuildRoot: %(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)
Vendor:    Mozilla IT

%description
Placeholder for the not-build %{name} package

%package Perl-SDK
Summary:   A Perl SDK for interacting with VMware vSphere infrastructure
Group:     Development/Libraries
License:   GPLv2+
Autoreq:   0
Requires:  perl >= 5.008, perl-URI, perl-Crypt-SSLeay >= 0.51, perl-libwww-perl >= 5.8.05, perl-SOAP-Lite >= 0.67, perl-XML-LibXML >= 1.58
BuildRequires: perl >= 5.008, perl-ExtUtils-MakeMaker
Prefix: %{perl_vendorlib}

%description Perl-SDK
The vSphere SDK for Perl is a client-side Perl framework that provides an easy-to-use scripting interface to the vSphere API. Administrators and developers who are familiar with Perl can use the vSphere SDK for Perl to automate a wide variety of administrative, provisioning, and monitoring tasks in the vSphere environment. The vSphere SDK for Perl includes ready-to-use utility applications, which you can immediately put to use in your virtual datacenter.

The vSphere SDK for Perl installation includes the WS-Management Perl Library, which allows you to write scripts that retrieve CIM data from the ESX host using CIMOM, a service that provides standard CIM management functions over a WBEM (Web-Based Enterprise Management).

You can use the SDK to manage ESX 3.0.x, ESX/ESXi 3.5 through 4.1, ESXi 5.0 and up, vCenter Server 2.5 and up


%package CLI
Summary:   A CLI for interacting with VMware vSphere infrastructure
License:   GPLv2+
Group:     Applications/System
Autoreq:   0
Requires:  VMware-vSphere-Perl-SDK
Requires:  perl-Archive-Zip
Requires:  perl-UUID >= 0.03, perl-Class-MethodMaker >= 2.08

%description CLI
The vSphere Command-Line Interface (vSphere CLI) command set allows you to run common system administration commands against ESX/ESXi systems from any machine with network access to those systems. You can also run most vSphere CLI commands against a vCenter Server system and target any ESX/ESXi system that vCenter Server system manages. vSphere CLI includes the ESXCLI command set, vicfg- commands, and some other commands.


%prep
%setup -q -n vmware-vsphere-cli-distrib
%patch0 -p0


%build
%{__perl} Makefile.PL INSTALLDIRS=vendor \
                      INSTALLVENDORSCRIPT=%{app_dir}/vcli \
                      INSTALLVENDORLIB=%{perl_vendorlib} \
                      #INSTALL_BASE=%{_prefix} \
                      #INSTALLSITELIB=%{perl_vendorlib} \
                      #INSTALLSITEARCH=%{perl_vendorarch} \
                      #INSTALLSITEMAN3DIR=%{_prefix}/share/man/man3
%{__make}


%install
%{__rm} -rf $RPM_BUILD_ROOT
%{__make} DESTDIR=$RPM_BUILD_ROOT/ install

%{__install} -d -m 0755 $RPM_BUILD_ROOT%{app_dir}/vcli
%{__cp} -r lib/bin $RPM_BUILD_ROOT%{app_dir}/vcli

%{__cp} -r lib/lib64/ $RPM_BUILD_ROOT%{app_dir}/vcli/lib

%{__install} -d -m 0755 $RPM_BUILD_ROOT%{app_dir}/vcli/share/man/man1
%{__cp} man/*.1 $RPM_BUILD_ROOT%{app_dir}/vcli/share/man/man1/

# Install esxcfg/vicfg scripts
%{__install} -d -m 0755 $RPM_BUILD_ROOT%{app_dir}/bin
%{__cp} bin/* $RPM_BUILD_ROOT%{app_dir}/bin
%{__install} -d -m 0755 $RPM_BUILD_ROOT%{_prefix}/lib
%{__cp} lib/lib32/lib*.1.0.1 $RPM_BUILD_ROOT%{_prefix}/lib/
%{__cp} lib/lib32/libv*.so $RPM_BUILD_ROOT%{_prefix}/lib/

# remove unecessary files
%{__rm} -f $RPM_BUILD_ROOT%{app_dir}/bin/vmware-uninstall-vSphere-CLI.pl
%{__rm} -f $RPM_BUILD_ROOT%{perl_vendorlib}/vmware-install.pl  # Don't install!  We're the installer.
%{__rm} -f $RPM_BUILD_ROOT%{perl_archlib}/perllocal.pod
%{__rm} -rf $RPM_BUILD_ROOT/%{perl_vendorlib}/VMware/pyexe  # Not Windows
%{__rm} -rf $RPM_BUILD_ROOT/%{perl_vendorlib}/WSMan         # Not Windows
find $RPM_BUILD_ROOT -type f -name .packlist -exec rm -f {} \;

# vcli config file
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/vmware-vcli
cat <<EOD > $RPM_BUILD_ROOT%{_sysconfdir}/vmware-vcli/locations
answer BINDIR %{app_dir}/bin
answer LIBDIR %{app_dir}/vcli
answer INITDIR %{_sysconfdir}%{app_dir}
answer INITSCRIPTSDIR %{_initrddir}
EOD



%clean
%{__rm} -rf $RPM_BUILD_ROOT


%files Perl-SDK
%defattr(-,root,root,-)
#%{perl_vendorarch}/auto/VIPerlToolkit  # Empty, why bother?
%{perl_vendorlib}/VMware
#%{perl_vendorlib}/WSMan  # Not Windows
%doc %{_prefix}/share/man/man3/VMware*

%files CLI
%defattr(-,root,root,-)
%doc %{app_dir}/vcli/doc
%dir %{_sysconfdir}/vmware-vcli
%config(noreplace) %{_sysconfdir}/vmware-vcli/locations
%dir %{app_dir}/vcli
%{app_dir}/vcli/apps
%{app_dir}/vcli/bin
%{app_dir}/vcli/lib
%{app_dir}/vcli/share
%{_prefix}/lib/libcrypto.so.1.0.1
%{_prefix}/lib/libssl.so.1.0.1
%{_prefix}/lib/libvim-types.so
%{_prefix}/lib/libvmacore.so
%{_prefix}/lib/libvmomi.so
%dir %{app_dir}/bin
%{app_dir}/bin/esxcfg-advcfg
%{app_dir}/bin/esxcfg-authconfig
%{app_dir}/bin/esxcfg-cfgbackup
%{app_dir}/bin/esxcfg-dns
%{app_dir}/bin/esxcfg-dumppart
%{app_dir}/bin/esxcfg-hostops
%{app_dir}/bin/esxcfg-ipsec
%{app_dir}/bin/esxcfg-iscsi
%{app_dir}/bin/esxcfg-module
%{app_dir}/bin/esxcfg-mpath
%{app_dir}/bin/esxcfg-mpath35
%{app_dir}/bin/esxcfg-nas
%{app_dir}/bin/esxcfg-nics
%{app_dir}/bin/esxcfg-ntp
%{app_dir}/bin/esxcfg-rescan
%{app_dir}/bin/esxcfg-route
%{app_dir}/bin/esxcfg-scsidevs
%{app_dir}/bin/esxcfg-snmp
%{app_dir}/bin/esxcfg-syslog
%{app_dir}/bin/esxcfg-user
%{app_dir}/bin/esxcfg-vmknic
%{app_dir}/bin/esxcfg-volume
%{app_dir}/bin/esxcfg-vswitch
%{app_dir}/bin/resxtop
%{app_dir}/bin/svmotion
%{app_dir}/bin/vicfg-advcfg
%{app_dir}/bin/vicfg-authconfig
%{app_dir}/bin/vicfg-cfgbackup
%{app_dir}/bin/vicfg-dns
%{app_dir}/bin/vicfg-dumppart
%{app_dir}/bin/vicfg-hostops
%{app_dir}/bin/vicfg-ipsec
%{app_dir}/bin/vicfg-iscsi
%{app_dir}/bin/vicfg-module
%{app_dir}/bin/vicfg-mpath
%{app_dir}/bin/vicfg-mpath35
%{app_dir}/bin/vicfg-nas
%{app_dir}/bin/vicfg-nics
%{app_dir}/bin/vicfg-ntp
%{app_dir}/bin/vicfg-rescan
%{app_dir}/bin/vicfg-route
%{app_dir}/bin/vicfg-scsidevs
%{app_dir}/bin/vicfg-snmp
%{app_dir}/bin/vicfg-syslog
%{app_dir}/bin/vicfg-user
%{app_dir}/bin/vicfg-vmknic
%{app_dir}/bin/vicfg-volume
%{app_dir}/bin/vicfg-vswitch
%{app_dir}/bin/vifs
%{app_dir}/bin/vihostupdate
%{app_dir}/bin/vihostupdate35
%{app_dir}/bin/viperl-support
%{app_dir}/bin/vmkfstools
%{app_dir}/bin/vmware-cmd


%changelog
* Wed Mar 23 2016 Greg Cox <gcox@mozilla.com> 6.0.0 3561779
- SDK 6.0.0 3561779

* Thu Mar 27 2014 Marco Tizzoni <marco.tizzoni@gmail.com> 5.5.0 1384587
- SDK 5.5.0 1384587

* Fri Feb 22 2013 Schlomo Schapiro <schlomo.schapiro@immobilienscout24.de> 5.1.0 780721
- SDK 5.1.0 780721

* Sun Oct 23 2011 Vaughan Whitteron <rpmbuild@firetooth.net> 5.0.0 522456.1
- Split package into Perl SDK and CLI packages
- Include RCLI scripts in the CLI package

* Mon Aug 29 2011 Vaughan Whitteron <rpmbuild@firetooth.net> 5.0.0 522456
- SDK 5.0.0 522456

