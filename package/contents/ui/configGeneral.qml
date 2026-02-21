import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support
import "utils.js" as Utils

KCM.SimpleKCM {
    id: configPage

    property alias cfg_skipConfirmation: skipConfirmationCheckbox.checked
    property alias cfg_skipDefaultConfirmation: skipDefaultConfirmationCheckbox.checked
    property alias cfg_hideDuplicates: hideDuplicatesCheckbox.checked
    property string cfg_customNames
    property string cfg_customOrder
    property string cfg_hiddenEntries

    property var namesMap: ({})
    property var hiddenSet: ({})
    property bool entriesLoaded: false
    property string loadError: ""

    ListModel {
        id: entriesModel
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            if (sourceName === "efibootmgr -v") {
                var stdout = data["stdout"] || ""
                var exitCode = data["exit code"]
                if (exitCode !== 0) {
                    configPage.loadError = i18n("Failed to read boot entries. Ensure efibootmgr is installed.")
                } else {
                    populateModel(stdout)
                }
                configPage.entriesLoaded = true
            }
            disconnectSource(sourceName)
        }
    }

    Component.onCompleted: {
        namesMap = Utils.parseCustomNames(cfg_customNames)
        var hiddenArr = (cfg_hiddenEntries || "").split(",").filter(function(s) { return s.trim() !== "" })
        var hs = {}
        for (var i = 0; i < hiddenArr.length; i++)
            hs[hiddenArr[i].trim()] = true
        hiddenSet = hs
        executable.connectSource("efibootmgr -v")
    }

    function populateModel(output) {
        var lines = output.split("\n")
        var entries = []

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            var entryMatch = line.match(/^Boot([0-9A-Fa-f]{4})(\*?)\s+(.+)/)
            if (entryMatch) {
                var fullText = entryMatch[3]

                // Skip NB-USB: temporary entries
                if (fullText.indexOf("NB-USB:") !== -1)
                    continue

                // Skip entries with USB device paths (firmware-created USB entries)
                if (fullText.indexOf("USB(") !== -1 || fullText.indexOf("UsbClass(") !== -1)
                    continue

                var parsed = Utils.parseEntryName(fullText)
                entries.push({
                    bootNum: entryMatch[1],
                    originalName: parsed.name,
                    efiPath: parsed.efiPath,
                    customName: namesMap[entryMatch[1]] || "",
                    entryIcon: Utils.bootEntryIcon(parsed.name),
                    hidden: hiddenSet[entryMatch[1]] === true
                })
            }
        }

        // Prune stale entries from config (disconnected USB, removed OS, etc.)
        var validNums = []
        for (var k = 0; k < entries.length; k++)
            validNums.push(entries[k].bootNum)

        var cleaned = Utils.cleanupConfig(validNums, cfg_customOrder, cfg_hiddenEntries, cfg_customNames)
        if (cleaned.changed) {
            cfg_customOrder = cleaned.customOrder
            cfg_hiddenEntries = cleaned.hiddenEntries
            cfg_customNames = cleaned.customNames
            plasmoid.configuration.customOrder = cleaned.customOrder
            plasmoid.configuration.hiddenEntries = cleaned.hiddenEntries
            plasmoid.configuration.customNames = cleaned.customNames

            // Refresh namesMap and hiddenSet from cleaned data
            namesMap = Utils.parseCustomNames(cleaned.customNames)
            var cleanHiddenArr = (cleaned.hiddenEntries || "").split(",")
            var hs = {}
            for (var h = 0; h < cleanHiddenArr.length; h++) {
                var hnum = cleanHiddenArr[h].trim()
                if (hnum !== "") hs[hnum] = true
            }
            hiddenSet = hs

            // Re-apply cleaned names and hidden state to entries
            for (var r = 0; r < entries.length; r++) {
                entries[r].customName = namesMap[entries[r].bootNum] || ""
                entries[r].hidden = hiddenSet[entries[r].bootNum] === true
            }
        }

        entries = Utils.applyCustomOrder(entries, cleaned.changed ? cleaned.customOrder : cfg_customOrder)

        entriesModel.clear()
        for (var j = 0; j < entries.length; j++)
            entriesModel.append(entries[j])
    }

    function saveNames() {
        var names = {}
        for (var i = 0; i < entriesModel.count; i++) {
            var entry = entriesModel.get(i)
            if (entry.customName !== "")
                names[entry.bootNum] = entry.customName
        }
        namesMap = names
        var val = JSON.stringify(names)
        cfg_customNames = val
        plasmoid.configuration.customNames = val
    }

    function saveOrder() {
        var order = []
        for (var i = 0; i < entriesModel.count; i++)
            order.push(entriesModel.get(i).bootNum)
        var val = order.join(",")
        cfg_customOrder = val
        plasmoid.configuration.customOrder = val
    }

    function saveHidden() {
        var arr = []
        for (var i = 0; i < entriesModel.count; i++) {
            var entry = entriesModel.get(i)
            if (entry.hidden)
                arr.push(entry.bootNum)
        }
        var hs = {}
        for (var j = 0; j < arr.length; j++)
            hs[arr[j]] = true
        hiddenSet = hs
        var val = arr.join(",")
        cfg_hiddenEntries = val
        plasmoid.configuration.hiddenEntries = val
    }

    function moveEntry(fromIndex, toIndex) {
        if (toIndex < 0 || toIndex >= entriesModel.count) return
        entriesModel.move(fromIndex, toIndex, 1)
        saveOrder()
    }

    Kirigami.FormLayout {

        // --- Behavior section ---

        QQC2.CheckBox {
            id: skipConfirmationCheckbox
            Kirigami.FormData.label: i18n("Behavior:")
            text: i18n("Skip confirmation before rebooting")
        }

        QQC2.CheckBox {
            id: skipDefaultConfirmationCheckbox
            text: i18n("Skip confirmation when changing default boot entry")
        }

        QQC2.CheckBox {
            id: hideDuplicatesCheckbox
            text: i18n("Hide UEFI OS duplicate entries")
        }

        // --- Boot entries section ---

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Boot Entries")
        }

        QQC2.BusyIndicator {
            visible: !configPage.entriesLoaded
            running: visible
        }

        QQC2.Label {
            visible: configPage.loadError !== ""
            text: configPage.loadError
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
        }

        QQC2.Label {
            visible: configPage.entriesLoaded && configPage.loadError === "" && entriesModel.count > 0
            text: i18n("Reorder entries with the arrow buttons. Click a name to rename it.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: configPage.entriesLoaded && configPage.loadError === ""
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: entriesModel

                delegate: Kirigami.AbstractCard {
                    Layout.fillWidth: true
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 24
                    opacity: model.hidden ? 0.5 : 1.0

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        ColumnLayout {
                            spacing: 0

                            QQC2.ToolButton {
                                icon.name: "go-up"
                                enabled: index > 0
                                onClicked: moveEntry(index, index - 1)
                                display: QQC2.AbstractButton.IconOnly
                                implicitWidth: Kirigami.Units.gridUnit * 1.5
                                implicitHeight: Kirigami.Units.gridUnit * 1.5
                                QQC2.ToolTip { text: i18n("Move up") }
                            }

                            QQC2.ToolButton {
                                icon.name: "go-down"
                                enabled: index < entriesModel.count - 1
                                onClicked: moveEntry(index, index + 1)
                                display: QQC2.AbstractButton.IconOnly
                                implicitWidth: Kirigami.Units.gridUnit * 1.5
                                implicitHeight: Kirigami.Units.gridUnit * 1.5
                                QQC2.ToolTip { text: i18n("Move down") }
                            }
                        }

                        Kirigami.Icon {
                            source: model.entryIcon
                            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            QQC2.TextField {
                                id: nameField
                                Layout.fillWidth: true
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                                text: model.customName !== "" ? model.customName : model.originalName
                                placeholderText: model.originalName

                                onTextEdited: {
                                    if (text === model.originalName || text.trim() === "") {
                                        entriesModel.setProperty(index, "customName", "")
                                    } else {
                                        entriesModel.setProperty(index, "customName", text)
                                    }
                                    saveNames()
                                }
                            }

                            QQC2.Label {
                                text: {
                                    var label = "Boot" + model.bootNum
                                    if (model.customName !== "")
                                        label += " \u00b7 " + model.originalName
                                    return label
                                }
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }

                            QQC2.Label {
                                visible: model.efiPath !== ""
                                text: model.efiPath
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                                elide: Text.ElideMiddle
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                            }
                        }

                        QQC2.ToolButton {
                            icon.name: "edit-clear"
                            visible: model.customName !== ""
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip { text: i18n("Reset to original name") }

                            onClicked: {
                                nameField.text = model.originalName
                                entriesModel.setProperty(index, "customName", "")
                                saveNames()
                            }
                        }

                        QQC2.ToolButton {
                            icon.name: model.hidden ? "view-hidden" : "view-visible"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip { text: model.hidden ? i18n("Show in menu") : i18n("Hide from menu") }

                            onClicked: {
                                entriesModel.setProperty(index, "hidden", !model.hidden)
                                saveHidden()
                            }
                        }
                    }
                }
            }
        }
    }
}
