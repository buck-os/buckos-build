#!/usr/bin/env python3
"""Generate /etc/{passwd,group,shadow,gshadow} entries for system accounts.

Replaces the inline bash in acct.bzl.
"""

import argparse
import os
import sys

from _env import sanitize_global_env


def main():
    parser = argparse.ArgumentParser(description="Generate system account entries")
    parser.add_argument("--mode", required=True, choices=["group", "user"])
    parser.add_argument("--name", required=True)
    parser.add_argument("--id", required=True, type=int, dest="acct_id")
    parser.add_argument("--output-dir", required=True)
    # User-specific fields
    parser.add_argument("--home", default="/nonexistent")
    parser.add_argument("--shell", default="/usr/sbin/nologin")
    parser.add_argument("--description", default="")
    args = parser.parse_args()

    sanitize_global_env()

    output = os.path.abspath(args.output_dir)
    etc = os.path.join(output, "etc")
    os.makedirs(etc, exist_ok=True)

    if args.mode == "group":
        # group(5): group_name:password:GID:user_list
        group_line = f"{args.name}:x:{args.acct_id}:"
        # gshadow(5): group_name:encrypted_password:admins:members
        gshadow_line = f"{args.name}:!::"

        with open(os.path.join(etc, "group"), "a") as f:
            f.write(group_line + "\n")
        with open(os.path.join(etc, "gshadow"), "a") as f:
            f.write(gshadow_line + "\n")
    else:
        # passwd(5): username:password:UID:GID:GECOS:home_dir:shell
        passwd_line = f"{args.name}:x:{args.acct_id}:{args.acct_id}:{args.description}:{args.home}:{args.shell}"
        # shadow(5): username:encrypted_password:last_changed:min:max:warn:inactive:expire:reserved
        shadow_line = f"{args.name}:!:0:0:99999:7:::"

        with open(os.path.join(etc, "passwd"), "a") as f:
            f.write(passwd_line + "\n")
        shadow_path = os.path.join(etc, "shadow")
        with open(shadow_path, "a") as f:
            f.write(shadow_line + "\n")
        os.chmod(shadow_path, 0o640)


if __name__ == "__main__":
    main()
