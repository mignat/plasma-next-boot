import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support
import "utils.js" as Utils

ColumnLayout {
    id: root

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.preferredWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: popupHeight
    Layout.preferredHeight: popupHeight
    Layout.maximumHeight: popupHeight

    readonly property real popupHeight: {
        if (root.loading || root.usbLoading)
            return Kirigami.Units.gridUnit * 5

        if (root.confirming)
            return Kirigami.Units.gridUnit * 14

        if (root.errorText !== "")
            return Kirigami.Units.gridUnit * 8

        var items = bootEntriesModel.count + usbDevicesModel.count
        var headers = 0
        if (bootEntriesModel.count > 0) headers++ // Boot Options
        if (usbDevicesModel.count > 0) headers++ // USB Devices
        items += headers

        if (items === 0)
            return Kirigami.Units.gridUnit * 6

        return Math.min(bootEntriesModel.count * Kirigami.Units.gridUnit * 2.5
                        + usbDevicesModel.count * Kirigami.Units.gridUnit * 2.5
                        + headers * Kirigami.Units.gridUnit * 1.5
                        + Kirigami.Units.largeSpacing * 2,
                        Kirigami.Units.gridUnit * 30)
    }
    spacing: 0

    property string currentBootNum: ""
    property string nextBootNum: ""
    property string defaultBootNum: ""
    property var bootOrder: []
    property string selectedBootNum: ""
    property string selectedBootName: ""
    property bool loading: true
    property string errorText: ""
    property bool confirming: false
    property bool confirmingDefault: false

    property bool expanded: false
    property bool usbLoading: false
    property bool selectedIsUsb: false
    property var selectedUsbData: ({})
    property int refreshCounter: 0

    readonly property string scriptsDir: {
        var url = Qt.resolvedUrl(".").toString()
        if (url.startsWith("file://"))
            url = url.substring(7)
        // Remove trailing slash
        if (url.endsWith("/"))
            url = url.substring(0, url.length - 1)
        return url
    }

    ListModel {
        id: bootEntriesModel
    }

    ListModel {
        id: usbDevicesModel
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            var exitCode = data["exit code"]

            if (sourceName.indexOf("efibootmgr #") !== -1) {
                if (exitCode !== 0) {
                    root.errorText = i18n("Failed to read boot entries.\nEnsure efibootmgr is installed and EFI variables are accessible.")
                    root.loading = false
                } else {
                    parseBootEntries(stdout)
                    root.loading = false
                }
            } else if (sourceName.indexOf("efibootmgr -o") !== -1) {
                if (exitCode !== 0) {
                    root.errorText = i18n("Failed to set default boot entry.\nAuthentication may have been cancelled.")
                } else {
                    refresh()
                }
            } else if (sourceName.indexOf("efibootmgr -n") !== -1) {
                if (exitCode !== 0) {
                    root.errorText = i18n("Failed to set next boot entry.\nAuthentication may have been cancelled.")
                    root.confirming = false
                } else {
                    executable.connectSource("systemctl reboot")
                }
            } else if (sourceName.indexOf("nextboot-usb-scan.sh") !== -1) {
                if (exitCode === 0) {
                    parseUsbDevices(stdout)
                }
                root.usbLoading = false
            } else if (sourceName.indexOf("nextboot-usb-boot.sh") !== -1) {
                if (exitCode !== 0 || stdout.indexOf("OK:") === -1) {
                    root.errorText = i18n("Failed to create USB boot entry.\nAuthentication may have been cancelled.")
                    root.confirming = false
                } else {
                    executable.connectSource("systemctl reboot")
                }
            }

            disconnectSource(sourceName)
        }
    }

    function parseBootEntries(output) {
        bootEntriesModel.clear()
        root.currentBootNum = ""
        root.nextBootNum = ""
        root.defaultBootNum = ""
        root.bootOrder = []

        var lines = output.split("\n")
        var rawEntries = []
        var hasNonDuplicate = false

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()

            var currentMatch = line.match(/^BootCurrent:\s*([0-9A-Fa-f]+)/)
            if (currentMatch) {
                root.currentBootNum = currentMatch[1]
                continue
            }

            var nextMatch = line.match(/^BootNext:\s*([0-9A-Fa-f]+)/)
            if (nextMatch) {
                root.nextBootNum = nextMatch[1]
                continue
            }

            var orderMatch = line.match(/^BootOrder:\s*(.+)/)
            if (orderMatch) {
                root.bootOrder = orderMatch[1].split(",").map(function(s) { return s.trim() })
                if (root.bootOrder.length > 0)
                    root.defaultBootNum = root.bootOrder[0]
                continue
            }

            var entryMatch = line.match(/^Boot([0-9A-Fa-f]{4})(\*?)\s+(.+)/)
            if (entryMatch) {
                // Skip NB-USB: entries (temporary USB entries we created)
                if (entryMatch[3].indexOf("NB-USB:") !== -1)
                    continue

                var parsed = Utils.parseEntryName(entryMatch[3])
                var isDup = Utils.isUefiOsDuplicate(parsed.name)
                if (!isDup) hasNonDuplicate = true

                rawEntries.push({
                    bootNum: entryMatch[1],
                    active: entryMatch[2] === "*",
                    originalName: parsed.name,
                    isDuplicate: isDup
                })
            }
        }

        // Prune stale entries from config (disconnected USB, removed OS, etc.)
        var validNums = []
        for (var v = 0; v < rawEntries.length; v++)
            validNums.push(rawEntries[v].bootNum)

        var cleaned = Utils.cleanupConfig(
            validNums,
            Plasmoid.configuration.customOrder,
            Plasmoid.configuration.hiddenEntries,
            Plasmoid.configuration.customNames
        )
        if (cleaned.changed) {
            Plasmoid.configuration.customOrder = cleaned.customOrder
            Plasmoid.configuration.hiddenEntries = cleaned.hiddenEntries
            Plasmoid.configuration.customNames = cleaned.customNames
        }

        var customNames = Utils.parseCustomNames(cleaned.customNames)
        rawEntries = Utils.applyCustomOrder(rawEntries, cleaned.customOrder)

        var hideDups = Plasmoid.configuration.hideDuplicates
        var hiddenArr = (cleaned.hiddenEntries || "").split(",")
        var hiddenSet = {}
        for (var h = 0; h < hiddenArr.length; h++) {
            var hn = hiddenArr[h].trim()
            if (hn !== "") hiddenSet[hn] = true
        }

        var filtered = []
        for (var m = 0; m < rawEntries.length; m++) {
            var entry = rawEntries[m]

            if (hideDups && entry.isDuplicate && hasNonDuplicate)
                continue

            if (hiddenSet[entry.bootNum])
                continue

            filtered.push(entry)
        }

        // Move the currently booted entry to the back
        for (var c = 0; c < filtered.length; c++) {
            if (filtered[c].bootNum === root.currentBootNum && c < filtered.length - 1) {
                var current = filtered.splice(c, 1)[0]
                filtered.push(current)
                break
            }
        }

        for (var f = 0; f < filtered.length; f++) {
            var fe = filtered[f]
            bootEntriesModel.append({
                bootNum: fe.bootNum,
                active: fe.active,
                name: customNames[fe.bootNum] || fe.originalName,
                originalName: fe.originalName,
                isCurrent: fe.bootNum === root.currentBootNum,
                isNext: fe.bootNum === root.nextBootNum,
                isDefault: fe.bootNum === root.defaultBootNum,
                entryIcon: Utils.bootEntryIcon(fe.originalName)
            })
        }
    }

    function parseUsbDevices(output) {
        usbDevicesModel.clear()

        var parsed
        try {
            parsed = JSON.parse(output)
        } catch (e) {
            return
        }

        var devices = parsed.devices || []
        var usbBootNums = parsed.usbBootNums || []

        // Hide ALL USB-related boot entries (plugged in or stale)
        var bootNumsToHide = {}
        for (var u = 0; u < usbBootNums.length; u++)
            bootNumsToHide[usbBootNums[u]] = true

        for (var i = 0; i < devices.length; i++) {
            var dev = devices[i]
            var efiFiles = dev.efiFiles || []
            var existingBootNum = dev.existingBootNum || ""

            if (efiFiles.length === 1) {
                usbDevicesModel.append({
                    deviceName: dev.deviceName || "",
                    diskPath: dev.diskPath || "",
                    partPath: dev.partPath || "",
                    partNum: dev.partNum || 1,
                    label: dev.label || "",
                    efiPath: efiFiles[0].path || "",
                    efiName: efiFiles[0].name || "",
                    displayName: dev.deviceName || dev.label || "USB Device",
                    existingBootNum: existingBootNum
                })
            } else {
                for (var j = 0; j < efiFiles.length; j++) {
                    var eName = efiFiles[j].name || ""
                    // Skip non-x64 fallback loaders to reduce noise
                    if (eName === "BOOTIA32.EFI" || eName === "BOOTAA64.EFI")
                        continue

                    var suffix = ""
                    if (eName !== "BOOTX64.EFI")
                        suffix = " (" + eName.replace(/\.efi$/i, "") + ")"

                    usbDevicesModel.append({
                        deviceName: dev.deviceName || "",
                        diskPath: dev.diskPath || "",
                        partPath: dev.partPath || "",
                        partNum: dev.partNum || 1,
                        label: dev.label || "",
                        efiPath: efiFiles[j].path || "",
                        efiName: eName,
                        displayName: (dev.deviceName || dev.label || "USB Device") + suffix,
                        existingBootNum: existingBootNum
                    })
                }
            }
        }

        // Remove firmware boot entries that are covered by USB scan entries
        for (var k = bootEntriesModel.count - 1; k >= 0; k--) {
            if (bootNumsToHide[bootEntriesModel.get(k).bootNum])
                bootEntriesModel.remove(k)
        }
    }

    function setDefaultBoot(bootNum) {
        if (!/^[0-9A-Fa-f]{4}$/.test(bootNum)) return
        var newOrder = [bootNum]
        for (var i = 0; i < root.bootOrder.length; i++) {
            if (root.bootOrder[i] !== bootNum)
                newOrder.push(root.bootOrder[i])
        }
        executable.connectSource("pkexec efibootmgr -o " + newOrder.join(","))
    }

    function triggerSetDefault(bootNum, bootName) {
        root.selectedBootNum = bootNum
        root.selectedBootName = bootName

        if (Plasmoid.configuration.skipDefaultConfirmation) {
            setDefaultBoot(bootNum)
        } else {
            root.confirmingDefault = true
            root.confirming = true
        }
    }

    function setNextBootAndReboot(bootNum) {
        if (!/^[0-9A-Fa-f]{4}$/.test(bootNum)) {
            root.errorText = i18n("Invalid boot entry number.")
            return
        }
        root.errorText = ""
        executable.connectSource("pkexec efibootmgr -n " + bootNum)
    }

    function triggerBoot(bootNum, bootName) {
        root.selectedBootNum = bootNum
        root.selectedBootName = bootName
        root.selectedIsUsb = false

        if (Plasmoid.configuration.skipConfirmation) {
            setNextBootAndReboot(bootNum)
        } else {
            root.confirming = true
        }
    }

    function triggerUsbBoot(diskPath, partNum, efiPath, displayName, existingBootNum) {
        root.selectedBootName = displayName

        if (existingBootNum) {
            // Firmware already has a boot entry for this USB — just use it
            root.selectedBootNum = existingBootNum
            root.selectedIsUsb = false
        } else {
            // No firmware entry — will create a temporary one
            root.selectedBootNum = ""
            root.selectedIsUsb = true
            root.selectedUsbData = {
                diskPath: diskPath,
                partNum: partNum,
                efiPath: efiPath,
                label: displayName
            }
        }

        if (Plasmoid.configuration.skipConfirmation) {
            if (root.selectedIsUsb)
                executeUsbBoot()
            else
                setNextBootAndReboot(root.selectedBootNum)
        } else {
            root.confirming = true
        }
    }

    function executeUsbBoot() {
        root.errorText = ""
        var d = root.selectedUsbData
        if (!d.diskPath || !d.partNum || !d.efiPath) {
            root.errorText = i18n("Invalid USB device data.")
            return
        }
        var cmd = "pkexec bash " + root.scriptsDir + "/nextboot-usb-boot.sh"
            + " '" + d.diskPath.replace(/'/g, "") + "'"
            + " '" + String(d.partNum) + "'"
            + " '" + d.efiPath.replace(/'/g, "") + "'"
            + " '" + d.label.replace(/'/g, "") + "'"
        executable.connectSource(cmd)
    }

    function refresh() {
        root.loading = true
        root.usbLoading = true
        root.errorText = ""
        root.confirming = false
        root.confirmingDefault = false
        root.selectedIsUsb = false
        bootEntriesModel.clear()
        usbDevicesModel.clear()
        root.refreshCounter++
        executable.connectSource("efibootmgr #" + root.refreshCounter)
        executable.connectSource("bash " + root.scriptsDir + "/nextboot-usb-scan.sh #" + root.refreshCounter)
    }

    Component.onCompleted: refresh()

    onExpandedChanged: {
        if (expanded) refresh()
    }

    P5Support.DataSource {
        id: hotplugMonitor
        engine: "hotplug"

        onSourceAdded: {
            if (root.expanded && !root.confirming) hotplugDebounce.restart()
        }
        onSourceRemoved: {
            if (root.expanded && !root.confirming) hotplugDebounce.restart()
        }
    }

    Timer {
        id: hotplugDebounce
        interval: 500
        onTriggered: refresh()
    }

    // Loading
    PlasmaComponents.BusyIndicator {
        Layout.alignment: Qt.AlignCenter
        Layout.fillHeight: true
        visible: root.loading || root.usbLoading
        running: visible
    }

    // Error
    PlasmaExtras.PlaceholderMessage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !root.loading && !root.usbLoading && root.errorText !== "" && !root.confirming
        text: root.errorText
        iconName: "dialog-error"

        helpfulAction: Kirigami.Action {
            text: i18n("Retry")
            icon.name: "view-refresh"
            onTriggered: refresh()
        }
    }

    // Boot entries list
    ColumnLayout {
        Layout.fillWidth: true
        visible: !root.loading && !root.usbLoading && root.errorText === "" && !root.confirming
                 && (bootEntriesModel.count > 0 || usbDevicesModel.count > 0)
        spacing: 0

                // --- Boot Options header ---
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 1.5
                    visible: bootEntriesModel.count > 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: "drive-harddisk"
                            color: Kirigami.Theme.textColor
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            opacity: 0.7
                        }

                        PlasmaComponents.Label {
                            text: i18n("Boot Options")
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }

                        Kirigami.Separator {
                            Layout.fillWidth: true
                        }
                    }
                }

                // --- Boot entries ---
                Repeater {
                    model: bootEntriesModel

                    delegate: PlasmaComponents.ItemDelegate {
                        Layout.fillWidth: true

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Kirigami.Icon {
                                source: model.entryIcon
                                color: Kirigami.Theme.textColor

                                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: model.name
                                    elide: Text.ElideRight
                                    font.bold: model.isCurrent
                                }

                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: {
                                        var parts = ["Boot" + model.bootNum]
                                        if (model.isCurrent) parts.unshift(i18n("Current"))
                                        if (model.isNext) parts.unshift(i18n("Next"))
                                        if (!model.active) parts.push(i18n("Inactive"))
                                        return parts.join(" \u00b7 ")
                                    }
                                    elide: Text.ElideRight
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                }
                            }

                            Kirigami.Icon {
                                source: model.isDefault ? "favorite" : "non-starred"
                                color: Kirigami.Theme.textColor
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: model.isDefault ? 0.7 : 0.3

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: model.isDefault ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    enabled: !model.isDefault
                                    onClicked: triggerSetDefault(model.bootNum, model.name)
                                }

                                PlasmaComponents.ToolTip {
                                    text: model.isDefault ? i18n("Default boot entry") : i18n("Set as default boot entry")
                                }
                            }

                            Kirigami.Icon {
                                source: "system-reboot"
                                color: Kirigami.Theme.textColor

                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: 0.5
                            }
                        }

                        onClicked: triggerBoot(model.bootNum, model.name)
                    }
                }

                // --- USB section header ---
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 1.5
                    visible: usbDevicesModel.count > 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: "drive-removable-media-usb"
                            color: Kirigami.Theme.textColor
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            opacity: 0.7
                        }

                        PlasmaComponents.Label {
                            text: i18n("USB Devices")
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }

                        Kirigami.Separator {
                            Layout.fillWidth: true
                        }
                    }
                }

                // --- USB boot entries ---
                Repeater {
                    model: usbDevicesModel

                    delegate: PlasmaComponents.ItemDelegate {
                        Layout.fillWidth: true

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Kirigami.Icon {
                                source: "drive-removable-media-usb"
                                color: Kirigami.Theme.textColor
    
                                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: model.displayName
                                    elide: Text.ElideRight
                                }

                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: {
                                        var parts = []
                                        if (model.label)
                                            parts.push(model.label)
                                        parts.push(model.partPath)
                                        return parts.join(" \u00b7 ")
                                    }
                                    elide: Text.ElideRight
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                }
                            }

                            Kirigami.Icon {
                                source: "system-reboot"
                                color: Kirigami.Theme.textColor
    
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: 0.5
                            }
                        }

                        onClicked: triggerUsbBoot(model.diskPath, model.partNum,
                                                  model.efiPath, model.displayName,
                                                  model.existingBootNum)
                    }
                }
    }

    // Empty state
    PlasmaExtras.PlaceholderMessage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !root.loading && !root.usbLoading && root.errorText === "" && !root.confirming
                 && bootEntriesModel.count === 0 && usbDevicesModel.count === 0
        text: i18n("No boot entries found")
        iconName: "drive-harddisk"
    }

    // Confirmation view
    ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.margins: Kirigami.Units.largeSpacing
        visible: root.confirming
        spacing: Kirigami.Units.largeSpacing

        Item { Layout.fillHeight: true }

        Kirigami.Icon {
            Layout.alignment: Qt.AlignHCenter
            source: root.confirmingDefault ? "favorite"
                  : root.selectedIsUsb ? "drive-removable-media-usb"
                  : "system-reboot"
            color: Kirigami.Theme.textColor

            Layout.preferredWidth: Kirigami.Units.iconSizes.huge
            Layout.preferredHeight: Kirigami.Units.iconSizes.huge
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 16
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.confirmingDefault
                ? i18n("Set <b>%1</b> as default?", root.selectedBootName)
                : i18n("Reboot into <b>%1</b>?", root.selectedBootName)
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: root.confirmingDefault
                ? i18n("This will change the default boot order")
                : root.selectedIsUsb
                    ? i18n("A temporary boot entry will be created for this USB device")
                    : i18n("Boot%1 will be set as the next boot entry", root.selectedBootNum)
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Kirigami.Units.largeSpacing

            PlasmaComponents.Button {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onClicked: {
                    root.confirming = false
                    root.confirmingDefault = false
                }
            }

            PlasmaComponents.Button {
                text: root.confirmingDefault ? i18n("Set Default") : i18n("Reboot Now")
                icon.name: root.confirmingDefault ? "favorite" : "system-reboot"
                onClicked: {
                    if (root.confirmingDefault) {
                        setDefaultBoot(root.selectedBootNum)
                        root.confirming = false
                        root.confirmingDefault = false
                    } else if (root.selectedIsUsb) {
                        executeUsbBoot()
                    } else {
                        setNextBootAndReboot(root.selectedBootNum)
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
