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
my @rules = ();
if (!$rulesfile || ! -f $rulesfile) {
    die "Privileges file not provided.\n";
} else {
    open( FH, '<'.$rulesfile ) or die "Can't open JSON file $rulesfile: $!\n";
    my $json_text = join '', <FH>;
    close FH;
    my $rules_ref = from_json($json_text);
    @rules = @$rules_ref;
}

# connect to the server
Util::connect(); #print "Server Connected\n";
importRules();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub importRules {
    RULE: foreach my $rule_ref (@rules) {
        my $cluster_name = $rule_ref->{'cluster'};
        my $rule_name    = $rule_ref->{'name'};
        my $rule_type    = $rule_ref->{'type'};
        my $newrule      = undef;
        my $cluster_ref = Vim::find_entity_view(view_type => 'ClusterComputeResource', filter => { name => $cluster_name } );
        if (!$cluster_ref) {
            print "Could not find a cluster named $cluster_name.  Not applying rule $rule_name.\n";
            next RULE;
        }
        my $existing_rules = $cluster_ref->configurationEx->rule;
        if ($existing_rules) {
            foreach my $oldrule (@{$existing_rules}) {
                if ($oldrule->name eq $rule_name) {
                    print "### There is already a rule on $cluster_name named $rule_name.  Skipping.\n";
                    next RULE;
                }
            }
        }
        if (! $rule_type) {
            print STDERR "$rule_name did not have a 'type' attribute declared.\n";
            next RULE;
        } elsif (($rule_type eq 'ClusterAntiAffinityRuleSpec') || ($rule_type eq 'ClusterAffinityRuleSpec')) {
            my $vms_ref = $rule_ref->{'vms'};
                 if ($rule_type eq 'ClusterAntiAffinityRuleSpec') {
                $newrule = ClusterAntiAffinityRuleSpec->new('enabled' => 1, 'name' => $rule_name, );
            } elsif ($rule_type eq 'ClusterAffinityRuleSpec') {
                $newrule = ClusterAffinityRuleSpec->new(    'enabled' => 1, 'name' => $rule_name, );
            }
            my @vm_mors = ();
            foreach my $vm_name (@$vms_ref) {
                my $vm_mor = Vim::find_entity_view(view_type => 'VirtualMachine', filter => { name => $vm_name } );
                if (!$vm_mor) {
                    print STDERR "Did not find a VM named $vm_name on $cluster_name.  Skipping $rule_name.\n";
                    next RULE;
                }
                push @vm_mors, $vm_mor;
            }
            $newrule->{'vm'} = [ @vm_mors ];
        } elsif ($rule_type eq 'ClusterVmHostRuleInfo') {
            $newrule = ClusterVmHostRuleInfo->new('enabled' => 1, 'name' => $rule_name, );
            my $existing_groups = $cluster_ref->configurationEx->group;
            if ($existing_groups) {
                foreach my $attr ('affineHostGroupName', 'antiAffineHostGroupName', 'vmGroupName', ) {
                    next unless (defined($rule_ref->{$attr}));
                    my ($found_group) = grep { $_->name eq $rule_ref->{$attr} } @{$existing_groups};
                    if ($found_group) {
                        $newrule->{$attr} = $rule_ref->{$attr};
                    } else {
                        print STDERR "$cluster_name does not have a ".$rule_ref->{$attr}." group for $rule_name to use.\n";
                        next RULE;
                    }
                }
            } else {
                print STDERR "$cluster_name did not have any groups; can't apply $rule_name.\n";
                next RULE;
            }

        } else {
            print STDERR "$rule_name had an unsupported 'type' $rule_type.\n";
            next RULE;
        }
        next RULE unless (defined $newrule);
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
            print STDERR "$cluster_name / $rule_name failed: ";
            print(($@->isa('SoapFault') ? $@->fault_string : $@) . "\n");
        } else {
            print STDERR "$cluster_name / $rule_name successfully added.\n";
        }
    }
}
