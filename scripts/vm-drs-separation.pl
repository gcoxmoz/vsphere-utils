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
# This is both a powerful / useful script, and some nasty spaghetti.  Sorry.
# It started out with a simple purpose: make sure that where we have clusters
# (foo1, foo2, foo3), that we have a DRS rule to keep them separated.
# It grew a bit: once you HAVE a DRS rule, make sure your VMs are spread out
# on the shared storage such that if we lose an aggr, we'll only lose one Nth
# of the hosts in that DRS rule.
#
# There's some Mozilla-specific use here, you can copy it or not.
# * All our separation rules are called, literally, "$blahblah separation"
#   The script will gripe if you are off that convention.  You can comment that.
# * We have rules for elasticsearch and rabbitMQ boxes, so that, besides DRS
#   separation, they stick to 'even numbered' or 'odd numbered' hosts.  This
#   is for UCS niceties and split-brain avoidance.  You probably won't care.
#   If you do, happy to talk about it.
# * We flag a particular host as the 'home port' for vCenter, so that in a
#   disaster situation, we can take an educated guess where the VCSA will be.
#
# Otherwise, we're mostly using simple separations.
#

my %opts = (
    'clusterName' => { type => '=s', help => 'Cluster name', required => 0},
    'listrules'   => { type => ':s', help => 'List rules',   default => undef, required => 0},
    'listsingles' => { type => ':s', help => 'List VMs without any rules', default => undef, required => 0},
    );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
