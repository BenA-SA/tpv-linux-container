FROM fedora:43

RUN dnf install -y --setopt=install_weak_deps=False \
      qt5-qtbase qt5-qtbase-gui qt5-qtconnectivity qt5-qtlocation \
      qt5-qtmultimedia qt5-qtdeclarative qt5-qtquickcontrols2 \
      qt5-qtcharts qt5-qtnetworkauth qt5-qtsvg qt5-qtspeech \
      qt5-qtwebsockets qt5-qtsensors \
      dbus-tools avahi-tools iproute bluez \
 && dnf clean all && rm -rf /var/cache/dnf

COPY qdomyos-zwift /opt/qz/qdomyos-zwift
RUN chmod +x /opt/qz/qdomyos-zwift

WORKDIR /opt/qz
ENTRYPOINT ["/opt/qz/qdomyos-zwift"]
CMD ["-no-gui", "-no-virtual-device-bluetooth"]
