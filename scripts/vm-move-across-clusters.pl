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
# This script came about from moving VMs across 2 large clusters, and getting tired of trying to manage
# resource pool permissions, DRS rules, group creations.
#
# Unfortunately, it's not a common operation, so my testing is NOT complete.
# And I lost my main testbed due to some unrelated moves.
#
# I'm publishing because it's been working in "good enough" mode.  I know it's not quite, though.  Sorry.
#

my %opts = (
  'newcluster' => { type => "=s", help => 'New cluster to move into', required => 1},
  'newpool'    => { type => "=s", help => 'New pool to move into.  / delimit if it\'s a nested pool',    required => 1},
  'vms'        => { type => "=s", help => 'VMs to move',              required => 1},
  'noop'       => { type => '!', help => 'Don\'t actually do anything', default => undef, required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $noop = Opts::get_option('noop');

# connect to the server
Util::connect(); #print "Server Connected\n";
my %layout = verify_inputs();
do_actions(0, \%layout);
if (!defined($noop) || !$noop) {
    my @chars = ("A".."Z", "a".."z");
    my $randstring;
    $randstring .= $chars[rand @chars] for 1..12;
    print "\nYou haven't typed --noop.  Please confirm you want to do these steps by typing '$randstring' now.  ";
    my $text = <STDIN>; chomp $text;
    if ($text =~ m#^$randstring$#) {
        do_actions(1, \%layout);
    } else {
        print "Text did not perfectly match.  Aborting.\n";
    }
}
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

# FIXME 2 assumption in here somewhere that we don't have to do anything with the network or storage because cross-cluster consistency.  We should probably verify that.
sub verify_inputs {
    my %movement_info = ();
    print STDOUT "### Preflight Check ###\n";
    
    # Cluster
    printf STDOUT '%-30s', "Cluster check: ";
    my $newcluster = Opts::get_option('newcluster');
    my $cluster_ref = Vim::find_entity_view(view_type => 'ClusterComputeResource', properties => ['name', 'configurationEx', 'resourcePool'], filter => { name => qr#^$newcluster$# } );
    if (!$cluster_ref) { Util::trace(0, "ClusterComputeResource '" . $newcluster . "' not found\n"); exit; }
    print STDOUT "found destination cluster '".$cluster_ref->name."'\n";
    $movement_info{'newcluster'} = $cluster_ref;

    # VMs
    printf STDOUT '%-30s', "VM existence check: ";
    my $vm_string  = Opts::get_option('vms');
    my @vms = ();
    my $oldpool;
    my $oldpoolref;
    my @vms_names = split m#\s+#, $vm_string;
    my %temp_vms_hash = ();
    
    foreach my $vm (@vms_names) {
        my $vm_ref = Vim::find_entity_view(view_type => 'VirtualMachine', properties => ['name', 'resourcePool',], filter => { name => qr#^$vm$# } );
        if (!$vm_ref) { Util::trace(0, "VirtualMachine '" . $vm . "' not found\n"); exit; }
        
        my $respool = Vim::get_view(view_type => 'ResourcePool', mo_ref => $vm_ref->resourcePool, properties => ['name', 'parent', 'owner', 'vm', 'config', 'permission', ] );
        $oldpoolref = $vm_ref->resourcePool;
        $oldpool = $respool;
        # ^ This is cheating a bit.  The last VM's pool will be labeled the 'old pool'.
        # However, since we fail later if they're not all in the same pool, this is good enough.
        my @pathing = ();
        while ($respool->name !~ m#^Resources$#) {
            unshift @pathing, $respool;
            $respool = Vim::get_view(view_type => 'ResourcePool', mo_ref => $respool->parent, properties => ['name', 'parent', 'owner', ] );
        }
        my $owner = Vim::get_view(view_type => 'ClusterComputeResource', mo_ref => $respool->owner, properties => ['name', 'configurationEx', ] );
        $movement_info{'oldcluster'} = $owner;
        #print "$vm: [".$owner->name.'] '.join(' ', map { $_->name } @pathing)."\n";
        push @vms, $vm_ref;
        $temp_vms_hash{$owner->name}{$vm} = join('/', map { $_->name } @pathing);
    }
    print STDOUT "found all VMs\n";
    #
    # Let's quick-analyze the VMs
    #
    printf STDOUT '%-30s', "VM location check: ";
    if (scalar(keys(%temp_vms_hash)) > 1) {
        print "You have listed VMs from more than one cluster.\n";
        foreach my $cluster (sort keys %temp_vms_hash) {
            print "$cluster:\n";
            print "  ".join(' ', sort keys %{$temp_vms_hash{$cluster}}). "\n";
        }
        print "Start over with a subset of these VMs.\n";
        exit;
    } else {
        #
        # My use case is to pick-and-plop like-VMs from one pool to a similar one.
        # So I'm going to complain if they're disparate.
        # If you have a slicker way, I'm all ears, but otherwise, this is a safety check.
        #
        my $cluster = (keys(%temp_vms_hash))[0];
        if ($cluster eq $newcluster) {
            print "Your VMs are already in cluster $cluster.  You don't need me.\n";
            exit;
        }
        my %pathings = reverse %{$temp_vms_hash{$cluster}};
        if (scalar(keys(%pathings)) > 1) {
            print "You have listed VMs from more than one pool path in $cluster.\n";
            foreach my $path (keys %pathings) {
                print(($path ? $path : '/')."\n");
                foreach my $vm (sort keys %{$temp_vms_hash{$cluster}}) { print "  $vm\n" if ($temp_vms_hash{$cluster}{$vm} eq $path); }
            }
            print "Start over with a subset of these VMs.\n";
            exit;
        }
        print STDOUT "found all VMs in one source pool\n";
        my $vms_ref = Vim::get_views(view_type => 'VirtualMachine', mo_ref_array => $oldpool->vm, properties => ['name', ], );
        my %actual_sub_vms = map { $_->name => 1 } @$vms_ref;
        my %listed_sub_vms = map { $_->name => 1 } @vms;
        foreach my $i (keys %listed_sub_vms) { delete $actual_sub_vms{$i}; }
        if (scalar keys %actual_sub_vms <= 0) {
            # All the VMs we want to move are the last remnants of oldpool.
            # remove it on the way out.
            $movement_info{'deletepool'} = {'oldpoolref' => $oldpoolref, };
        }
        $movement_info{'movevms'} = {'vms' => \@vms};
    }

    printf STDOUT '%-30s', "Destination pool check: ";
    my $newpool_str    = Opts::get_option('newpool');
    my @new_pools_paths = split m#/#, $newpool_str;

    my $poolpointer = Vim::get_view(view_type => 'ResourcePool', mo_ref => $cluster_ref->resourcePool , properties => ['name', 'resourcePool', 'config', 'permission', ] );
    my @new_pools_refs  = ($poolpointer, );
    LEVEL: foreach my $level (@new_pools_paths) {
        my $pools_ref = Vim::get_views(view_type => 'ResourcePool', mo_ref_array => $poolpointer->resourcePool, properties => ['name', 'resourcePool', 'config', 'permission', ], );
        foreach my $pool (@$pools_ref) {
            next unless ($pool->name eq $level);
            push @new_pools_refs, $pool;
            $poolpointer = $pool;
            next LEVEL;
        }
        # If we got here, no pool was found, time to give up.
        last LEVEL;
    }

    #print join(' ', @new_pools_paths)."\n";
    #print join(' ', map { $_->name} @new_pools_refs)."\n";
    if (scalar(@new_pools_refs) == scalar(@new_pools_paths) + 1) {
        # The refs point to the ROOT pool, so it will have 1 more if the desired full path exists.
        # So we have a preexisting destination pool.  Cool.
        #
        # Bomb out if this doesn't look like a PERFECT match, because with it being a merge-in
        # to an existing pool, we don't want data loss or change or overwrites from the old pool.
        # Force the user to do it the hard way.
        #
        # If you don't like it, move it to a new pool to get it across the cluster divide and
        # reconcile the differences later.
        #
        my $newpool = $new_pools_refs[$#new_pools_refs];
        if ($oldpool->name ne $newpool->name) {
            print "VMs are in '".$oldpool->name."' but you want to move them to '".$newpool->name."'\n";
            # This isn't a stopper but is unusual.  Call it out.
        } else {
            print "found matching pool names in both clusters\n";
        }
        printf STDOUT '%-30s', "Pool resource check: ";
        foreach my $resource ('cpu', 'memory',) {
            my $oldi = $oldpool->config->{$resource.'Allocation'}->shares->shares;
            my $newi = $newpool->config->{$resource.'Allocation'}->shares->shares;
            my $oldl = $oldpool->config->{$resource.'Allocation'}->shares->level->val;
            my $newl = $newpool->config->{$resource.'Allocation'}->shares->level->val;
            if ($oldi != $newi) {
                print "Mismatch in Resource Pool $resource shares: old=$oldi / new=$newi\n";
            } elsif ($oldl ne $newl) {
                print "Mismatch in Resource Pool $resource levels old=$oldi / new=$newi\n";
            } else {
                next;
            }
            exit;
        }
        print "Resource levels match between ".$oldpool->name." and ".$newpool->name."\n";

        printf STDOUT '%-30s', "Pool permissions check: ";
        my $oldp = $oldpool->permission || [];
        my $newp = $newpool->permission || [];
        if (!scalar @{$oldp} && !scalar @{$newp}) {
            print "No special permissions on ".$oldpool->name." or ".$newpool->name."\n";
        } else {
            my %old = map { $_->principal => $_ } @$oldp;
            my %new = map { $_->principal => $_ } @$newp;
            foreach my $principal (keys %old) {
                my $oldcomp = $old{$principal};
                my $newcomp = $new{$principal};
                if (! $newcomp) {
                    print $newpool->name." is missing permissions for $principal.\n";
                    exit;
                } else {
                    foreach my $piece ('group', 'propagate', 'roleId',) {
                        if ($oldcomp->{$piece} ne $newcomp->{$piece}) {
                            print $newpool->name."'s permissions for $principal disagree with ".$oldpool->name."'s $piece value\n";
                            exit;
                        }
                    }
                }
                delete $old{$principal};
                delete $new{$principal};
            } 
            foreach my $principal (%new) {
                # If we're here, we have a problem by default.
                print $oldpool->name." is missing permissions for $principal.\n";
                exit;
            }
            print "Permissions match between ".$oldpool->name." and ".$newpool->name."\n";
        }
        $movement_info{'movevms'}->{'newpool'} = $newpool;

    } elsif (scalar(@new_pools_refs) == scalar(@new_pools_paths)) {
        # We DON'T have a preexisting destination pool, but there's a 1-level up parent so we can nest.
        # add "make it, preserving resource values and perms" to the steps-to-take.
        #print "Destination pool does not exist.\n";
        my $newpool_name = $new_pools_paths[$#new_pools_paths];
        my $parentpool   = $new_pools_refs[$#new_pools_refs];
        print "'".$newpool_name."' does not exist in $newcluster, but we can make it under '".$parentpool->name."'\n";
        $movement_info{'createpool'} = {'oldpool' => $oldpool, 'parentpool' => $parentpool, 'newpool_name' => $newpool_name, };
    } else {
        print "Unable to determine where to place this pool.  Create the parent pools and try again.\n";
        exit;
    }

    printf STDOUT '%-30s', "DRS rules: ";
    my $oldrules = $movement_info{'oldcluster'}->configurationEx->rule;
    my $newrules = $movement_info{'newcluster'}->configurationEx->rule;
    if (!$oldrules) {
        print "No rules found on the old cluster\n";
    } else {
        my %found_groups = ();
        my %vm_map = map { $_->name => 1 } @{$movement_info{'movevms'}->{'vms'}};
        foreach my $rule (sort { $a->name cmp $b->name } @{$oldrules}) {
            my $rule_name = $rule->name;
            if ($rule->isa('ClusterAntiAffinityRuleSpec') || $rule->isa('ClusterAffinityRuleSpec')) {
                next if (!defined($rule->vm) || scalar(@{$rule->vm}) == 0);
                next;  # DRS rules get ported over if you move in bulk, as of 6.0
            } elsif ($rule->isa('ClusterVmHostRuleInfo')) {
                my $this_rule_applies = 0;
                next if (!defined($rule->vmGroupName));
                next if (!defined($rule->affineHostGroupName) && !defined($rule->antiAffineHostGroupName));

                my ($group) = grep { $_->name eq $rule->vmGroupName }
                                   @{$movement_info{'oldcluster'}->configurationEx->group};
                next if (!defined($group->vm) || scalar(@{$group->vm}) == 0);
                my $group_name = $group->name;
                foreach my $vm_obj (@{$group->vm}) {
                    # Everything says not to do this in a loop.  But we need the moref.
                    my $vm = Vim::get_view(view_type => 'VirtualMachine', mo_ref => $vm_obj, properties => ['name'], );
                    next unless ($vm_map{$vm->name});
                    # At this point, the rule applies to us because we have a VM match within the VM group.  Record it:
                    $this_rule_applies = 1;
                           $found_groups{$group_name}{'vmgroup'} = $group;
                           $found_groups{$group_name}{'rule'}  = $rule;
                    push @{$found_groups{$group_name}{'vms'}}, $vm;
                    push @{$found_groups{$group_name}{'vms_mo'}}, $vm_obj;
                }
                
                if ($this_rule_applies) {
                    my $target_name = $rule->affineHostGroupName || $rule->antiAffineHostGroupName || '';
                    my ($found_newhostgroup) = grep { $_->name eq $target_name }
                                                    @{$movement_info{'newcluster'}->configurationEx->group};
                    if (!$found_newhostgroup) {
                        print "Rule '$rule_name' points to a Host Group named '$target_name' in the old cluster.\n";
                        print "Could not find a Host Group named '$target_name' in the new cluster.\n";
                        print "Since we don't know what hosts would be in this, we can't create it for you.\n";
                        print "Go make a Host Group called '$target_name', fill it with some hosts, then run this again.\n";
                        exit;
                    }
                }

            } else {
                print "Unexpected rule type found, ".$rule->name."\n";
                print "Bailing out, you should look into this.\n";
                exit;
            }
        }
        if (keys %found_groups) {
            print "\n";
            #
            # Everything in here is a VM group.
            # Earlier in the preflight, we demanded that any hostgroups affected be created by
            # hand due to the obvious difference in contents across clusters.
            #
            foreach my $group_name (keys %found_groups) {
                my $rule    = $found_groups{$group_name}{'rule'};
                my $vmgroup = $found_groups{$group_name}{'vmgroup'};
                my @vms_detected  = @{$found_groups{$group_name}{'vms'}};
                my $vms_in_group_ref = Vim::get_views(view_type => 'VirtualMachine', mo_ref_array => $vmgroup->vm, properties => ['name'], );
                my %vm_detect    = map { $_->name => 1 } @vms_detected;
                my %vm_in_groups = map { $_->name => 1 } @$vms_in_group_ref;
                foreach my $vm_d (keys %vm_detect) {
                    delete $vm_in_groups{$vm_d};
                }
                if (scalar keys %vm_in_groups) {
                    print "  Group '$group_name' has VMs that will be left behind if you move just these VMs.\n";
                    print "  They are: ".join(' ', sort keys %vm_in_groups)."\n";
                } else {
                    push @{$movement_info{'deleteoldgrouprule'}}, { 'oldrule'   => $rule,    };
                    push @{$movement_info{'deleteoldgroup'}},     { 'oldgroup'  => $vmgroup, };
                }
                my $target_name = $rule->vmGroupName;
                my ($found_newhostgroup) = grep { $_->name eq $target_name }
                                               @{$movement_info{'newcluster'}->configurationEx->group};
                if (defined $found_newhostgroup) {
                    push @{$movement_info{'copyvmgroup'}},      { 'newgroup' => $found_newhostgroup, 'vms' => $found_groups{$group_name}{'vms_mo'}, };
                } else {
                    push @{$movement_info{'makeemptyvmgroup'}}, { 'oldgroup' => $vmgroup, 'vms' => $found_groups{$group_name}{'vms_mo'}, };
                    # ^ this will do the copyvmgroup setup.  Don't worry about this discrepancy.
                }
                my ($newrule) = grep { $_->name eq $rule->name and $_->isa('ClusterVmHostRuleInfo') }
                                          @{$newrules};
                if (defined($newrule)) {
                    foreach my $attr ('affineHostGroupName', 'antiAffineHostGroupName', 'vmGroupName', ) {
                        if ( (defined($rule->{$attr}) != defined($newrule->{$attr})) ||
                             (defined($rule->{$attr}) && ($rule->{$attr} ne $newrule->{$attr}))
                            ) {
                            print '  Preexisting rule '.$newrule->name." is different between clusters.  Please manually resolve.\n";
                            exit;
                        }
                    }
                } else {
                    push @{$movement_info{'copygrouprules'}},   { 'oldrule'  => $rule, };
                }
            }
        } else {
            print "no relevant rules found\n";
        }
    }

    return %movement_info;
}

sub do_actions {
    my ($doit, $movement_info_ref, ) = @_;
    my %movement_info = %${movement_info_ref};
    print "### ".($doit ? "Changes" : "Plan Summary")."\n";
    
    # Order of actions
    foreach my $step ('createpool', 'movevms', 'deletedrsrule', 'makeemptyvmgroup', 'copyvmgroup', 'copygrouprules', 'deletepool', 'deleteoldgrouprule', 'deleteoldgroup', ) {
        # 
        # Reminder: think 4th-dimensionally here.  movevms is a Task and an async, so any views must be
        # refreshed to avoid acting on stale data.
        #
        my $activity = $movement_info{$step};
        next unless (defined $activity);
        if ($step eq 'createpool') {
            my $oldpool      = $activity->{'oldpool'};
            my $newpool_name = $activity->{'newpool_name'};
            my $parentpool   = $activity->{'parentpool'};
            if ($doit) {
                print "Creatng a new resource pool named ".$newpool_name." under [".$movement_info{'newcluster'}->name.'] '.$parentpool->name."...  ";
                my $cpusharesLevel = SharesLevel->new($oldpool->config->cpuAllocation->shares->level->val);
                my $memsharesLevel = SharesLevel->new($oldpool->config->memoryAllocation->shares->level->val);
                my $cpuShares = SharesInfo->new(level => $cpusharesLevel, shares => $oldpool->config->cpuAllocation->shares->shares, );
                my $memShares = SharesInfo->new(level => $memsharesLevel, shares => $oldpool->config->memoryAllocation->shares->shares, );
                my $cpuAllocation = ResourceAllocationInfo->new(expandableReservation => $oldpool->config->cpuAllocation->expandableReservation, limit => $oldpool->config->cpuAllocation->limit, reservation => $oldpool->config->cpuAllocation->reservation, shares => $cpuShares);
                my $memAllocation = ResourceAllocationInfo->new(expandableReservation => $oldpool->config->memoryAllocation->expandableReservation, limit => $oldpool->config->memoryAllocation->limit, reservation => $oldpool->config->memoryAllocation->reservation, shares => $memShares);
                my $rc_spec = ResourceConfigSpec->new(cpuAllocation => $cpuAllocation, memoryAllocation => $memAllocation);
                my $newpool_moref = $parentpool->CreateResourcePool(name => $newpool_name, spec => $rc_spec);
                my @newperms = ();
                if ($oldpool->permission) {
                    foreach my $oldperm (@{$oldpool->permission}) {
                        my $newperm = Permission->new(group => $oldperm->group, principal => $oldperm->principal, propagate => $oldperm->propagate, roleId => $oldperm->roleId,);
                        push @newperms, $newperm;
                    }
                }
                my $content = Vim::get_service_content();
                my $authMgr = Vim::get_view(mo_ref => $content->authorizationManager);
                $authMgr->SetEntityPermissions(entity => $newpool_moref, permission => \@newperms);
                my $newpool = Vim::get_view(view_type => 'ResourcePool', mo_ref => $newpool_moref, );
                $movement_info{'movevms'}->{'newpool'} = $newpool;
                print "done.\n";
            } else {
                print "Would create a new pool named ".$newpool_name." under [".$movement_info{'newcluster'}->name.'] '.$parentpool->name." in the image of the old pool ".$oldpool->name.".\n";
            }
        } elsif ($step eq 'movevms') {
            my @vms        = @{$activity->{'vms'}};
            my $newpool    = $activity->{'newpool'};
            if ($doit) {
                my %tasks = ();
                foreach my $vm (@vms) {
                    my $relo_spec = VirtualMachineRelocateSpec->new(pool => $newpool,);
                    print "Submitting move of ".$vm->name." to ".$newpool->name."...  ";
                    my $task_mo = $vm->RelocateVM_Task(spec => $relo_spec, );
                    print "done.\n";
                    $tasks{$vm->name} = $task_mo;
                }

                $| = 1;
                print "Sleeping 15 seconds to let these VMs get moving... "; sleep 15 ; print "done.\n";
                my $lastlen = '';
                while (keys %tasks) {
                    foreach my $vm (sort keys %tasks) {
                        my $task    = Vim::get_view(view_type => 'Task', mo_ref => $tasks{$vm}, );
                        if ($task->info->state->val eq 'success') {
                            delete $tasks{$vm};
                        } elsif ($task->info->state->val eq 'error') {
                            print "Move of $vm errored out.  Stopping here.\n";
                            exit;
                        }
                        # Any other state is queued or running.
                    }
                    if (keys %tasks) {
                        my $note = "Waiting on ".join(' ', sort keys %tasks).' ';
                        print "\r" if ($lastlen);
                        printf '%'.$lastlen.'s', $note;
                        sleep 5;
                        $lastlen = '-'.length($note);
                    }
                }
                print "\nAll VM moves completed.\n";
            } else {
                my $newpoolname    = $newpool ? $newpool->name : 'the above pool (yet to be created)';
                foreach my $vm (@vms) {
                    print "Would move ".$vm->name." to ".$newpoolname."\n";
                }
            }
        } elsif ($step eq 'deletepool') {
            #
            # Paranoia: this should only have been invoked if it was prechecked to be evac'ed.
            # But.  Check again.
            #
            my $oldpoolref = $activity->{'oldpoolref'};
            my $oldpool = Vim::get_view(view_type => 'ResourcePool', mo_ref => $oldpoolref, );
            # ^ Need the most up-to-date view since pool contents will have changed in the VM moves.
            if ($doit) {
                print "Deleting old resource pool ".$oldpool->name."... ";
                my $belay = 0;
                if ($oldpool->vm) {
                    my $vms_ref = Vim::get_views(view_type => 'VirtualMachine', mo_ref_array => $oldpool->vm, properties => ['name', ], );
                    if (scalar(@$vms_ref)) {
                        print "NOT deleting ".$oldpool->name." since I found VMs ".join(' ', map { $_->name } @$vms_ref)."\n";
                        $belay = 1;
                    }
                }
                if ($oldpool->resourcePool) {
                    my $subpools_ref = Vim::get_views(view_type => 'ResourcePool', mo_ref_array => $oldpool->resourcePool, properties => ['name', ], );
                    if (scalar(@$subpools_ref)) {
                        print "NOT deleting ".$oldpool->name." since I found child pools ".join(' ', map { $_->name } @$subpools_ref)."\n";
                        $belay = 1;
                    }
                }
                if (!$belay) {
                    $oldpool->Destroy_Task();
                    print "done.\n";
                }
            } else {
                print "Would delete old pool ".$oldpool->name." (I expect it will be empty, but will check again beforehand)\n";
            }
        } elsif ($step eq 'makeemptyvmgroup') {
            my @todo_steps = @$activity;
            if ($doit) {
                foreach my $step (@todo_steps) {
                    my $oldgroup = $step->{'oldgroup'};
                    my $vms_ref = $step->{'vms'};
                    print "Creating an empty VM Group '".$oldgroup->name."'... ";
                    my $groupSpec = ClusterGroupSpec->new();
                       $groupSpec->{'operation'} = ArrayUpdateOperation->new('add');
                       $groupSpec->{'info'} = ClusterVmGroup->new('name' => $oldgroup->name, );
                    my $clusterSpec = new ClusterConfigSpecEx();
                       $clusterSpec->{'groupSpec'} = [ $groupSpec ];
                    $movement_info{'newcluster'}->ReconfigureComputeResource(spec => $clusterSpec, modify => 1);
                    $movement_info{'newcluster'}->RefreshRecommendation();
                    my $newcluster = $movement_info{'newcluster'}->name;
                    # Reminder: think 4th-dimensionally here.
                    # Refetch the cluster vision, since you changed it.
                    my $cluster_ref = Vim::find_entity_view(view_type => 'ClusterComputeResource', properties => ['name', 'configurationEx',], filter => { name => qr#^$newcluster$# } );
                    my $newgroups = $cluster_ref->configurationEx->group;
                    my $found_newhostgroup = undef;
                    foreach my $group (@{$newgroups}) {
                        my $group_name = $group->name;
                        if ($oldgroup->name     eq $group_name) {
                            $found_newhostgroup = $group;
                            last;
                        }
                    }
                    push @{$movement_info{'copyvmgroup'}},      { 'newgroup' => $found_newhostgroup, 'vms' => $vms_ref, };
                    print "done\n";
                }
            } else {
                foreach my $step (@todo_steps) {
                    my $oldgroup = $step->{'oldgroup'};
                    my $vms_ref = $step->{'vms'};
                    my $vms = Vim::get_views(view_type => 'VirtualMachine', mo_ref_array => $vms_ref, properties => ['name', ], );
                    print "Would make a new VM Group '".$oldgroup->name."'\n";
                    push @{$movement_info{'copyvmgroup'}},      { 'newgroup' => '', 'vms' => $vms_ref, };
                }
            }

        } elsif ($step eq 'copyvmgroup') {
            #
            # Reminder: think 4th-dimensionally here.
            # We have been passed a view into oldgroup that is now old and invalid, as VMs will have moved.
            # BUT, that works fine since there's a possibility of the group being culled by autocleanup
            # during the VM move, so stale data is actually desirable.
            # We also assume that the new group (possibly empty and created seconds ago) exists, and therefore we're editing a group.
            #
            my @todo_steps = @$activity;
            if ($doit) {
                foreach my $step (@todo_steps) {
                    my $newgroup = $step->{'newgroup'};
                    my $vms_ref = $step->{'vms'};
                    my $vms = Vim::get_views(view_type => 'VirtualMachine', mo_ref_array => $vms_ref, properties => ['name', ], );
                    print 'Adding VMs ('.join(' ', map { '"'.$_->name.'"' } sort { $a->name cmp $b->name } @$vms ).") to Group '".$newgroup->name."'... ";
                    my $groupSpec = ClusterGroupSpec->new();
                       $groupSpec->{'operation'} = ArrayUpdateOperation->new('edit');
                       $groupSpec->{'info'} = ClusterVmGroup->new('name' => $newgroup->name, 'vm' => $vms_ref, );
                    my $clusterSpec = new ClusterConfigSpecEx();
                       $clusterSpec->{'groupSpec'} = [ $groupSpec ];
                    $movement_info{'newcluster'}->ReconfigureComputeResource(spec => $clusterSpec, modify => 1);
                    $movement_info{'newcluster'}->RefreshRecommendation();
                    print "done\n";
                }
            } else {
                foreach my $step (@todo_steps) {
                    my $newgroup = $step->{'newgroup'};
                    my $vms_ref = $step->{'vms'};
                    my $vms = Vim::get_views(view_type => 'VirtualMachine', mo_ref_array => $vms_ref, properties => ['name', ], );
                    print 'Would add VMs ('.join(' ', map { '"'.$_->name.'"' } sort { $a->name cmp $b->name } @$vms ).') to '.($newgroup ? "Group '".$newgroup->name."'" : 'the above group (yet to be created)')."\n";
                }
            }
        } elsif ($step eq 'copygrouprules') {
            # 
            # Reminder: think 4th-dimensionally here.
            # We're here to make a copy of the grouping rules into the new cluster.
            # We assume there's no rule already existing on the far side because we checked it before 
            # invoking the copygrouprules step in here.  So, we could run afoul, but let's assume not.
            #
            my @todo_steps = @$activity;
            if ($doit) {
                foreach my $step (@todo_steps) {
                    my $oldrule = $step->{'oldrule'};
                    print "Creating a Grouping rule in the style of '".$oldrule->name."'... ";
                    my $newrule = ClusterVmHostRuleInfo->new('name' => $oldrule->name, 'enabled' => 1, );
# FIXME - must or should?  There's a 'mandatory' boolean.  Needs testing.
                    foreach my $attr ('affineHostGroupName', 'antiAffineHostGroupName', 'vmGroupName', ) {
                        next unless (defined($oldrule->{$attr}));
                        $newrule->{$attr} = $oldrule->{$attr};
                    }
                    my $ruleSpec = ClusterRuleSpec->new();
                       $ruleSpec->{'operation'} = ArrayUpdateOperation->new('add');
                       $ruleSpec->{'info'} = $newrule;
                    my $clusterSpec = new ClusterConfigSpecEx();
                       $clusterSpec->{'rulesSpec'} = [ $ruleSpec ];
                    $movement_info{'newcluster'}->ReconfigureComputeResource(spec => $clusterSpec, modify => 1);
                    $movement_info{'newcluster'}->RefreshRecommendation();
                    print "done\n";
                }
            } else {
                foreach my $step (@todo_steps) {
                    my $oldrule = $step->{'oldrule'};
                    print "Would make a new Grouping rule '".$oldrule->name."'\n";
                }
            }
        } elsif ($step eq 'deletedrsrule') {
            my @todo_steps = @$activity;
            if ($doit) {
                foreach my $step (@todo_steps) {
                    my $oldrule = $step->{'oldrule'};
                    print "Deleting old Affine rule '".$oldrule->name."'... ";
                    my $ruleSpec = ClusterRuleSpec->new();
                       $ruleSpec->{'operation'} = ArrayUpdateOperation->new('remove');
                       $ruleSpec->{'removeKey'} = $oldrule->{'key'};
                    my $clusterSpec = new ClusterConfigSpecEx();
                       $clusterSpec->{'rulesSpec'} = [ $ruleSpec ];
                    $movement_info{'oldcluster'}->ReconfigureComputeResource(spec => $clusterSpec, modify => 1);
                    $movement_info{'oldcluster'}->RefreshRecommendation();
                    print "done\n";
                }
            } else {
                foreach my $step (@todo_steps) {
                    my $oldrule = $step->{'oldrule'};
                    print "Would delete the Affine rule '".$oldrule->name."' from the old cluster since its VMs have moved.\n";
                }
            }
        } elsif ($step eq 'deleteoldgrouprule') {
            my @todo_steps = @$activity;
            if ($doit) {
                foreach my $step (@todo_steps) {
                    my $oldrule = $step->{'oldrule'};
                    print "Deleting old Grouping rule '".$oldrule->name."'... ";
                    my $ruleSpec = ClusterRuleSpec->new();
                       $ruleSpec->{'operation'} = ArrayUpdateOperation->new('remove');
                       $ruleSpec->{'removeKey'} = $oldrule->{'key'};
                    my $clusterSpec = new ClusterConfigSpecEx();
                       $clusterSpec->{'rulesSpec'} = [ $ruleSpec ];
                    $movement_info{'oldcluster'}->ReconfigureComputeResource(spec => $clusterSpec, modify => 1);
                    $movement_info{'oldcluster'}->RefreshRecommendation();
                    print "done\n";
                }
            } else {
                foreach my $step (@todo_steps) {
                    my $oldrule = $step->{'oldrule'};
                    print "Would delete the Grouping rule '".$oldrule->name."' from the old cluster since its VM group should be empty.\n";
                }
            }
        } elsif ($step eq 'deleteoldgroup') {
            my @todo_steps = @$activity;
            if ($doit) {
                foreach my $step (@todo_steps) {
                    my $oldgroup = $step->{'oldgroup'};
                    print "Deleting the empty VM Group '".$oldgroup->name."' from the old cluster... ";
                    my $groupSpec = ClusterGroupSpec->new();
                       $groupSpec->{'operation'} = ArrayUpdateOperation->new('remove');
                       $groupSpec->{'removeKey'} = $oldgroup->{'name'};
                    my $clusterSpec = new ClusterConfigSpecEx();
                       $clusterSpec->{'groupSpec'} = [ $groupSpec ];
                    $movement_info{'oldcluster'}->ReconfigureComputeResource(spec => $clusterSpec, modify => 1);
                    $movement_info{'oldcluster'}->RefreshRecommendation();
                    print "done\n";
                }
            } else {
                foreach my $step (@todo_steps) {
                    my $oldgroup = $step->{'oldgroup'};
                    print "Would delete the empty VM Group '".$oldgroup->name."' from the old cluster.\n";
                }
            }
        } else {
            print "Unhandled use case '$step', aborting";
            exit;
        }
        # FIXME 2 this is a temporary blocker
            if ($doit) {
                print "Done with step '$step'.  Press enter to go on.\n"; <STDIN>;
            }
    }
}
