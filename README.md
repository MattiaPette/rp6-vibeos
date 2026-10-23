# rp6-vibeos

Sistema minimale per il Retroid Pocket 6 (QCS8550, 8 GB) il cui unico scopo è far girare
[DroidDeck](https://github.com/Droid-Deck/DroidDeck) lasciando a giochi e GPU più RAM e spazio possibile.

Architettura: kernel mainline 7.3 di Retroid → host Debian minimale → Waydroid (Android in
container, solo DroidDeck installato) mostrato a tutto schermo da `cage`. Steam, Proton, FEX,
DXVK e i loro aggiornamenti restano gestiti da DroidDeck.

> Stato: prototipo, mai avviato su hardware. La GPU dentro DroidDeck richiede ancora lavoro:
> DroidDeck cerca il driver Android KGSL (`/dev/kgsl-3d0`), che il kernel mainline non ha.

## Build

Su un host Linux x86_64 o arm64 con `gcc-aarch64-linux-gnu`, `bc`, `flex`, `bison`,
`libssl-dev`, `device-tree-compiler`, `m4`, `alsa-utils` (`alsatplg`), `mkbootimg`,
`debootstrap`, `qemu-user-static`, `zstd`:

```sh
scripts/01-fetch-sources.sh            # kernel, topology, UCM, linux-firmware (solo i file utili)
scripts/10-build-kernel.sh             # config RP6 + driver ricavati dal device tree
scripts/20-build-audio.sh              # topology AudioReach + UCM
scripts/30-collect-firmware.sh <dump>  # firmware generici + blob firmati dall'Android stock
sudo scripts/40-build-rootfs.sh        # Debian minbase + Waydroid + cage
scripts/50-make-bootimg.sh             # boot.img per l'ABL
```

Alcuni pacchetti `mkbootimg` di Debian/Ubuntu non includono il modulo Python `gki`, che
serve solo per firmare immagini GKI: se lo script fallisce con `No module named 'gki'`,
usa `mkbootimg` da AOSP (`system/tools/mkbootimg`).

Le impostazioni comuni sono in `config.env`, il frammento del kernel in `kernel/rp6.config`.
`scripts/dt2config.py` legge il DTB dell'RP6 e abilita i driver di ogni nodo attivo, così il
config non va scritto a mano.

## Firmware firmati

GPU zap shader, ADSP e CDSP sono firmati per il device e si trovano solo nell'Android stock.
Prima di toccare il device copia le partizioni e le cartelle firmware, ad esempio:

```sh
adb pull /vendor/firmware      dump/vendor-firmware
adb pull /vendor/firmware_mnt  dump/firmware_mnt
adb pull /vendor/dsp           dump/dsp
```

Se ci sono solo file `.mdt` + `.bNN` serve [pil-squasher](https://github.com/linux-msm/pil-squasher).

## Primo avvio (senza toccare Android)

1. Sblocca il bootloader e fai il backup di tutte le partizioni.
2. Scrivi il rootfs nella prima partizione ext4 della microSD (`root=/dev/mmcblk0p1`).
3. `fastboot boot out/boot.img`: avvia una volta dalla RAM e non scrive niente sul device.
