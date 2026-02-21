import QtQuick
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "system-reboot"
            active: parent.containsMouse
        }
    }

    fullRepresentation: FullRepresentation {
        expanded: root.expanded
    }

    preferredRepresentation: compactRepresentation

    toolTipMainText: i18n("Next Boot")
    toolTipSubText: i18n("Select next boot entry and reboot")
}
