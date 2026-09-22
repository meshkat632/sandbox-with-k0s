#!/usr/bin/env python3
"""Bootstrap a k0s node for a multi-node cluster.

First node (controller) — do NOT use `k0s install controller --single`,
single-node mode can never join other nodes:

    sudo python3 install_k0s.py --role controller

Then create a worker join token ON THE CONTROLLER:

    sudo k0s token create --role worker

Every additional node (worker):

    sudo python3 install_k0s.py --role worker --controller-ip <CTRL_IP> --token <TOKEN>

If node-1 was previously installed with --single, wipe it first:

    sudo k0s reset
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import time

K0S_INSTALL_URL = "https://get.k0s.sh"
K0S_BIN = shutil.which("k0s") or "/usr/local/bin/k0s"


def run(cmd):
    print(f"+ {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, check=True)


def install_binary():
    if os.path.exists(K0S_BIN):
        print(f"k0s already present at {K0S_BIN}")
        return
    print("installing k0s...")
    subprocess.run(f"curl -sSfL {K0S_INSTALL_URL} | sh", shell=True, check=True)


def check_reachable(host, port, timeout=5):
    print(f"checking connectivity to {host}:{port}...")
    with socket.create_connection((host, port), timeout=timeout):
        pass


def wait_until_running(deadline_s=180):
    print("waiting for k0s to come up...", flush=True)
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        try:
            subprocess.run([K0S_BIN, "status"], check=True, capture_output=True)
            print("k0s is running")
            return
        except subprocess.CalledProcessError:
            time.sleep(5)
    sys.exit(f"k0s did not start within {deadline_s}s — check `journalctl -u k0scontroller` / `-u k0sworker`")


def install_controller():
    run([K0S_BIN, "install", "controller"])


def install_worker(controller_ip, token):
    if controller_ip:
        check_reachable(controller_ip, 6443)
    token_file = "/etc/k0s/join-token"
    os.makedirs(os.path.dirname(token_file), exist_ok=True)
    with open(token_file, "w") as f:
        f.write(token)
    os.chmod(token_file, 0o600)
    run([K0S_BIN, "install", "worker", f"--token-file={token_file}"])


def main():
    if os.geteuid() != 0:
        sys.exit("run as root: sudo python3 install_k0s.py ...")

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--role", choices=["controller", "worker"], required=True)
    parser.add_argument("--token", help="worker join token from `k0s token create --role worker`")
    parser.add_argument("--controller-ip", help="controller private IP, for a pre-join connectivity check")
    args = parser.parse_args()

    install_binary()

    if args.role == "controller":
        install_controller()
    else:
        if not args.token:
            parser.error("--role worker requires --token")
        install_worker(args.controller_ip, args.token)

    run([K0S_BIN, "start"])
    wait_until_running()

    if args.role == "controller":
        print("\ncontroller up. Create a worker token with:")
        print("    sudo k0s token create --role worker")
    else:
        os.remove("/etc/k0s/join-token")
        print("\nworker joined.")


if __name__ == "__main__":
    main()
