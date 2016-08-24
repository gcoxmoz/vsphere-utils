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
# We name each VM (that isn't a template) as the FQDN of the VM.  This usually work well.
# This script lints for cases where there's a problem.  The aim is mostly:
# "does 'the name vCenter knows' match DNS match 'what VMware Tools says you are'?"
#
# It's prone to false nagatives / overreporting.  Problem spots:
# * Template without an FQDN
# * A decom'ed box that has been pulled from DNS
# * Template that's booted and thus has an unexpected name
# * HA pair'ed boxes that know their name as the floating-IP's name
# * VMware tools has crashed
#

my %opts = (
  'clusterName' => { type => '=s', help => 'Cluster name', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my @vms = get_all_vms();
analyze_vms(@vms) if (@vms);
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub get_all_vms {
    my @vms = ();
    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'config.template', 'runtime.powerState', 'layoutEx.file', 'guest', 'snapshot', ], );
    if (!$vms) { print "Search for VMs failed.\n"; return (); }
    if (!(scalar @{$vms})) { print "Found no VMs.\n"; return (); }
    foreach my $vm (@{$vms}) {
      next if ($vm->get_property('config.template') eq 'true');   # templates don't participate in name matches
      push @vms, $vm;
    }
    return @vms;
}

sub analyze_vms {
  my @vms = @_;
  foreach my $vm (sort { $a->name cmp $b->name } @vms) {
    my $vm_name = $vm->name;
    my $vm_is_on = ($vm->get_property('runtime.powerState')->val =~ m#poweredOn# ? 1 : 0);
    if ($vm_name !~ m#(?:net|org|com)$#) {
      print "### VM $vm_name is not an FQDN.\n";
    } else {
      my @addresses = gethostbyname($vm_name);
      if (!@addresses) {
        print "### VM $vm_name does not resolve in DNS.\n";
      }
    }

    my @files = @{$vm->get_property('layoutEx.file')};
    my @vmx = ();
    foreach my $file (@files) {
      my $file_name = $file->name;
      # Looking through all the files in the folder is tiresome.
      # If we're on multiple datastores, we'll be found out immediately in the vm-drs-separation script.
      # If we're on multiple directories on one datastore, we'll be found out eventually with an SVMO.
      # So let's assume the VMX file is all that matters; 99.9% of the time this is true.
      push(@vmx, $file_name) if ($file_name =~ m#\.vmx$#i);
    }
    if (scalar(@vmx) < 1) {
      print "### VM $vm_name doesn't seem to have a VMX file.\n";
    } elsif (scalar(@vmx) > 1) {
      print "### VM $vm_name has multiple VMX files.\n";
    } else {
      my $file_name = $vmx[0];
      if ($file_name !~ m#^(\[[^\]]+\]) ([^/]+)/#) {
        print "### VM $vm_name has a VMX that couldn't be pattern-matched.  Script error?\n";
      } else {
        my ($ds, $dir) = ($1, $2, );
        if ($dir ne $vm_name) {
          print "### VM $vm_name is known as '$dir' on disk on $ds.\n";
        }
      }
    }

    my $guest_fam = $vm->get_property('guest.guestFamily') || '';
    if (($guest_fam !~ m#windows#i) && $vm_is_on) {
      # Windows hostnames suck.  Don't even play this game.
      my $tools_version = $vm->get_property('guest.toolsVersionStatus2') || '';
      if ($tools_version eq 'guestToolsNotInstalled') {
#        print "### VM $vm_name does not have tools installed.\n";
      } else {
        my $tools_name = $vm->get_property('guest.hostName');
        if (!$tools_name) {
          print "### VM $vm_name does not know its name from the tools.\n";
        #} elsif ($vm_name ne $tools_name) {
        } elsif ($vm_name !~ m#^$tools_name#) {
          # A corner case slips through:
          # name foo1.m.c and DNS foor1.bar.scl3.m.c don't trip here.
          print "### VM $vm_name reports its name as '$tools_name' in the tools.\n";
        }
      }
    }

  }

}
