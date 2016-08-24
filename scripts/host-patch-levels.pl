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
# h/t http://www.virtuallyghetto.com/2016/08/quick-tip-how-to-retrieve-the-esxi-update-level-using-the-vsphere-api.html
# Checks your host patching levels
#

my %opts = (
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
get_all_patch_levels();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub get_all_patch_levels {
    my $hosts = Vim::find_entity_views(view_type => 'HostSystem', properties => ['name', 'config.product', 'configManager.advancedOption' ], );
    if (!$hosts) { print "Search for hosts failed.\n"; return (); }
    if (!(scalar @{$hosts})) { print "Found no hosts.\n"; return (); }
    foreach my $host (sort {$a->name cmp $b->name} @{$hosts}) {
      my $hostname = $host->name;
      my $update_level = '';
      if ($host->get_property('configManager.advancedOption')) {
         my $adv_opt = Vim::get_view (mo_ref => $host->{'configManager.advancedOption'});
         foreach my $opt (@{$adv_opt->setting()}) {
           if ($opt->key eq 'Misc.HostAgentUpdateLevel') {
              $update_level = $opt->value;
              last;
           }
         }
      }
      if ($host->get_property('config.product')) {
        print $hostname;
        print ' : Version '. $host->get_property('config.product.version');
        print $update_level ? 'u'.$update_level : '';
        print ' / Build '.  $host->get_property('config.product.build')."\n";
      }
    }
}
