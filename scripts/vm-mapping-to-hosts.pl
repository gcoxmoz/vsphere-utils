#!/usr/bin/perl -w
#
# gcox@mozilla
#
use strict;
use warnings;
use VMware::VIRuntime;
$SIG{__DIE__} = sub{Util::disconnect()};
$Util::script_version = '1.0';

#
# While we make a DRS rule to try to keep our vCenter on a particular host, we run this
# cron script about every 10 minutes, to dump a file to an NFS volume, as an 'in case
# of emergency' item to help us locate our VMs in case of a severe vCenter issue.
#
# You'll probably want a config file 
# VI_SERVER=vcenter1.wherever
# VI_USERNAME=ro_user@mysite.com
# VI_PASSWORD=12345-the-same-combination-as-my-luggage
#

my %opts = (
  'makefile' => { type => "=s",   help => 'Create a backup file', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $makefile = Opts::get_option('makefile') || '';

if ($makefile) {
  die "File, if specified, must be pathed from /.\n" if ($makefile !~ m#^/#);
  die "File, if specified, must not be a directory.\n" if ($makefile =~ m#/$#);
 (my $dir = $makefile) =~ s#/[^/]+$##;
  die "No such directory $dir\n" if (! -d $dir);
  if (-e $makefile) {
    die "File $makefile exists but isn't a writable file.\n" if (!(-w $makefile && -f $makefile));
  }
}

# connect from the server
Util::connect(); #print "Server Connected\n";
my %vms = get_all_vms_by_host();
if (%vms) {
  printfile(%vms);
} else {
  print "No VMs found.\n";
}
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub get_all_vms_by_host {
    my %vms = ();
    my $hosts = Vim::find_entity_views(view_type => 'HostSystem', properties => ['name', 'vm' ], );
    if (!$hosts) { print "Search for hosts failed.\n"; return (); }
    if (!(scalar @{$hosts})) { print "Found no hosts.\n"; return (); }
    foreach my $host (@{$hosts}) {
      my $hostname = $host->name;
      if ($host->get_property('vm')) {
        foreach my $vm (@{$host->get_property('vm')}) {
          my $vm_view = Vim::get_view(mo_ref => $vm, properties => ['name', ], );
          my $vmname = $vm_view->name;
          push(@{$vms{$hostname}}, $vmname);
        }
      }
    }
    return %vms;
}

sub printfile {
  my (%vms, ) = @_;
  my @outlines = ();
  foreach my $host (sort { $a cmp $b } keys %vms) {
    foreach my $vm (sort { $a cmp $b } @{$vms{$host}}) {
      push @outlines, "$host $vm\n";
    }
  }
  if ($makefile) {
    open( DUMP, '>'.$makefile);
    print DUMP @outlines;
    close(DUMP);
  } else {
    print STDOUT @outlines;
  }
}
