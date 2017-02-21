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
#
#

use JSON;
my %opts = (
   'rulesfile'      => { type => '=s', help => 'Rules configuration file, in JSON format', required => 1},
    );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $rulesfile = Opts::get_option('rulesfile');
my @inputs = ();
if (!$rulesfile || ! -f $rulesfile) {
    die "Privileges file not provided.\n";
} else {
    open( FH, '<'.$rulesfile ) or die "Can't open JSON file $rulesfile: $!\n";
    my $json_text = join '', <FH>;
    close FH;
    my $inputs_ref = from_json($json_text);
    @inputs = @$inputs_ref;
}

# connect to the server
Util::connect(); #print "Server Connected\n";
importFile();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub importFile {
    INPUT: foreach my $input_ref (@inputs) {
        my $cluster_name = $input_ref->{'cluster'};
        my $input_type    = $input_ref->{'type'};
        my $input_name    = $input_ref->{'name'};
        my $cluster_ref = Vim::find_entity_view(view_type => 'ClusterComputeResource', filter => { name => $cluster_name } );
        if (!$cluster_ref) {
            print "Could not find a cluster named '$cluster_name'.  Not applying input line '$input_name'.\n";
            next INPUT;
        } elsif (! $input_type) {
            print STDERR "$input_name did not have a 'type' attribute declared.\n";
            next INPUT;
        }

        if (($input_type eq 'ClusterAntiAffinityRuleSpec') || ($input_type eq 'ClusterAffinityRuleSpec') || ($input_type eq 'ClusterVmHostRuleInfo')) {
            my $existing_rules = $cluster_ref->configurationEx->rule;
            if ($existing_rules) {
                foreach my $oldrule (@{$existing_rules}) {
                    if ($oldrule->name eq $input_name) {
                        print "### There is already a rule on $cluster_name named $input_name.  Skipping.\n";
                        next INPUT;
                    }
                }
            }

            my $newrule      = undef;
            if (($input_type eq 'ClusterAntiAffinityRuleSpec') || ($input_type eq 'ClusterAffinityRuleSpec')) {
                my $vms_ref = $input_ref->{'vms'};
                     if ($input_type eq 'ClusterAntiAffinityRuleSpec') {
                    $newrule = ClusterAntiAffinityRuleSpec->new('enabled' => 1, 'name' => $input_name, );
                } elsif ($input_type eq 'ClusterAffinityRuleSpec') {
                    $newrule = ClusterAffinityRuleSpec->new(    'enabled' => 1, 'name' => $input_name, );
                }
                my @vm_mors = ();
                foreach my $vm_name (@$vms_ref) {
                    my $vm_mor = Vim::find_entity_view(view_type => 'VirtualMachine', filter => { name => $vm_name } );
                    if (!$vm_mor) {
                        print STDERR "Did not find a VM named $vm_name on $cluster_name.  Skipping $input_name.\n";
                        next INPUT;
                    }
                    push @vm_mors, $vm_mor;
                }
                $newrule->{'vm'} = [ @vm_mors ];
            } elsif ($input_type eq 'ClusterVmHostRuleInfo') {
                $newrule = ClusterVmHostRuleInfo->new('enabled' => 1, 'name' => $input_name, );
                my $existing_groups = $cluster_ref->configurationEx->group;
                if ($existing_groups) {
                    foreach my $attr ('affineHostGroupName', 'antiAffineHostGroupName', 'vmGroupName', ) {
                        next unless (defined($input_ref->{$attr}));
                        my ($found_group) = grep { $_->name eq $input_ref->{$attr} } @{$existing_groups};
                        if ($found_group) {
                            $newrule->{$attr} = $input_ref->{$attr};
                        } else {
                            print STDERR "$cluster_name does not have a ".$input_ref->{$attr}." group for '$input_name' to use.\n";
                            next INPUT;
                        }
                    }
                } else {
                    print STDERR "$cluster_name did not have any groups; can't apply '$input_name'.\n";
                    next INPUT;
                }
    
            } else {
                print STDERR "$input_name had an unsupported 'type' '$input_type'.\n";
                next INPUT;
            }
            next INPUT unless (defined $newrule);
            my $ruleSpec = ClusterRuleSpec->new();
               $ruleSpec->{'operation'} = ArrayUpdateOperation->new('add');
               $ruleSpec->{'info'} = $newrule;
            my $clusterSpec = new ClusterConfigSpecEx();
               $clusterSpec->{'rulesSpec'} = [ $ruleSpec ];
            eval {
                $cluster_ref->ReconfigureComputeResource(spec => $clusterSpec, modify => 1, );
                $cluster_ref->RefreshRecommendation();
            };
            if ($@) {
                print STDERR "$cluster_name / $input_name failed: ";
                print(($@->isa('SoapFault') ? $@->fault_string : $@) . "\n");
            } else {
                print STDERR "$cluster_name / $input_name successfully added.\n";
            }
        } elsif (($input_type eq 'ClusterHostGroup') || ($input_type eq 'ClusterVmGroup')) {
            my $existing_groups = $cluster_ref->configurationEx->group;
            if ($existing_groups) {
                foreach my $oldgroup (@{$existing_groups}) {
                    if ($oldgroup->name eq $input_name) {
                        print "### There is already a group on $cluster_name named '$input_name'.  Skipping.\n";
                        next INPUT;
                    }
                }
            }

            my $newgroup      = undef;
                 if ($input_type eq 'ClusterHostGroup') {
                         $newgroup = ClusterHostGroup->new('name' => $input_name, );
                my $hosts_ref = $input_ref->{'hosts'};
                my @host_mors = ();
                foreach my $host_name (@$hosts_ref) {
                    my $host_mor = Vim::find_entity_view(view_type => 'HostSystem', filter => { name => $host_name } );
                    if (!$host_mor) {
                        print STDERR "Did not find a host named $host_name on $cluster_name.  Skipping '$input_name'.\n";
                        next INPUT;
                    }
                    push @host_mors, $host_mor;
                }
                $newgroup->{'host'} = [ @host_mors ];
            } elsif ($input_type eq 'ClusterVmGroup') {
                    $newgroup =      ClusterVmGroup->new(  'name' => $input_name, );
                my $vms_ref = $input_ref->{'vms'};
                my @vm_mors = ();
                foreach my $vm_name (@$vms_ref) {
                    my $vm_mor = Vim::find_entity_view(view_type => 'VirtualMachine', filter => { name => $vm_name } );
                    if (!$vm_mor) {
                        print STDERR "Did not find a VM named $vm_name on $cluster_name.  Skipping '$input_name'.\n";
                        next INPUT;
                    }
                    push @vm_mors, $vm_mor;
                }
                $newgroup->{'vm'} = [ @vm_mors ];
            } else {
                print STDERR "$input_name had an unsupported 'type' $input_type.\n";
                next INPUT;
            }
            next INPUT unless (defined $newgroup);
            my $groupSpec = ClusterGroupSpec->new();
               $groupSpec->{'operation'} = ArrayUpdateOperation->new('add');
               $groupSpec->{'info'} = $newgroup;
            my $clusterSpec = new ClusterConfigSpecEx();
               $clusterSpec->{'groupSpec'} = [ $groupSpec ];
            eval {
                $cluster_ref->ReconfigureComputeResource(spec => $clusterSpec, modify => 1, );
                $cluster_ref->RefreshRecommendation();
            };
            if ($@) {
                print STDERR "$cluster_name / $input_name failed: ";
                print(($@->isa('SoapFault') ? $@->fault_string : $@) . "\n");
            } else {
                print STDERR "$cluster_name / $input_name successfully added.\n";
            }

        } else {
            print STDERR "$input_name had an unsupported 'type' '$input_type'.\n";
            next INPUT;
        }

    }
}
