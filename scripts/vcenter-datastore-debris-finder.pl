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
# Search through your datastores looking for incomplete deletes: folders and files
# left behind, unclaimed or badly deleted.
#
# There's been powershell versions of this that do the searching and the cleaning
# but, powershell.  And, I don't like to turn deletes on autopilot.  So this does
# the searching only.
#
# HT: http://www.lucd.info/2011/04/25/orphaned-files-and-folders-spring-cleaning/
# Modified semi-extensively to fit into my NetApp world.
#

my %opts = (
  'debug'              => { type => '!',  help => 'Trace the files that we consider', default => undef, required => 0},
  'ignore-datastore'   => { type => '=s', help => 'A datastore (like your ISOs volume) to ignore', default => undef, required => 0},
  'include-every-file' => { type => '!',  help => "Include nearly EVERY FILE on the datastore, including deprecated files.", default => undef, required => 0 },
  # Technically not EVERY file.  But you can read the code to learn more.
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $debug     = Opts::get_option('debug') || 0;
my $ignore_ds = Opts::get_option('ignore-datastore') || '';
my $scan_all_files = Opts::get_option('include-every-file') || 0;

# connect to the server
Util::connect(); #print "Server Connected\n";
scan_ds();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub debug {
    my ($line, ) = @_;
    if ($debug) {
        print STDERR $line;
    }
}

sub scan_ds {
    # This could run long in large environments.  Consider
    #     https://kb.vmware.com/kb/1017253
    # if you are blowing up.

    my @query;
    if ($scan_all_files) {
        # This scans for "if it's a file".  This picks up a lot of crap.
        # But unfortunately, you probably want to at least try this:
        # Some files, like -aux.xml (snapshotManifestList) and vmxf don't get caught by the 'catch everything'
        # in the 'else' part of the query.. which can leave you with near-empty directories to manually clean.
        # So this path is the 'go look at everything' firehose.  Don't delete things just because they show
        # up by activating this flag.  This is so you can help yourself.
        #
        # Now, as a side note, we DO engage a filter later in the process, to remove some common
        # garbage files.  Look for scan_all_files, below.
        my $qFile = FileQuery->new();
        @query = ($qFile);
    } else {
        # Build up the query specs for the datastore browser:
        # http://pubs.vmware.com/vsphere-60/topic/com.vmware.wssdk.apiref.doc/vim.host.DatastoreBrowser.Query.html
        my $qFloppy    = FloppyImageFileQuery->new();
        my $qFolder    = FolderFileQuery->new();
        my $qISO       = IsoImageFileQuery->new();
        my $qLog       = VmLogFileQuery->new();
        my $qRAM       = VmNvramFileQuery->new();
        my $qSnap      = VmSnapshotFileQuery->new();
        my $qConfig    = VmConfigFileQuery->new(details => VmConfigFileQueryFlags->new(configVersion => 0,), );
        my $qTemplate  = TemplateConfigFileQuery->new(details => VmConfigFileQueryFlags->new(configVersion => 0,), );
        my $qDisk      = VmDiskFileQuery->new(details => VmDiskFileQueryFlags->new(capacityKb => 0, diskExtents => 0, diskType => 0, hardwareVersion => 0, thin => 0,), );
        @query = ($qFloppy,$qFolder,$qISO,$qLog,$qRAM,$qSnap,$qConfig,$qTemplate,$qDisk,);
    }
    my $flags      = FileQueryFlags->new(fileOwner => 0, fileSize => 0, fileType => 0, modification => 0,);
    my $searchSpec = HostDatastoreBrowserSearchSpec->new(details => $flags, query => \@query, sortFoldersFirst => 1,);

    my $ds_refs = Vim::find_entity_views(view_type => 'Datastore', properties => ['name', 'browser', 'vm', 'summary.multipleHostAccess', ], );
    #my $ds_refs = Vim::find_entity_views(view_type => 'Datastore', properties => ['name', 'browser', 'vm', 'summary.multipleHostAccess', ], filter => { 'name' => qr/some_subset/ }, );
    #
    if (!$ds_refs) { Util::trace(0, "No Datastores found\n"); exit; }
    foreach my $ds (sort { $a->name cmp $b->name } @$ds_refs) {
        next if (!($ds->{'summary.multipleHostAccess'}));
        next if (!($ds->vm) || !(scalar(@{$ds->vm})));
        next if ($ds->name eq $ignore_ds);
        my $dspath = '['.$ds->name.']';
        print '### Searching '.$dspath."\n";

        my $browser = Vim::get_view(mo_ref => $ds->browser, );
        my $rootresults = $browser->SearchDatastore(datastorePath => $dspath, searchSpec => $searchSpec, );

        # It'd be nice if we didn't do this.  But there's no way to say "don't search .snapshot"
        # until AFTER it comes back.  And since snapshots can be many multiples of an already slow process...
        # we look at the root before doing iterations over the top-level directories.  Sorry.
        my @rootpaths;
        foreach my $file (@{$rootresults->file}) {
            # Skip items related to DVS, HA, and NetApp filers:
            next if ($file->path eq '.dvsData');
            next if ($file->path eq '.iorm.sf');
            next if ($file->path eq '.vSphere-HA');
            next if ($file->path eq '.snapshot');
            my $fullfile = $dspath.' '.$file->path;
            #Not even going to bother talking here, as this is eyeball-level scanning of the DS root.
            #debug("## found $fullfile\n");
            push @rootpaths, $fullfile;
        }

        my %files_on_datastore;
        my %vm_dirs;
        foreach my $rootpath (@rootpaths) {
            my $searchresults = $browser->SearchDatastoreSubFolders(datastorePath => $rootpath, searchSpec => $searchSpec, );
            foreach my $folder (@$searchresults) {
                my $folderpath = $folder->folderPath;
                if ($folder->file) {
                    foreach my $file (@{$folder->file}) {
                        my $fullfile = $folderpath.$file->path;
                        debug("## found $fullfile\n");
                        $files_on_datastore{$fullfile} = 1;
                        # We call this a 'real' directory if it has a .vmx or .vmtx
                        # We use this later...
                        $vm_dirs{$folderpath} = 1 if ($fullfile =~ m#\.vmt?x$#);
                    }
                    # This deletes things that are top-level directories and have subdirs.
                    # This prevents false-positives.  Since it's usually killing things that
                    # aren't even 'found', even the debug line is turned off.
                    # We put this inside the 'if' because we want to leave behind a reference to
                    # a directory where nothing underneath was found.
                    $folderpath =~ s#/$##;
                    #debug("## kill  $folderpath\n");
                    delete $files_on_datastore{$folderpath};
                }
            }
        }

        my $vm_refs = Vim::get_views(mo_ref_array => $ds->vm, view_type => 'VirtualMachine', properties => ['name', 'layoutEx.file', 'config.template', ], );
        foreach my $vm_ref (@$vm_refs) {
            foreach my $f (@{$vm_ref->{'layoutEx.file'}}) {
                 my $filename = $f->name;
                 debug("## kill  $filename\n");
                 delete $files_on_datastore{$filename};
                 # For whatever reason, a template doesn't have its template .vmtx in layoutEx, it lists the (not actually there) .vmx file
                 # HACK: So, here we hackily go through and remove the vmtx file if it's a template and there's a vmx.
                 if ($vm_ref->{'config.template'} && ($filename =~ s#\.vmx$#.vmtx#)) {
                     debug("## kill  $filename\n");
                     delete $files_on_datastore{$filename};
                 }
            }
        }
        
        foreach my $file (sort keys %files_on_datastore) {
            # Now, let's list all the files that didn't get claimed... mostly.
            if ($file =~ m#/vmware-\d+\.log$#) {
                # You're here because you have a rotated log file that no VM claimed.
                # Here's the catch: (I think) rotates can happen after a VM is off or templated.
                # So a VM directory can have files its VM doesn't know about.
                # The idea here is, if you have a directory that's "real" (has a VMX or VMTX)
                # then SOME logs are supposed to be there, so if we whiffed on some of them,
                # just forget it.
                #
                # The pitfall here is pretty much zero: if you have an unowned VMX file, you
                # won't be told about these logs, but you WILL see the VMX and thus the logs
                # when you go looking.
                (my $tmpcopy = $file) =~ s#/.*?$#/#;
                next if ($vm_dirs{$tmpcopy});
            } elsif ($scan_all_files) {
                # You're here if you enabled the flag to scan the entire datastore.
                # Some files (the lock file against vmx, and the hlog of "I've been vMotioned")
                # are total wastes of time and space, so we don't report on them.
                #
                # The risk here is that we could fail to report a directory that JUST has
                # these hidden files, but, unlikely.  The lock is tied to a VMX, and while the hlog
                # COULD be the last-man-standing, I've not encountered this case before.
                next if ($file =~ m#(\.hlog|\.vmx\.lck)$#);
            }
            print $file."\n";
        }

    }
}
