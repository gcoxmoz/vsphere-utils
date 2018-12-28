# $Id$
%define debug_package %{nil}

%define app_dir /opt/vmware
%define perl_vendorlib /usr/lib64/perl5/vendor_perl

%global __requires_exclude_from ^%{_prefix}/share/man$

Summary:   A Perl SDK for interacting with VMware vSphere infrastructure
Name:      VMware-vSphere
Version:   6.7.0.8156551
Release:   1%{?dist}
License:   GPLv2+
Group:     Applications/System
# https://my.vmware.com/web/vmware/details?downloadGroup=VS-PERL-SDK65&productId=618
Source:    VMware-vSphere-Perl-SDK-6.7.0-8156551.x86_64.tar.gz
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
# Creating a list of requirements is not easy.  There are many conflicting
# sources.  If you enable autogen, you'll get a list of 'things' that include
# a mess of pragmas, core modules, perl package builtins, and the things you
# actually care about.  If you look at the code's Makefile.PL, you get one
# answer, the docs give a different answer,
# https://vdc-download.vmware.com/vmwb-repository/dcr-public/f280c443-0cda-4fed-8e15-7dc07e2b7037/66ce9472-ffd3-4e80-83b4-1bcfeec2099e/vsphere-perl-sdk-67-installation-guide.pdf
# and the contents of
# bin/vmware-uninstall-vSphere-CLI.pl give another.  And none of them are
# specific to what THIS package wants/needs.
#
# So this list is a manual curation.  It's not easy but here's the method:
# * Build the package once, just to get an installable RPM.
# * break the package open, and go through all the perl files and pipe
#   them through /usr/lib/rpm/find-requires
# * From that wad of data, cull out:
#   * the base pragmas
#         perl(bytes) perl(integer) perl(lib) perl(overload) perl(strict) perl(utf8) perl(warnings)
#   * the base modules in the perl package
#         perl(Config) perl(Fcntl) perl(File::Basename) perl(MIME::Base64)
#   * the core modules that are mandatory but packaged separate from perl
#         perl(Carp) perl(Encode) perl(Exporter) perl(File::Path) perl(Getopt::Long) perl(constant)
# "Why not just include all the things it wants?"
# I could.  but it's SO noisy and confusing for users.  And, they're built
# into the OS, there's not much I can do here if they're wrong.
#
# Then, require the perl that the modules want:
Requires:  perl >= 5.006001
# That leaves "the other modules"  And here the judgement calls begin.
# First, eliminate the things that are explicitly asked for by the SDK, but
# that are result of dependencies of libwww-perl:
#         perl(Date::Format) perl(HTML::Entities) perl(HTTP::Cookies) perl(HTTP::Headers) perl(HTTP::Request) perl(HTTP::Response) perl(URI) perl(URI::URL) perl(URI::Escape)
#
# Second: Archive::Zip is unneeded.  It's only in VIExt.pm, in unzip_file,
# which is a function that isn't used.  So skip it.
#         perl(Archive::Zip)
#
# Now, into the ones we care about.
#
# UUID is a garbage module that doesn't ship from an OS provider.
# You need to hand-package it.  THANKS VMware.
# cpan2rpm /tmp/UUID-0.27.tar.gz --version 0.27 --no-sign
# Make sure you have libuuid-devel installed; other uuid-named
# packages are red herrings on C7
#         perl(UUID)
Requires: perl(UUID) >= 0.27
#
# Data::Dumper, makefile says 2.102, docs and uninstall say 2.121
# OS is 2.145, so, sure!
#         perl(Data::Dumper)
Requires: perl(Data::Dumper) >= 2.121
#
# perl-libwww-perl - This could be 6.26, 5.8.05, 6.15 depending on if you believe
# vmware-uninstall-vSphere-CLI.pl, Makefile.PL, or docs.  CentOS7 ships 6.05
# So, we're not listing a version here.
#         perl(LWP::ConnCache) perl(LWP::UserAgent)
##Requires: perl(LWP) >= 6.26
Requires: perl(LWP)
#
# 6.7 instroduced the use of Text::Template as part of SSO, and it's needed.
# but the only place versioning is mentioned is vmware-uninstall-vSphere-CLI.pl.
# It wants 1.47 and the OS ships with 1.45.
#         perl(Text::Template)
##Requires: perl(Text::Template) >= 1.47
Requires: perl(Text::Template)
#
# perl-XML-LibXML -This is pretty clearly requesting 2.0129
# CentOS7 ships with 2.0018.  The changelog seems pretty minimal though.
#         perl(XML::LibXML)
##Requires: perl(XML::LibXML) >= 2.0129
Requires: perl(XML::LibXML)

