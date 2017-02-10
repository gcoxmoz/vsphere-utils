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
# http://kb.vmware.com/kb/2037005
# Got templates that need reregistering in 5.x?
# This does the dirty work with fewer clicks.
#

my %opts = (
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my @vms = get_all_templates();
fix_templates(@vms) if (@vms);
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub get_all_templates {
    my @vms = ();
    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'parent', 'config.template', 'config.files.vmPathName', 'runtime.host', ], );
    if (!$vms) { print "Search for VMs failed.\n"; return (); }
    if (!(scalar @{$vms})) { print "Found no VMs.\n"; return (); }
    foreach my $vm (@{$vms}) {
      next unless ($vm->get_property('config.template') eq 'true');
      push @vms, $vm;
    }
    return @vms;
}


sub fix_templates {
  my @vms = @_;
  foreach my $vm (sort { $a->name cmp $b->name } @vms) {
    my $vm_name = $vm->name;

    my $path        = $vm->get_property('config.files.vmPathName');
    my $parent_view = Vim::get_view(mo_ref => $vm->parent, properties => ['name', ], );
    my $host_view   = Vim::get_view(mo_ref => $vm->{'runtime.host'}, properties => ['name', ], );

    print "$vm_name\n";
    print "  Path:   ".$path."\n";
    print "  Folder: ".$parent_view->name . "\n";

    my $ret1 = $vm->UnregisterVM();
    my $ret2 = $parent_view->RegisterVM(path => $path, name => $vm_name, asTemplate => 1, host => $host_view, );
  }
}
