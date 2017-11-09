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
# Get a list, or set the values, of the VMotion encryption settings.
# Since this is enforced at the VM level, this script is so we can get to 'required' easily without manually touching each VM.
#

my %opts = (
    'set' => { type => '=s',   help => 'Set the encryption value', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my $servicecontent = Vim::get_service_content();
if ($servicecontent->about->apiVersion < 6.5) {
    die "vMotion Encryption wasn't introduced until 6.5.\n";
}
iterate_over_VMs();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub iterate_over_VMs {
    my $set    = Opts::get_option('set');
    if (defined $set) {
        if ($set !~ m{^(?:disabled|opportunistic|required)$}) {
            die "--set must be one of disabled, opportunistic, or required";
        }
    } else {
        $set = '';
    }

    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'config', ], );
    if (!$vms) { Util::trace(0, "No vms found '\n"); return; }

    foreach my $vm (sort { $a->name cmp $b->name } @$vms) {
        my $vm_name = $vm->name;

        my $vmo_string = $vm->get_property('config.migrateEncryption');
        if (! $vmo_string) {
            print "### VM '$vm_name' doesn't have config.migrateEncryption set(?)\n";
            next;
        }
        if ($set) {
            if ($set eq $vmo_string) {
                print "$vm_name is already set to $vmo_string.\n";
            } elsif ($vm->get_property('config.template') eq 'true') {
                print "Won't convert $vm_name, since it's a template.\n";
            } else {
                print "Converting $vm_name from $vmo_string to $set.\n";
                my $config = VirtualMachineConfigSpec->new( 'migrateEncryption' => $set, );
                $vm->ReconfigVM( spec => $config, );
            }
        } else {
            printf "%-50s %s\n", $vm_name, $vmo_string;
        }
    }

}
