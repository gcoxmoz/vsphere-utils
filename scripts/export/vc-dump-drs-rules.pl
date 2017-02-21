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
    'clusterName' => { type => '=s', help => 'Cluster name', required => 0},
    'groups'      => { type => '!',  help => 'Use --nogroups not to show groups', default => 1, required => 0},
    'vms'         => { type => '!',  help => 'Use --novms    not to show VMs',    default => 1, required => 0},
    'json'        => { type => '',   help => 'Export listing as JSON', required => 0},
    );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my @output = ();
searchRules();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub searchRules {
    # Find the Cluster
    my $clusterName = Opts::get_option('clusterName');
    my $clusters_ref = Vim::find_entity_views(view_type => 'ClusterComputeResource', properties => ['name', 'configurationEx'], filter => $clusterName ? { name => $clusterName } : {} );
    if (!@{$clusters_ref}) { Util::trace(0, "ComputeResource '" . $clusterName . "' not found\n"); return; }

    foreach my $cluster_ref (sort { $a->name cmp $b->name } @{$clusters_ref}) {
      my $groups = $cluster_ref->configurationEx->group;
      if (defined($groups) && Opts::get_option('groups')) {
          foreach my $group (sort { $a->name cmp $b->name } @{$groups}) {
              my $json = {};
              my $group_name = $group->name;
              $json->{'cluster'} = $cluster_ref->name;
              $json->{'name'}    = $group_name;
              if ($group->isa('ClusterHostGroup')) {
                  next unless (defined($group->host));
                  $json->{'type'} = 'ClusterHostGroup';
                  my @hosts = sort map { $_->{'name'} }  @{ Vim::get_views( mo_ref_array => $group->host , properties => ['name'], ) };
                  $json->{'hosts'} = \@hosts;
              } elsif ($group->isa('ClusterVmGroup')) {
                  $json->{'type'} = 'ClusterVmGroup';
                  next unless (defined($group->vm));
                  my @vms = sort map { $_->{'config.name'} }  @{ Vim::get_views( mo_ref_array => $group->vm , properties => ['config.name'], ) };
                  $json->{'vms'} = \@vms;
              } else {
                  print "### Group '$group_name' isn't of a type I understand.\n";
              }
              my $json_blob; %{$json_blob} = %$json;
              push @output, $json_blob;
          }
      }

      my $rules = $cluster_ref->configurationEx->rule;
      if (defined($rules) && Opts::get_option('vms')) {
          foreach my $rule (sort { $a->name cmp $b->name } @{$rules}) {
              my $json = {};
              my $rule_name = $rule->name;
              $json->{'cluster'} = $cluster_ref->name;
              $json->{'name'}    = $rule_name;
              if ($rule->isa('ClusterAntiAffinityRuleSpec')) {
                  $json->{'type'} = 'ClusterAntiAffinityRuleSpec';
                  my @vms = sort map { $_->{'config.name'} }  @{ Vim::get_views( mo_ref_array => $rule->vm , properties => ['config.name'], ) };
                  $json->{'vms'} = \@vms;
              } elsif ($rule->isa('ClusterAffinityRuleSpec')) {
                  $json->{'type'} = 'ClusterAffinityRuleSpec';
                  my @vms = sort map { $_->{'config.name'} }  @{ Vim::get_views( mo_ref_array => $rule->vm , properties => ['config.name'], ) };
                  $json->{'vms'} = \@vms;
              } elsif ($rule->isa('ClusterVmHostRuleInfo')) {
                  $json->{'type'} = 'ClusterVmHostRuleInfo';
                  $json->{'affineHostGroupName'} = $rule->affineHostGroupName if ($rule->affineHostGroupName);
                  $json->{'antiAffineHostGroupName'} = $rule->antiAffineHostGroupName if ($rule->antiAffineHostGroupName);
                  $json->{'vmGroupName'} = $rule->vmGroupName if ($rule->vmGroupName);
              } else {
                  print "### Rule '$rule_name' isn't of a type I understand.\n";
              }
              my $json_blob; %{$json_blob} = %$json;
              push @output, $json_blob;
          }
      }

    }
    if (Opts::get_option('json') || 1) {
        # Too much info NOT to print it all, so, just do so.
        print to_json(\@output, {utf8 => 1, pretty => 1, canonical => 1, });
    }

}
