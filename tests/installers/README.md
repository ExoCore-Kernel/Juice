# Installer smoke tests

JuiceMSISmoke.msi is assembled from the checked-in IDT tables with Wine's
own ARM64 msidb.exe. It copies the preinstalled WineMine payload into the
persistent per-user install directory, registers it with JuiceGUI, launches
from the JuiceGUI application list, and removes both the file and catalog
entries during uninstall.

JuiceSetupSmoke.exe is a conventional ARM64 setup executable. It copies
itself to LocalAppData, registers with JuiceGUI, launches the installed copy,
and records deterministic install, launch, and uninstall markers in
/var/mobile/Documents.

Build both after Grape is assembled:

    scripts/build-installer-smokes-device.sh

The build writes artifacts and SHA-256 evidence under
build/tests/installers.