BuildRequires: perl >= 5.008, perl(ExtUtils::MakeMaker), perl-generators
Prefix: %{perl_vendorlib}

%description Perl-SDK
The vSphere Perl SDK targets the development of Perl applications that access the vSphere platform. The SDK exposes the vSphere Perl APIs that are created as a Perl binding for the vSphere Web Services APIs.


%package CLI
Summary:   A CLI for interacting with VMware vSphere infrastructure
License:   GPLv2+
Group:     Applications/System
Autoreq:   0
# So this list is a manual curation.  It's not easy but here's the method:
# * Build the package once, just to get an installable RPM.
# * break the package open, and go through all the perl files and pipe
#   them through /usr/lib/rpm/find-requires
# * From that wad of data, cull out:
#   * the base pragmas
#         perl(bignum) perl(lib) perl(strict) perl(warnings)
#   * the base modules in the perl package
#         perl(File::Basename) perl(MIME::Base64)
#   * the core modules that are mandatory but packaged separate from perl
#         perl(Getopt::Long) perl(constant)
# Then, require the perl that the modules want:
Requires:  perl >= 5.006001
# 
# We also need our SDK to get SDK modules:
#         perl(VMware::VICommon) perl(VMware::VICredStore) perl(VMware::VIExt) perl(VMware::VILib) perl(VMware::VIM25Runtime) perl(VMware::VIRuntime)
Requires:  VMware-vSphere-Perl-SDK == %{version}
#
# That leaves "the other modules"  And here the judgement calls begin.
# First, eliminate the things that are explicitly asked for by the SDK, but
# that are result of dependencies of libwww-perl:
#         perl(HTTP::Date) perl(URI::URL)
#
# Data::Dumper, makefile says 2.102, docs and uninstall say 2.121
# OS is 2.145, so, sure!
#         perl(Data::Dumper)
Requires: perl(Data::Dumper) >= 2.121
#
# perl-libwww-perl - This could be 6.26, 5.8.05, 6.15 depending on if you believe
# vmware-uninstall-vSphere-CLI.pl, Makefile.PL, or docs.  CentOS7 ships 6.05
# So, we're not listing a version here.
#         perl(LWP::UserAgent)
##Requires: perl(LWP) >= 6.26
Requires: perl(LWP)
#
# perl-XML-LibXML -This is pretty clearly requesting 2.0129
# CentOS7 ships with 2.0018.  The changelog seems pretty minimal though.
#         perl(XML::LibXML)
##Requires: perl(XML::LibXML) >= 2.0129
Requires: perl(XML::LibXML)
# This is incomplete here.  I literally got tired of working on it and
# trying to figure out the complex mess that is this half of the module.
# The libraries and python components in a perl SDK, ugh.

BuildRequires: perl >= 5.008, perl-ExtUtils-MakeMaker, perl-generators

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
%{__cp} lib/lib32/lib*.1.0.2 $RPM_BUILD_ROOT%{_prefix}/lib/
%{__cp} lib/lib32/libv*.so $RPM_BUILD_ROOT%{_prefix}/lib/

# remove unecessary files
%{__rm} -f $RPM_BUILD_ROOT%{app_dir}/bin/vmware-uninstall-vSphere-CLI.pl
%{__rm} -f $RPM_BUILD_ROOT%{app_dir}/bin/*.pyc # For some reason .pyc file was in here?!
%{__rm} -f $RPM_BUILD_ROOT%{perl_vendorlib}/vmware-install.pl  # Don't install!  We're the installer.
%{__rm} -f $RPM_BUILD_ROOT%{perl_archlib}/perllocal.pod
%{__rm} -f $RPM_BUILD_ROOT%{app_dir}/bin/*.bat              # Not Windows
%{__rm} -rf $RPM_BUILD_ROOT/%{perl_vendorlib}/VMware/pyexe  # Not Windows
%{__rm} -rf $RPM_BUILD_ROOT/%{perl_vendorlib}/WSMan         # Not Windows
%{__rm} -rf $RPM_BUILD_ROOT/%{app_dir}/vcli/doc/samples     # Samples are not for production
%{__rm} -rf $RPM_BUILD_ROOT/%{app_dir}/vcli/bin/esxcli/lib64/python3.5 # We're not python.
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
%{_prefix}/lib/libcrypto.so.1.0.2
%{_prefix}/lib/libssl.so.1.0.2
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
* Fri Dec 28 2018 Greg Cox <gcox@mozilla.com> 6.7.0 8156551
- SDK 6.7.0 8156551

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

