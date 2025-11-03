# ProxMox cloud-init template Generator

Helper scripts for building reusable Proxmox cloud-init templates from upstream cloud images. The tooling keeps local cloud images up to date, assembles a merged cloud-init snippet (including user accounts), and drives `qm` to create or refresh templates with consistent settings.

## Credits
- Forum Post that started it all: https://forum.proxmox.com/threads/combining-custom-cloud-init-with-auto-generated.59008/page-3#post-428772
- Repo that inspired me: https://github.com/UntouchedWagons/Ubuntu-CloudInit-Docs
- Because Vibe Coding is all the rage, I used OpenAI's Codex to generate most of the code.

## What This Project Does

- Downloads the latest cloud images defined in `conf/cloud-init.conf`, verifying them against published checksums (`sync-cloud-images.py`).
- Generates cloud-init snippets composed from a base snippet, per-template fragments, and `conf/users-config.yaml`.
- Creates or refreshes Proxmox templates by destroying any existing VM with the configured ID, importing the image, resizing disks, applying tags, and wiring cloud-init (`cloud-init-create.sh`).

## Prerequisites

- Proxmox host with the `qm` CLI available.
- `bash`, `find`, `tee`, `curl`, `gpg`, and other common GNU utilities (the scripts run on the Proxmox node itself).
- Python 3.9+ (standard library only; see `requirements.txt`).
- Network access for downloading cloud images and GPG keys.
- `/var/lib/vz/snippets` writable (or set `SNIPPET_DIR` to an alternate path).
- The base Proxmox server dosn't come with git, python, python-venv or pip, you need to install all for this script to work.
```bash
apt update && apt install git python-is-python3 pip python3.13-venv -y
```
## Getting Started (a.k.a. “Just Make It Work”)

1. **Do the boring stuff first**: Prereqs are non-optional. Install all the crap Proxmox doesn't ship: `git`, `python`, `pip`, `venv`, etc. (yes, you need Python 3.9+).
2. **Clone this repo**: Because copy-pasting raw scripts from the internet into root shells is a vibe, but version control is smarter.
3. **Edit `users-config.yaml`**: Replace `PETERT_SSH_KEY`, `ANSIBLE_SSH_KEY`, or whatever random junk I left in there. Keep the format. Lose the noise.
4. **Copy `users.env.sample`**: `cp conf/users.env.sample conf/users.env`
5. **Match your env vars**: Edit `conf/users.env` to sync with `users-config.yaml`. If they don’t line up, nothing will work and you’ll deserve it.
6. **Passwords**: Use SSH keys like a real human. If you *must* use passwords, run `openssl passwd -6` to get a hash. Paste the hash. Not the password. Seriously.
7. **You’re on your Proxmox host, right?** If not, stop. Reassess your life.
8. **Download the images**: `./sync-cloud-images.py` grabs everything in `cloud-init.conf`. Don’t like my distro picks? Edit the file. Don’t whine.
9. **Dry run it**: `--dry-run` shows exactly what will happen. No surprises. No excuses.
10. **Test output**: `--test-output` dumps generated files to `test-output/`. Nervous? Copy-paste the lines from `proxmox-commands.txt` manually. Control freaks welcome.
11. **Run the damn script**: That’s why this exists. Start with:

    ```bash
    ./cloud-init-create.sh --list
    ```

    Then hit it with:

    ```bash
    ./cloud-init-create.sh --distro debian-12
    ```

    Sit back. Watch the magic.


## Repository Layout

- `cloud-init-create.sh` – main entry point for generating a template for a given distro.
- `sync-cloud-images.py` – image synchronisation and checksum validation.
- `conf/` – configuration:
  - `cloud-init.conf` – list of distros/releases/artifacts to download.
  - `cloud-init-urls.conf` – shell variables shared by the scripts and snippets (Docker/NVIDIA URLs, reference link).
  - `users-config.yaml` – cloud-init `users` section merged into every snippet.
  - `debian-based-cloud-init.yaml` – base snippet common to Debian/Ubuntu templates.
  - `debian-based-ditros/` – per-template `.conf` files plus matching `.yaml` fragments appended to snippets.
- `images/` – cached images organised as `<distro>/<release>/<artifact>`.
- `test-output/` – populated when running in `--test-output` mode (holds the generated snippet and `proxmox-commands.txt`).

## Typical Workflow (After a 1-Year Break)

1. **Refresh the repo** – review configs in `conf/` for accuracy (URLs, VMIDs, tags, users). Update SSH keys in `users-config.yaml` if they rotated.
2. **Download or update images** – optional step because `cloud-init-create.sh` auto-runs it, but you can prefetch:
   ```bash
   ./sync-cloud-images.py            # all distros/releases
   ./sync-cloud-images.py --distro debian --release bookworm
   ```
