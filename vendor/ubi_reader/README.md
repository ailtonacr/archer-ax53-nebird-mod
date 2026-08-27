# vendor/ubi_reader

Pinned, in-repo copy of [ubi_reader](https://github.com/onekey-sec/ubi_reader)
(PyPI: `ubi-reader`), used by `01-unpack.sh` and `src/extract_xz_patch.py` to
extract UBI/UBIFS images. Vendored the same way `vendor/mtd-utils/` pins the
mtd-utils source: keep the exact upstream release tarball, extract it here,
and point our scripts at that copy instead of whatever happens to be
`pip install`ed on the machine.
