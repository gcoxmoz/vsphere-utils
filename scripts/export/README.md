These scripts are mostly dirty one-off environment-specific items.

VMware is, in our experience, more and more often asking to blow away vCenter and recreate it from scratch.
They've also indicated (twice) that there's "some sort of corruption" in the VC.  So we don't trust doing a backup and restore.
Maybe that's easy when you don't have a lot of customizations.  But that's not my experience.

That leads to us needing to export/reimport our configurations (e.g roles, permissions, folders/pools) the hard way.

This directory is for scripts related to that.
