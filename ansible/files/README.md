# ansible/files — build artifacts (NOT committed)

The `kipfs` binary is **not** stored in git — it is a **build artifact**. Committing an
8 MB binary bloats the repo and is not reproducible.

## How to obtain the binary before running the Ansible playbook
Build it from source (`app-repo/kripfs`), or pull it from CI / a release:

```bash
# option A — build locally
cd ../../../kripfs        # app-repo/kripfs
cargo build --release --bin kipfs
cp target/release/kipfs   ../datark-onboarding/ansible/files/kipfs

# option B — download the CI artifact (kipfs-binary) from the kripfs pipeline
#   .github/workflows/kripfs-deploy-nhn.yml uploads it on every build.
```

The playbook expects the binary at `ansible/files/kipfs`. It is gitignored.