searchRules();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub searchRules {
    # Find the Cluster
    my $clusterName = Opts::get_option('clusterName');
    my $clusters_ref = Vim::find_entity_views(view_type => 'ClusterComputeResource', properties => ['name', 'configurationEx'], filter => $clusterName ? { name => $clusterName } : {} );
    if (!@{$clusters_ref}) { Util::trace(0, "ComputeResource '" . $clusterName . "' not found\n"); return; }


    my %ds_to_cluster = ();
    my %cluster_to_ds = ();
    my $pod_view = Vim::find_entity_views(view_type => 'StoragePod' );
    if (!$pod_view) { Util::trace(0, "Datastore Clusters not found\n"); next; }
    foreach my $dsc_obj (@$pod_view) {
        my $clus_name = $dsc_obj->name;
        next unless ($dsc_obj->childEntity);
        my $ds_obj = Vim::get_views(view_type => 'Datastore', mo_ref_array => $dsc_obj->childEntity);
        foreach my $ds (@{$ds_obj}) {
            $ds_to_cluster{$ds->name} = $clus_name;
            push(@{$cluster_to_ds{$clus_name}}, $ds->name);
        }
    }


    my %strip_to_vm_map = ();
    foreach my $cluster_ref (sort { $a->name cmp $b->name } @{$clusters_ref}) {
      print '# Cluster '.  $cluster_ref->name . "\n";
      # Get the rules
      my $rules = $cluster_ref->configurationEx->rule;
      if (!$rules) { Util::trace(0, "Warning: No rules found for ComputeResource '" . $cluster_ref->name . "'\n"); }

      my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', begin_entity => $cluster_ref, properties => ['name', 'config.template', 'config.name', 'config.datastoreUrl', 'runtime.powerState', ], );
      if (!$vms) { Util::trace(0, "No vms found for ComputeResource '" . $clusterName . "'\n"); next; }
      my %vm_strips = ();
      my %vm_datastores = ();
      my %vm_uniqueness = ();
      my %vm_powered = ();
      foreach my $vm (@$vms) {
          next if ($vm->get_property('config.template') eq 'true');   # templates don't participate in DRS
          my $vm_name = $vm->name;
          (my $strip = $vm_name) =~ s#[0-9]+[ab]?\.##g;
          push(@{$strip_to_vm_map{$strip}}, $vm_name);
          $vm_strips{$vm_name} = $strip;
          $vm_uniqueness{$vm_name} = 1;
          my $dslist_ref = $vm->get_property('config.datastoreUrl');
          if (scalar(@{$dslist_ref}) < 1) {
              print "### VM '$vm_name' doesn't use datastores(!?)\n";
              $dslist_ref = '';
          } elsif (scalar(@{$dslist_ref}) > 1) {
              print "### VM '$vm_name' uses multiple datastores: ".join(' and ', sort map { $_->name } @{$dslist_ref}).".\n";
              my @array = grep { $_->name !~ m#installmedia#i } @{$dslist_ref};
              $dslist_ref = '';   # FIXME someday? we're using multiple DS's, one's not an ISO, and nobody's fixed the VM config.
              $dslist_ref = $array[0]->name if (scalar @array == 1);
          } else {
              $dslist_ref = @{$dslist_ref}[0]->name;
          }
          $vm_datastores{$vm_name} = $dslist_ref;
          if ($vm->get_property('runtime.powerState')->val =~ m#poweredOn#) {  # ignore powered-off (pseudotemplates)
              $vm_powered{$vm_name} = 1;
          }
      }

      my %separation_rule_to_vm_map = ();    # 1:N map rules to the VMs they contain, for listing at the the end
      my %rule_to_group_map = ();            # 1:1 map rules to the VM Group it contains, for matching up later
      my %strip_to_rule_map = (); # map strips to their rules, for finding single VMs that missed going into existing rules
      if ($rules) {
          foreach my $rule (sort { $a->name cmp $b->name } @{$rules}) {
              my $rule_name = $rule->name;
              if ($rule->isa('ClusterAntiAffinityRuleSpec')) {
                  print "### Rule '$rule_name' is not enabled.\n" unless ($rule->enabled);
                  print "### Separation '$rule_name' doesn't end in 'separation'.\n" unless ($rule_name =~ m#[Ss]eparation(?: [-0-9]+)?$#);

                  my @vms = ();
                  my %internal_overload_counter = (); # Strips this rule contains; ideally 1
                  if (scalar @{$rule->vm} == 0){
                      print "### Rule '$rule_name' has no VMs associated with it.\n";
                      next;
                  } elsif (scalar @{$rule->vm} == 1){
                      print "### Rule '$rule_name' has only 1 VM in it.\n";
                      next;
                  } else {
                      foreach my $vm_obj (@{$rule->vm}) {
                          my $vm = Vim::get_view(mo_ref => $vm_obj, properties => ['config.name'], );
                          my $vm_name = $vm->get_property('config.name');
                          push @vms, $vm_name;
                          my $stripname = $vm_strips{$vm_name};
                          $internal_overload_counter{$stripname} = 1;
                          $strip_to_rule_map{$stripname}{$rule_name} = 1;
                          if ($vm_uniqueness{$vm_name}) {
                            delete $vm_powered{$vm_name};
                            delete $vm_uniqueness{$vm_name};
                          } else {
                            # got here because some rule deleted the VM in an earlier loop.
                            print "### VM '$vm_name' seems to appear in multiple antiaffinity rules.\n";
                          }
                      }
                  }
                  print "### Rule '$rule_name' has a lot of members.\n" if (scalar(@vms) > 6);
                  print "### Rule '$rule_name' has inconsistently named VMs within it.\n" if (scalar(keys %internal_overload_counter) > 1);
                  my @sorted_vms = sort @vms;
                  $separation_rule_to_vm_map{$rule_name} = \@sorted_vms;
              } elsif ($rule->isa('ClusterVmHostRuleInfo')) {
                  $rule_to_group_map{$rule_name} = 1;
                  next if ($rule_name =~ m#^VC on last Host#i);
                  # Past here should be even-odds and fallthroughs
                  next if ($rule_name =~ m#elasticsearch$#i);
                  next if ($rule_name =~ m#rabbits?$#i);
                  print "### Found a pin-guest-to-host rule: '$rule_name'.\n";
              } else {
                  print "### Rule '$rule_name' isn't an Anti-Affinity or pin-guest-to-Host rule.\n";
              }
          }
      }

      # Fallen through the rules.  Here, anyone in %vm_uniqueness wasn't tagged by a rule,
      # and anyone in %vm_powered is here and powered
      # First, go looking for a VM that belongs to a rule already in existence.
      foreach my $vm_name (sort keys %vm_uniqueness) {
          my $stripname = $vm_strips{$vm_name};
          next unless ($strip_to_rule_map{$stripname});
          print "### VM '$vm_name' might fit in rule ".join(' or ', sort keys %{$strip_to_rule_map{$stripname}})."\n";
      }

      # Second, go looking for a VM that might pair up with someone else who doesn't have a rule.
      my %strip_to_leftovers_map = ();
      #foreach my $vm_name (keys %vm_uniqueness) {
      foreach my $vm_name (keys %vm_powered) {
          my $stripname = $vm_strips{$vm_name};
          push @{$strip_to_leftovers_map{$stripname}}, $vm_name;
      }
      foreach my $stripname (sort keys %strip_to_leftovers_map) {
          my @vms = sort @{$strip_to_leftovers_map{$stripname}};
          if (scalar(@vms) == 1) {
              # didn't find a buddy.
              next;
          } elsif (scalar(@vms) == 2) {
              # blah32 and blah64 aren't buddies
              (my $sa = $vms[0]) =~ s#(32|64)\.##;
              (my $sb = $vms[1]) =~ s#(32|64)\.##;
              next if ($sa eq $sb);
          }
          # Might need more rules here in the future.
          print "### VMs ".join(' and ', @vms)." might need a rule.\n";
      }

      # Let's look for storage rule violations
      foreach my $stripname (sort keys %strip_to_vm_map) {
          # We're only going to look at VMs that have DRS separation, since otherwise
          # this just gets silly: why would you worry about storage sep if you're not
          # worrying about host sep?
          next unless ($strip_to_rule_map{$stripname});
          my @vms = @{$strip_to_vm_map{$stripname}};
          # If there's not 2 VMs, there's no storage spread. Duh.
          next if (scalar(@vms) < 2);
          my %ds_map_for_this_strip = map { $_ => $vm_datastores{$_} } @vms;

          # Now, go through the VMs in this strip, and make sure they're all in datastores
          # belonging to one cluster.  If not, gripe and bail out.
          my %unique_cluster_finder = ();
          foreach my $vm (sort keys %ds_map_for_this_strip) {
              my $ds  = $ds_map_for_this_strip{$vm};
              my $dsc = $ds_to_cluster{$ds};
              if (!$dsc) {
                  print "### VM '$vm' belongs to non-clustered datastore '$ds'.\n";
                  next;
              }
              $unique_cluster_finder{$dsc} = 1;
          }
          if (scalar(keys %unique_cluster_finder) > 1) {
              print "### VMs ".join(" and ", sort @vms)." are spread across multiple datastore clusters.\n";
              # Get out of here, as any math we try to do is going to be suspect.
              next;
          } elsif (scalar(keys %unique_cluster_finder) < 1) {
              # We are here because all the VMs in this strip were eliminated for being non-clustered datastores
              print "### All the above VMs were in non-clustered datastores.  Can't suggest a balance plan.\n";
              next;
          }

          # Now, you have VMs all belonging to one datastorecluster.
          my $which_cluster = (keys %unique_cluster_finder)[0];
          # Go through the datastores in that cluster, make a zero count for each datastore,
          # then count up each time each datastore is used.
          my %ds_count = ();
          foreach my $ds (@{$cluster_to_ds{$which_cluster}}) {
              # This forces a zero count into the array, to catch misbalances of the 2-1-1-0 type
              $ds_count{$ds} = 0;
          }
          foreach my $ds (values %ds_map_for_this_strip) {
              $ds_count{$ds}++;
          }

          # Sort the datastore count by use, low to high
          my @sorted_ds = sort { $ds_count{$a} <=> $ds_count{$b} } keys %ds_count;
          # If only one DS is used, that's a problem (we have multple VMs, guaranteed above)
          # If the spread from most-used to least-used is more than 1, that's like 1-3-3 when it should be 2-2-3
          if ((scalar(@sorted_ds) < 2) || (($ds_count{$sorted_ds[$#sorted_ds]} - $ds_count{$sorted_ds[0]}) > 1)) {
              print "### Storage balance problem:\n";
              foreach my $vm (sort @vms) {
                  print "###  $vm : $ds_map_for_this_strip{$vm}\n";
              }
          }
      }


      if (%separation_rule_to_vm_map) {
          foreach my $separation_rule (sort keys %separation_rule_to_vm_map) {
              (my $rule = $separation_rule) =~ s# separation$##;
              next if ($rule_to_group_map{$rule});
              if ( ($rule =~ m#elasticsearch#i) ||
                   ($rule =~ m#rabbit#i) ) {
                  print "### Separation rule '$separation_rule' does not appear to have an even-odd segmentation rule.\n";
              }
          }
      }


      #if verbose, print all rules and their member VMs...
      if (defined Opts::get_option('listrules')) {
          if (%separation_rule_to_vm_map) {
              print "## Existing AntiAffinity rules:\n";
              foreach my $rule_name (sort keys %separation_rule_to_vm_map) {
                  print "$rule_name\n";
                  print join("\n", map {"  $_" } sort @{$separation_rule_to_vm_map{$rule_name}})."\n";
              }
          }
          if (%rule_to_group_map) {
              print "## Existing ClusterVmHost rules:\n";
              foreach my $rule_name (sort keys %rule_to_group_map) {
                  print "$rule_name\n";
              }
          }
      }
      # ...and then print all VMs that have no rule.
      if (defined Opts::get_option('listsingles')) {
          print "## VMs that are not part of any rules:\n";
          print join("\n", sort keys %vm_uniqueness)."\n";
      }
    }

}
