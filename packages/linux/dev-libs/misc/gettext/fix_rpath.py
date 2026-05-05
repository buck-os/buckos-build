"""Fix gettext-tools RPATH: NUL-out corrupted RPATH entries.

make expands $O in $ORIGIN (treating it as a make variable),
corrupting RPATH to RIGIN/../lib.  Restoring $ORIGIN would require
inserting 2 extra bytes, which corrupts the ELF structure.

Instead, NUL-out the broken string in-place so the dynamic linker
falls back to LD_LIBRARY_PATH (provided by build_helper's
derive_lib_paths for all path-prepend host tools).
"""
import glob
import os

BROKEN = b"RIGIN/../lib"

for path in glob.glob("usr/bin/*"):
    if not os.path.isfile(path):
        continue
    with open(path, "rb") as f:
        data = bytearray(f.read())
    if data[:4] != b"\x7fELF":
        continue
    idx = data.find(BROKEN)
    if idx < 0:
        continue
    # NUL-out the corrupted RPATH in-place (same length, no ELF shift)
    for i in range(idx, idx + len(BROKEN)):
        data[i] = 0
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, 0o755)
