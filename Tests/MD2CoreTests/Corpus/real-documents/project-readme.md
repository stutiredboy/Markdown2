# Waypost

Waypost moves newline-delimited event files from a local spool to an ingestion
endpoint. It keeps the spool on disk and records a checkpoint only after the
endpoint acknowledges a batch. Use `waypost status` to see the next file and
byte offset without opening the spool yourself.

## Install a portable copy

On a host without a package manager, extract the archive into a writable
directory and add its `bin` directory to `PATH`. The
[portable Windows guide](https://waypost.example.test/guide/windows_(portable).md)
shows where to put the executable and how to add it to `PATH` for one shell.

Save the following snippet as `bootstrap.sh` and run it from the extracted
directory. The dry run reads the sample without updating its checkpoint.

~~~sh filename=bootstrap.sh
#!/bin/sh
set -eu
# Keep a separate spool for dry runs
mkdir -p ./scratch-spool
cp ./examples/events.jsonl ./scratch-spool/events.jsonl
waypost send --dry-run --spool ./scratch-spool
~~~

## Configure an endpoint

Keep the credentials in the service environment. The configuration file can be
checked into the infrastructure repository because it contains only the spool
directory, batch size, and endpoint address.

```toml
spool = "/var/lib/waypost/events"
batch_size = 200
endpoint = "https://ingest.example.test/v1/events"
```

Before you enable the service, confirm that the service account can read the
spool and write checkpoints. A dry run that reads the sample under your own
account does not verify those permissions.

## Roll out the service

On a staged rollout, the first nine steps belong to the infrastructure team.
Resume the deployment checklist at the first operator step:

10. Restart the worker.
    - Verify the health check before processing the backlog.
11. Re-enable traffic.

When the queue is empty, record the checkpoint value and attach it to the
deployment ticket. When a rotation has stalled, follow the
[spool recovery procedure](technical-note.md) before restarting the worker.
