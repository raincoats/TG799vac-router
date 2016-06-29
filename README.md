# Technicolor TG799vac router filesystem (Telstra T-Gateway, version Coral 15.1)

Hello, this is the `/` from a Telstra T-Gateway router. It's as close as I could get to a full copy, there's no `proc`, `sys`, `dev` etc, as I ripped it out through samba.

Sharing this in case someone else wants to root it. I haven't yet, hopefully will soon. I can tell you, it's no Netgear, this thing seems fairly alright for a router, security wise.

### How did you do it?

Followed a symlink!

Okay, here's a step by step:

1. Get a USB flash drive. Format that bad boy as ext4.

2. On the USB, make a symlink to root (`ln -s root /`).

3. Plug the USB into the router. Make sure filesharing is enabled.

4. Here comes the tricky part. 

    - On Windows, you should be able to go to `\\10.0.0.138\usbdisk` just in explorer, and then click through to the symlink we made on step 2.
    - On Linux, I seem to remember you had to mount it like `mount.cifs -o nounix //10.0.0.138/usbdisk /mnt/evil`, then you could access the fs root through `/mnt/evil/name_of_usb/root/`. If you mount it without the `-o nounix`, the symlink will actually point at your computer's root.

5. Copy it over with copy and paste (windows), or on Linux, you can do it the leet way like `rsync -Pa /mnt/evil/name_of_usb/root ~/wherever/you/like/`. (I no longer have access to the vuln router, so I can't test these for you)

###  Can I do this myself?

Well, is your router up to date? If so... then no. The vuln works on 15.1 Coral (which the router came with), but I've since updated to 15.3 Turquoise, and it doesn't seem to work anymore. Looks like they've fixed the samba permissions.

### Did you change anything?

Sure did.

 - My pppoe username/pass have been changed to "pppoe-username" and "pppoe-password"
 - The router's ethernet mac is now `de:ad:06:66:00:00`.
 - The router's wifi mac is now `de-ad-06-66-00-01`.
 - The router's serial number is now `1234ABCDE` (the real serial has the same number of numbers and letters).

### Any pro tips or other info?

 - All those `.lp` files in `/www`? Lua Pages. (I didn't know that, at least)
 - There's a few directories missing, like `/rom` (which did not feel like copying over), `/proc` etc.
 - Also a few files I couldn't read, like `/etc/shadow`, that sort of thing. Plus a bunch of files in `/custo` IIRC.
 - I think `/var` was a symlink to `/tmp`, or the other way around.
 - Samba and nginx both run as `nobody`. (hmmm)
 - All the files/folders are `uid=0 gid=0` and completely unwritable, except for a few that were `uid=65534 gid=65534` (nobody): `/var/run/assistance` and contents; and `/var/lib/nginx/body`.
 - `/tmp` was writable, and folders made there seem to persist across reboots.
 - I also posess a random coredump from something called `minitr064d`, too lazy to edit the sensitive info out right now, but contact me if you'd like it.
 - This device had never been online when I did this. It was 10.0.1.138/24, not 10.0.0.138.


