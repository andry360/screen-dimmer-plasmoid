import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // --- Data ----------------------------------------------------------------------
    // The screen-dimmer service applies the levels and writes the state file;
    // both live in $XDG_RUNTIME_DIR/screen-dimmer (see daemon/main.cpp).
    property bool running: true
    property var outputs: []          // [{name, label, priority}], reassigned only when the list changes
    property var levels: ({})         // name -> 0..100, what the sliders show and what gets written
    property bool loaded: false

    readonly property string dir: '"$XDG_RUNTIME_DIR/screen-dimmer"'
    readonly property int step: 5

    // --- Derived state -------------------------------------------------------------
    readonly property var primary: outputs.length ? outputs.reduce((a, b) => b.priority < a.priority ? b : a) : null
    readonly property int darkest: outputs.reduce((m, o) => Math.min(m, level(o.name)), 100)
    readonly property bool dimmed: running && darkest < 100

    function level(name) { return levels[name] !== undefined ? levels[name] : 100 }

    Plasmoid.icon: "brightness-low"
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 6

    // --- Reading the state (on load, when the popup opens, every 2 s while it is open) ---
    Plasma5Support.DataSource {
        id: reader
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            root.parseState(data["exit code"] === 0 ? String(data["stdout"]) : null)
        }
    }

    function readState() { reader.connectSource("cat " + dir + "/state") }

    function parseState(out) {
        running = out !== null
        if (!running) return
        const list = [], read = {}
        for (const line of out.split("\n")) {
            const p = line.split("\t")
            if (p.length < 5) continue
            list.push({ name: p[0], label: p[1], priority: +p[4] })
            read[p[0]] = +p[2]
        }
        if (JSON.stringify(list) !== JSON.stringify(outputs)) outputs = list
        // While the user is moving a slider, the widget's own values win
        if (!writer.busy) levels = read
        loaded = true
    }

    Timer {
        interval: root.running ? 2000 : 10000
        repeat: true
        running: root.expanded || !root.running
        onTriggered: root.readState()
    }
    onExpandedChanged: if (root.expanded) readState()
    Component.onCompleted: readState()

    // --- Writing the levels (debounced: one write every 150 ms while dragging) -----
    Plasma5Support.DataSource {
        id: shell
        engine: "executable"
        onNewData: (source, data) => disconnectSource(source)
    }

    Timer {
        id: writer
        property bool busy: running || settle.running
        interval: 150
        onTriggered: {
            const lines = Object.keys(root.levels).map(n => "'" + n + " " + root.levels[n] + "'")
            shell.connectSource("d=" + root.dir + "; mkdir -p \"$d\" && printf '%s\\n' " + lines.join(" ") +
                                " > \"$d/levels.tmp\" && mv \"$d/levels.tmp\" \"$d/levels\"")
            settle.restart()
        }
    }
    Timer {   // reads back what the service applied once things are quiet
        id: settle
        interval: 500
        onTriggered: root.readState()
    }

    function setLevel(name, value) {
        const v = Math.max(0, Math.min(100, Math.round(value)))
        if (v === level(name)) return
        const copy = Object.assign({}, levels)
        copy[name] = v
        levels = copy
        writer.restart()
    }

    function resetAll() {
        const copy = {}
        for (const o of outputs) copy[o.name] = 100
        levels = copy
        writer.restart()
    }

    // --- Tooltip ---------------------------------------------------------------------
    toolTipMainText: "Screen Dimmer"
    toolTipSubText: {
        if (!running) return "Service not running"
        const L = outputs.map(o => o.label + ": " + level(o.name) + "%")
        L.push("")
        L.push("Scroll: adjust " + (primary ? primary.label : "the main screen") + " · Middle click: back to 100%")
        return L.join("\n")
    }

    // --- Panel icon ------------------------------------------------------------------
    compactRepresentation: MouseArea {
        id: compact
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        property int wheelDelta: 0

        onClicked: ev => {
            if (ev.button === Qt.MiddleButton) root.resetAll()
            else root.expanded = !root.expanded
        }
        onWheel: ev => {
            if (!root.primary) return
            wheelDelta += ev.angleDelta.y
            const steps = Math.trunc(wheelDelta / 120)
            if (steps === 0) return
            wheelDelta -= steps * 120
            root.setLevel(root.primary.name, root.level(root.primary.name) + steps * root.step)
        }

        Kirigami.Icon {
            anchors.fill: parent
            source: Plasmoid.icon
            active: compact.containsMouse
            opacity: root.running ? 1 : 0.5
        }
        // Badge with the darkest level, only while something is dimmed
        Rectangle {
            visible: root.dimmed
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: badge.implicitWidth + 4
            height: badge.implicitHeight
            radius: 3
            color: Kirigami.Theme.backgroundColor
            opacity: 0.9
            PlasmaComponents.Label {
                id: badge
                anchors.centerIn: parent
                text: root.darkest
                font.pixelSize: Math.max(8, compact.height * 0.38)
                font.bold: true
            }
        }
    }

    // --- Popup -----------------------------------------------------------------------
    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: !root.running
            iconName: "dialog-warning"
            text: "Service not running"
            explanation: "Start it with: systemctl --user start screen-dimmer"
        }

        ColumnLayout {
            id: content
            visible: root.running
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.largeSpacing

            Repeater {
                model: root.outputs
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Icon {
                            source: "video-display"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        PlasmaComponents.Label {
                            text: modelData.label + "  (" + modelData.name + ")"
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        PlasmaComponents.Label {
                            text: root.level(modelData.name) + "%"
                            font.bold: root.level(modelData.name) < 100
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "edit-undo"
                            enabled: root.level(modelData.name) < 100
                            onClicked: root.setLevel(modelData.name, 100)
                            PlasmaComponents.ToolTip.text: "Back to 100%"
                            PlasmaComponents.ToolTip.visible: hovered
                        }
                    }
                    PlasmaComponents.Slider {
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 1
                        value: root.level(modelData.name)
                        onMoved: root.setLevel(modelData.name, value)
                    }
                }
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                text: "Software dimming on top of the hardware brightness, which stays in \"Brightness and Color\". 0% is not black: about 2.5% of the light is left."
            }
        }
    }
}
