# bootstrap-stub

Public stub for the Viandier bootstrap.

## Usage

```bash
export INFISICAL_CLIENT_ID=...
export INFISICAL_CLIENT_SECRET=...
curl -fsSL https://viandier.com/bootstrap | sudo -E bash -s -- --profile server
```

Profile is one of `server` or `desktop`. Omit `--profile` to auto-detect.

## Forking this repo

The script is non-functional without valid credentials in our environment. Forks will not work.