3. **Inspect available templates**:
   ```bash
   ./cloud-init-create.sh --list
   ```
4. **Generate/refresh a template**:
   ```bash
   sudo ./cloud-init-create.sh --distro debian-12
   ```
   - The script destroys any existing VM with the configured `VMID`.
   - Images are sourced from `images/` (downloaded if missing or outdated).
   - Cloud-init snippet is written to `${SNIPPET_DIR}` (`/var/lib/vz/snippets` by default).
5. **Dry runs**:
   ```bash
   ./cloud-init-create.sh --distro debian-12 --dry-run
   ```
   Prints the `qm` commands without executing them.
6. **Test mode**:
   ```bash
   ./cloud-init-create.sh --distro debian-12 --test-output
   ```
   - Skips calling `qm`.
   - Writes command log and generated snippet into `test-output/` for inspection.

## Configuration Details

- **Per-template configs (`conf/debian-based-ditros/*.conf`)**
  - Provide `DISTRO` (identifier used with `--distro`), `VMID`, `STORAGE`, `LOCAL_IMAGE_FILE_NAME`, `IMAGE_RESIZE`, `TEMPLATE_NAME`, `SNIPPET_FILE`, and optional CPU/bridge/tags overrides.
  - `LOCAL_IMAGE_FILE_NAME` must match the directory structure created by the sync script (`<distro>/<release>/<filename>`).
  - CPU options are passed directly to `qm create` (`CPU`, `CPU_CORES`, `CPU_SOCKET`/`CPU_SOCKETS`, `CPU_NUM`/`CPU_NUMA`).
  - `BRIDGE` and `MTU` map to `--net0` settings.

- **Snippet fragments (`conf/debian-based-ditros/*.yaml`)**
  - Appended in lexical order to the base snippet.
  - Use for distro-specific package installs, service tweaks, and the required `reboot`.
  - For fragments that add `runcmd` entries, the script automatically merges them with the base list.

- **Base snippet (`conf/debian-based-cloud-init.yaml`)**
  - Installs `qemu-guest-agent`, `gnupg`, and `vim`.
  - Common best-place for standard packages applicable across Debian-based templates.

- **User accounts (`conf/users-config.yaml`)**
  - Injected verbatim into every generated snippet.
  - Update SSH keys, passwords, and sudo rules here before rebuilding templates.
  - Generate new password hashes with `openssl passwd -6 'plaintext-password'` (omit the argument to be prompted securely).

- **Shared URL constants (`conf/cloud-init-urls.conf`)**
  - Sourced by `cloud-init-create.sh`; referenced in some snippet fragments (Docker/NVIDIA repos, forum link comment).
  - Keep the URLs current to avoid 404s during provisioning.

- **Environment overrides**
  - `CONFIG_FILE` – alternate path to the URL/config variables file (defaults to `conf/cloud-init-urls.conf`).
  - `IMAGE_DIR` – directory holding synced images (default `images/` in the repo).
  - `SNIPPET_DIR` – where generated cloud-init snippets are written (Proxmox default `/var/lib/vz/snippets`).

## Adding or Updating Templates

1. Extend `conf/cloud-init.conf` with any new releases or artifacts to download.
2. Create a new distro config `.conf` under `conf/debian-based-ditros/` (match naming convention `<VMID>-<identifier>.conf`).
3. Optionally add a snippet fragment `.yaml` with package installs, service tweaks, and the mandatory `reboot`.
4. Run `./sync-cloud-images.py` to fetch the new artifact.
5. Generate the template with `./cloud-init-create.sh --distro <identifier>`.

## Troubleshooting Notes

- `cloud-init-create.sh` stops on errors (`set -euo pipefail`). If something fails mid-run, fix the issue and re-run; it handles clean-up by destroying the VM ID again.
- Check `test-output/proxmox-commands.txt` after a `--test-output` run to confirm the `qm` actions before executing them on a live node.
- If snippets fail to apply, ensure the target Proxmox node has access to the generated snippet path (`SNIPPET_DIR`) and that cloud-init is installed on the guest.
- `sync-cloud-images.py` will skip downloads when the upstream checksum file has not changed. Delete the corresponding `images/<distro>/<release>/remote-checksum` file to force a refresh.

## Quick Reminder for Future You

- Update `users-config.yaml` with current SSH keys and disable any stale accounts.
- Confirm that `VMID` values are still unused on the Proxmox cluster before running the script—destroying an existing VM is intentional.
- Validate that `local-zfs` (or whatever storage you expect) exists; adjust the config if storage names changed.
- Run `--test-output` first if you only want to review commands/snippets without touching Proxmox resources.
- Keep `conf/cloud-init-urls.conf` URLs fresh (Docker/NVIDIA keys tend to rotate).
