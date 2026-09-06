#!/usr/bin/env python3
"""Resolve ROM files inside a MERGED MAME romset zip, without guessing.

The local `roms/` collection is merged: a parent's zip holds its own ROMs at
the root and each clone's *differing* ROMs in a subdirectory named after the
clone.

    roms/thunderl.zip
        m4                      <- thunderl (parent), root
        m5
        t14 t15 t16 t17         <- shared with every clone
        thunderla/tl-1-1.u1     <- thunderla's own program ROMs
        thunderla/tl-1-2.u4
        thunderlbl/19.f11       <- a set that is out of scope here

WHY THIS IS NOT A ONE-LINE BASENAME LOOKUP
------------------------------------------
The obvious `{n.split('/')[-1]: n for n in namelist()}` maps basename to path
and works most of the time -- which is what makes it dangerous. Two of the
thirty zips here contain COLLIDING basenames:

    daioh.zip     12 collisions, daiohp/<x> vs daiohp2/<x>
    jjsquawk.zip   1 collision,  jjsquawkb/4.bin vs simpsonjr/4.bin

Those are different dumps under the same name. A dict comprehension keeps
whichever came last in the archive, so asking for daiohp's `data_even.u103`
can silently hand back daiohp2's -- a wrong image that decodes, boots in
simulation, and is wrong. LESSONS_LEARNED's "A hardware-vs-image comparison
cannot detect a wrong image" is the same failure one step downstream.

AND WHY PATHS ARE NOT THE ANSWER EITHER
---------------------------------------
A merged set stores each unique ROM ONCE, wherever it was first seen, and MAME
finds it BY HASH. zombraidpj shares three of its four program ROMs with
zombraidp, so they are stored under `zombraidp/` and nothing appears under
`zombraidpj/` for them -- a path rule that only looks at "its own directory,
then the root" declares them missing, which is wrong in the other direction.

THE RULE
--------
Resolve by CRC32 when the caller knows it, which is the only unambiguous key:

  1. by CRC   scan the archive's central directory (no decompression needed)
              and take the entry whose CRC matches the driver's ROM_START.
              This is both the lookup AND an integrity check -- it cannot
              return a differently-named dump, a bad dump, or a sibling
              clone's file of the same name.
  2. by path  only when no CRC is available: "S/N", then "N" at the root,
              then refuse. Guessing across other sets' directories is how the
              collision above bites.
"""
import zipfile


class RomSet:
    def __init__(self, zippath, setname=None):
        """setname: the MAME set being assembled. Defaults to the zip's stem,
        i.e. the parent -- which is correct for a parent and wrong for a clone,
        so pass it explicitly for clones."""
        self.path = str(zippath)
        self.zip = zipfile.ZipFile(zippath)
        self.set = setname or str(zippath).replace("\\", "/").split("/")[-1][:-4]
        self._entries = self.zip.namelist()
        self._root = {n for n in self._entries if "/" not in n}
        self._own = {n.split("/", 1)[1]: n
                     for n in self._entries
                     if n.startswith(self.set + "/")}
        # CRC32 -> [paths]. zipfile reads this from the central directory, so
        # it costs nothing and needs no decompression.
        self._by_crc = {}
        for info in self.zip.infolist():
            self._by_crc.setdefault(info.CRC, []).append(info.filename)

    def sets(self):
        """Every set this archive can assemble: the parent plus its clones."""
        clones = sorted({n.split("/")[0] for n in self._entries if "/" in n})
        stem = str(self.path).replace("\\", "/").split("/")[-1][:-4]
        return [stem] + clones

    def resolve(self, name, crc=None):
        """crc: the CRC32 from the driver's ROM_START, when known."""
        if crc is not None:
            hits = self._by_crc.get(crc)
            if hits:
                # Prefer this set's own copy if the same data appears twice,
                # purely so messages name the expected path.
                own = [h for h in hits if h.startswith(self.set + "/")]
                root = [h for h in hits if "/" not in h]
                return (own or root or hits)[0]
            raise KeyError(
                f"no ROM with CRC {crc:#010x} ({name!r}) in {self.path} for set "
                f"{self.set!r}. The archive does not contain this dump -- the "
                f"set is incomplete here, or the CRC came from a different "
                f"driver revision.")
        if name in self._own:
            return self._own[name]
        if name in self._root:
            return name
        elsewhere = [n for n in self._entries if n.split("/")[-1] == name]
        if elsewhere:
            raise KeyError(
                f"{name!r} is not part of set {self.set!r} in {self.path}: it "
                f"exists only as {elsewhere}. Using another set's file of the "
                f"same name would be a silently wrong image -- check the set "
                f"name, or the ROM_START you transcribed.")
        raise KeyError(
            f"{name!r} not found in {self.path} for set {self.set!r}. "
            f"Sets in this archive: {', '.join(self.sets())}")

    def read(self, name, crc=None):
        return self.zip.read(self.resolve(name, crc))

    def has(self, name, crc=None):
        try:
            self.resolve(name, crc)
            return True
        except KeyError:
            return False


def selftest(roms_dir="roms"):
    """Report every archive's sets, and any basename collisions in it."""
    import collections
    import pathlib
    for z in sorted(pathlib.Path(roms_dir).glob("*.zip")):
        rs = RomSet(z)
        by_base = collections.defaultdict(list)
        for n in rs._entries:
            by_base[n.split("/")[-1]].append(n)
        dups = {b: v for b, v in by_base.items() if len(v) > 1}
        flag = f"  {len(dups)} colliding basename(s)" if dups else ""
        print(f"{z.stem:12s} sets: {', '.join(rs.sets())}{flag}")


if __name__ == "__main__":
    selftest()
