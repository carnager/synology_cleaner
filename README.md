Synology NAS systems have remote backup Apps that work with remote rsync servers. 
In default configuration all @eaDir folders which Synology adds to practically every directory are synced too, which can be annoying.

If your remote server has a limited Shell available (e.g. Hetzner Storagebox) there is no simple and fast way to delete those directories.
The Shell does not have a find command and even if it had the speed is so limited that it can take hours to just list all files.

This script gets a full file list of a directory on your SSH server, filters for @eaDir directories and deletes files over ssh in batches.

## Features
- ssh host selection via ~/.ssh/config
- automatic cleanup of directory list to make the script resumable
- speed

## How it works
1. The script asks for the ssh server
2. The script asks for the remote folder to scan
3. A list of all files is fetched via rsync
4. Filtering the list for @eaDir directories
5. Creating a batch of directories to delete
6. Delete the batch via rm over ssh
7. Remove the batch from the list
