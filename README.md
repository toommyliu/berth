# Berth

A macOS app for seeing what your [tart](https://tart.run) VMs take up on disk and moving the ones you aren't using to another drive.

```
./scripts/build.sh
open build/Berth.app
```

Requires macOS 26 and tart installed with Homebrew.

The window lists every VM in tart's storage (`$TART_HOME/vms`, default `~/.tart/vms`) and in your stash folder, with its state, CPUs, memory, and how much of its virtual disk is actually on disk. Last used is when the VM last wrote to its disk. Free space for both drives is in the bar at the bottom.

From the toolbar or the right-click menu you can start and stop a VM, change its CPUs and memory (double-click works too), move it between tart and the stash, reveal it in Finder, or move it to the Trash. Running VMs can't be edited, moved, or trashed.

## Snapshots

The sidebar lists snapshots of the selected VM. A snapshot is an APFS clone of the VM's folder, stored in `$TART_HOME/berth/snapshots`. Taking one is instant and uses no space at first. It grows only as the VM and the snapshot drift apart, and the sidebar shows that size. Reverting swaps the clone into place in a single rename and saves the state you're leaving as a new snapshot, so you can undo a revert. The VM has to be stopped for both.

A VM with snapshots can't move to the stash: the snapshots share its blocks and would keep holding that space here. Delete them first.

## Moving

Moving within one volume is a rename. Across volumes, Berth copies only the parts of the disk image that hold data, so an 80 GB image with 20 GB written takes 20 GB on the stash drive if that drive is formatted APFS. exFAT has no sparse files and stores the full 80 GB. The copy lands in a hidden `.partial` folder and replaces the original only once it finishes, so cancelling or quitting mid-move leaves the source as it was.

Disk usage counts each VM's blocks on its own. VMs made with `tart clone` share blocks on APFS, so the total can be more than they really take.
