All patches imported from TP-Link AX53 GPL source (`GPL_AX53V1/QCASPF11_4/ilq-11-4_cs_qca/tools/`):

### Build Dependencies (Ubuntu 14.04)
It's suggested to use distrobox and spin up ubuntu-14
```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    linux-headers-generic \
    libacl1-dev \
    liblzo2-dev \
    uuid-dev \
    zlib1g-dev \
    liblzma-dev \
    libselinux1-dev
```
### To build, run this from root directory.
make tools
