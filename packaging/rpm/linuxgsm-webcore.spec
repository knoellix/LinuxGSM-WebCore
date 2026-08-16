Name:           linuxgsm-webcore
Version:        0.2.2
Release:        1%{?dist}
Summary:        LinuxGSM Game Server Manager for Webmin

License:        MIT
URL:            https://github.com/knoellix/LinuxGSM-WebCore
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       webmin
Requires:       perl
Requires:       bash
Requires:       curl

%description
A Webmin plugin for managing game servers using LinuxGSM.
Provides a web-based interface for provisioning, monitoring,
and managing game server instances with strict user isolation
and security (no-root, no-shell, SFTP-only access).

%prep
%autosetup

%install
mkdir -p %{buildroot}/usr/share/webmin/linuxgsm-webcore
cp -r src/* %{buildroot}/usr/share/webmin/linuxgsm-webcore/

%post
if [ -f /var/webmin/miniserv.pid ] && kill -0 "$(cat /var/webmin/miniserv.pid)" 2>/dev/null; then
    /etc/webmin/restart 2>/dev/null || true
fi

%preun
# Remove SFTP config blocks added by the module on uninstall
# (handled by the module's own cleanup routine)
:

%files
%dir /usr/share/webmin/linuxgsm-webcore/
/usr/share/webmin/linuxgsm-webcore/*

%changelog
* Sun Aug 16 2026 Christian Möllmann <moellix@knoellix.net> - 0.2.2-1
- Mods page monitor status, last auto-restart, jobs table, enable/disable

* Sun Aug 16 2026 Christian Möllmann <moellix@knoellix.net> - 0.2.1-1
- Fix mods start logging, mod SHA1 parse, live-log picker and back button

* Sat Aug 15 2026 Christian Möllmann <moellix@knoellix.net> - 0.2.0-1
- Dedicated mods page (list, enable/disable, version picker, modpack UI)

* Tue Apr 08 2026 Christian Möllmann <moellix@knoellix.net> - 0.1.0-1
- Initial package
