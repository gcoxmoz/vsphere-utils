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
# The main killer of your shared storage is VMs doing mean things to it.
# Also, if you need to find out what kind of IOPS load you're facing for
# something going to the clown^wcloud.
#
# We focus on the average read/write operations here, instantaneously.
# It's very easy, on a NetApp filer, to see who's beating up a volume,
# and hard to tie that back to a VM.  This aims to fill that gap, to
# find the VM you never suspected was misbehaving.
# If you want more deep-diving on one VM, use the web client.
# If you want more/different metrics, fork away.
# This solves the need that we had.
#

my @interesting_metrics  = qw( virtualDisk.numberReadAveraged.average virtualDisk.numberWriteAveraged.average );
my $minimum_iops_default = 30;
# Picked 30 based on the dubious logic of "a 10GB volume at 3 IOPS/GB".
my %opts = (
    'minimum-iops' => { type => '=i', help => 'Hide IOPS averages below THIS number (default: '.$minimum_iops_default.')', required => 0},
);

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $minimum_iops = defined(Opts::get_option('minimum-iops')) ? int(Opts::get_option('minimum-iops')) : $minimum_iops_default;
die "Minimum IOPS must be an positive integer.\n" unless ($minimum_iops >= 0);

# connect to the server
Util::connect(); #print "Server Connected\n";
get_stats();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub get_stats {
    my $service_content = Vim::get_service_content();
    my $perfMgr = Vim::get_view(mo_ref => $service_content->perfManager);
    my $perfCounterInfo = $perfMgr->perfCounter;
    my %allCounterDefintions = map { $_->key => $_  } @$perfCounterInfo;

    my $max_hostname_string = 10;  # Baseline, grows edited later.

    my %metrics = map { $_ => 1 } @interesting_metrics;

    my @perfqueryspecs;
    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => [ 'name', 'runtime.powerState', 'config.hardware.device', ], filter => { 'runtime.powerState' => 'poweredOn' } );
    #my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => [ 'name', 'runtime.powerState', 'config.hardware.device', ], filter => { 'name' => qr/^dev/ } ); # faster for testing

    foreach my $vm (@$vms) {
        our @metricIDs = ();
        $max_hostname_string = length($vm->name) if (length($vm->name) > $max_hostname_string);
        ###########################################################################
        #
        # This bit is brainless and wasteful.  We are verifying that the VM has 
        # the metrics markers that we want.  Since it's enabled at the VC level
        # for all VMs, we're effectively doing an inefficient loop to get the
        # same answer every time.  But, it's not the least efficient thing, and
        # it's probably better than ever finding out I'm wrong and then trying
        # to find where it went wrong.
        #
        my $availmetricid = $perfMgr->QueryAvailablePerfMetric(entity => $vm);

        foreach my $metric_ref (sort {$a->counterId cmp $b->counterId} @$availmetricid) {
            # Look throough all the metrics this VM knows about...
            # Skip it if this VM has metrics that the whole counter doesn't know about (whaaaat?)
            next unless ($allCounterDefintions{$metric_ref->counterId});
            my $metric     = $allCounterDefintions{$metric_ref->counterId};
            my $groupInfo  = $metric->groupInfo->key;
            my $nameInfo   = $metric->nameInfo->key;
            my $rolluptype = $metric->rollupType->val;
            my $vmwInternalName = $groupInfo . "." . $nameInfo . "." . $rolluptype;
            # ^ e.g. cpu.usage.average
            # Now, move along if this wasn't a metric we care about.
            next unless ($metrics{$vmwInternalName});

            my $metricId = PerfMetricId->new(counterId => $metric->key, instance => '*');
            push @metricIDs, $metricId;
        }
        ###########################################################################
        #
        # Here is the code to do MORE stupid.  Here, let's look up the polling
        # interval for each VM so we don't ask the VM for info it can't have.
        # Again, crazy inefficient to be doing this in an iterative loop over
        # all your VMs.
        # This time, though, 20s is assumed below because 'real-time samplingPeriod is 20 seconds':
        # http://pubs.vmware.com/vsphere-60/topic/com.vmware.wssdk.apiref.doc/vim.HistoricalInterval.html
        # and this segment is edited out, but I leave it behind in case someone
        # needs it in the future.
        #
        # my $historical_intervals = $perfMgr->historicalInterval;
        # my $provider_summary = $perfMgr->QueryPerfProviderSummary(entity => $vm);
        # my @intervals;
        # if ($provider_summary->refreshRate) {
        #     if ($provider_summary->refreshRate != -1) {
        #         push @intervals, $provider_summary->refreshRate;
        #     }
        # }
        # foreach (@$historical_intervals) {
        #     ifc($_->samplingPeriod != -1) {
        #         push @intervals, $_->samplingPeriod;
        #     }
        # }
        # my $pqs = PerfQuerySpec->new(entity => $vm, maxSample => 10, intervalId => shift(@$intervalIds), metricId => \@metricIDs);
        ###########################################################################

        my $pqs = PerfQuerySpec->new(entity => $vm, maxSample => 10, intervalId => 20, metricId => \@metricIDs);
        # 10 samples so we can average things out and not get fooled by one-offs.
        # 20 seconds so we do realtime only
        push @perfqueryspecs, $pqs;
    }

    if (scalar(@perfqueryspecs) == 0) {
        print "### Unable to find the desired metrics on any VMs.\n";
        exit 1;
    }

    my %results;
    foreach my $singleperfquery (sort {lc($a->entity->name) cmp lc($b->entity->name)} @perfqueryspecs) {
        my $vmname = $singleperfquery->entity->name;

        my $device_ref = $singleperfquery->entity->{'config.hardware.device'};
        # Might be a hack here, but everything sane seems to use scsi, so...
        # Grab all the SCSI controllers first.
        my %scsi;
        foreach my $dev (@$device_ref) {
            next unless ($dev->deviceInfo->label =~ m#(SCSI|SATA|IDE)(?: controller)? (\d+)#);
            $scsi{$dev->key} = lc($1).$2;
        }

        # Now grab all the disks and cobble together a namesake that resembles what
        # we will eventually get back from our queries below.
        # This is pretty hackish and works by luck; if the returns from queries
        # change, this could go south very quickly.
        my %disks;
        foreach my $dev (@$device_ref) {
            next unless ($dev->deviceInfo->label =~ m#Hard disk#);
            $dev->backing->fileName =~ m#\[(.+)\]#;
            my $backing_store = $1;
            my $controller    = $scsi{$dev->controllerKey};
            my $scsi_id       = $dev->unitNumber;
            $disks{$controller.':'.$scsi_id} = $backing_store;
        }

        # So, we're iterating over these specs one at a time, basically per-VM.
        # My attempts to do this as an array were thwarted:
        # 1) QueryPerf came back with no response when we went over about 500 VMs.
        # I gave up debugging it after a while.
        # 2) The match-back against the entity, so I know whose data I'm looking
        # at, was not straightforward.  I ended up STILL having to iterate calls
        # to the VC, so in the interest of readability, I did it this way.
        # Not proud of it, but happy with the results.
        my $metrics = $perfMgr->QueryPerf(querySpec => [ $singleperfquery ] );
        # This is the PerfEntityMetric[] from the query
        # http://pubs.vmware.com/vsphere-60/topic/com.vmware.wssdk.apiref.doc/vim.PerformanceManager.EntityMetric.html

        foreach my $metric (@$metrics) {
            my $perfValues = $metric->value;
            # This is a PerfMetricIntSeries[] of the values from the query
            # http://pubs.vmware.com/vsphere-60/topic/com.vmware.wssdk.apiref.doc/vim.PerformanceManager.IntSeries.html
            # Note: we only did one query so this is a loop-over-1 here.
            # For our purposes, since we're only querying virtualdisks,
            # these are disk values, so I've jumped the variables right to that.

            foreach my $disk (sort { $a->id->instance cmp $b->id->instance } @$perfValues) {
                my $diskname = $disk->id->instance;
                my $values   = $disk->value;

                my $sum  = 0;
                   $sum += $_ for @$values;
                my $avg  = int($sum / scalar(@$values));
                next if ($avg < $minimum_iops);

                my $metricRef  = $allCounterDefintions{$disk->id->counterId};
                my $groupInfo  = $metricRef->groupInfo->key;
                my $nameInfo   = $metricRef->nameInfo->key;
                my $rollupType = $metricRef->rollupType->val;

                my $internalID = $groupInfo . '.' . $nameInfo . '.' . $rollupType;
                printf '%-'.$max_hostname_string.'s %-9s %-20s %-19s %6d'."\n", $vmname, $diskname, $disks{$diskname}, $nameInfo, $avg;
            }
        }
    }  # end of queryloop
} # end of subroutine

exit 0;

__END__

