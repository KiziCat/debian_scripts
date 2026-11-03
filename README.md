Vibcoded debian scripts

debinst.sh - Custom installer script to be ran from debian live CD, it will Install debian on Btrfs partition with Limine as bootloader, 
Niri with Noctalia shell as DE plus few additions programs. 
(i did not test yest custom kernel based on CachyOS patches)


mkredeploy.sh - script to make deployment easier on new pc, it scans the system (Debian) for all installed applications
and creates a script that Will reinstall all of them on new OS (Script was not tested yet)

deletetall.sh - simple script that can be run on any distro with bash it will scan all images in a folder and delete all that are taller then wider.
