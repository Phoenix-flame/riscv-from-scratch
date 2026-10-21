# Vendored Kconfiglib 14.1.0

`make menuconfig` (Step 45) uses [Kconfiglib](https://github.com/ulfalizer/Kconfiglib)
by Ulf Magnusson -- the pure-Python Kconfig implementation Zephyr uses. These
files are copied unmodified from the 14.1.0 release (ISC licence, `LICENSE.txt`)
so the menu works without a `pip install`. Only the pieces this project calls
are included: the library, the curses menu, and the defconfig / savedefconfig /
olddefconfig / genconfig front ends.
