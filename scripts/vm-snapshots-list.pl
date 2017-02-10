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
# Main thing:
# Running with snapshots can kill your performance.  Finding your snapshots isn't hard, but it's tedious
# across a whole environment.  This shows you who has VM snaps, and when/why they exist, so you can
# quickly decide if you care.
#
# Secondary thing:
# NetApp's Virtual Storage Console can sometimes blow up and leave behind snapshots, smvi_something, EVERYWHERE
# With a --cleanup, we can quickly clear out these orphan snapshots once you see them.
#

my %opts = (
  'cleanup-smvi' => { type => "",   help => 'Run an actual cleanup', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $do_cleanup_flag = Opts::get_option('cleanup-smvi') && 1;

# connect to the server
Util::connect(); #print "Server Connected\n";
my @vms = get_all_vms();
searchSnapshots(@vms) if (@vms);
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub get_all_vms {
    my @vms = ();
    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'config.template', 'guest', 'snapshot', ], );
    if (!$vms) { print "Search for VMs failed.\n"; return (); }
    if (!(scalar @{$vms})) { print "Found no VMs.\n"; return (); }
    foreach my $vm (@{$vms}) {
      next if ($vm->get_property('config.template') eq 'true');   # templates don't participate in name matches
      push @vms, $vm;
    }
    return @vms;
}

sub searchSnapshots {
  my @vms = @_;
  print "# Use --cleanup-smvi to clean up any smvi snapshots\n" if (!$do_cleanup_flag);
  foreach my $vm (sort { $a->name cmp $b->name } @vms) {
    my $vm_name = $vm->name;
    if ($vm->snapshot) {
      print "### $vm_name has snapshots.\n";

      foreach (@{$vm->snapshot->rootSnapshotList}) {
        printSnaps($_, 2);
      }
    }
  }
}

sub printSnaps {
    my ($snapshotTree, $indent) = @_;
    $indent = 2 if ($indent < 2);
    print '### ' . ' ' x $indent . '|- Name:     ' . $snapshotTree->name . "\n";
    print '### ' . ' ' x $indent . '   Created:  ' . $snapshotTree->createTime . "\n";

    # recurse through the tree of snaps
    if ($snapshotTree->childSnapshotList) {
    # loop through any children that may exist
      foreach (@{$snapshotTree->childSnapshotList}) {
        printSnaps($_, $indent + 2);
      }
    }

    if ($do_cleanup_flag) {
      if ($snapshotTree->name !~ m#^smvi#) {
        print 'Not offering the deletion of snapshot "'.$snapshotTree->name."\".\n";
      } else {
        print 'Delete snapshot "'.$snapshotTree->name.'" ? [y/N] ';
        my $input = <STDIN>;
        chomp $input;
        if ($input =~ m/^[Y]$/i){ #match Y or y
          my $snapshot = Vim::get_view(mo_ref => $snapshotTree->snapshot);
          $snapshot->RemoveSnapshot_Task(removeChildren => 'false');
        } else {
          print 'Skipping "'.$snapshotTree->name."\"\n";
        }
      }
    }
}
