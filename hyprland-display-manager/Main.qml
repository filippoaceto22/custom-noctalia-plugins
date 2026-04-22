import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root
    

    property var pluginApi: null

    // =========================
    // STATE
    // =========================
    property var stateData: ({
        layout: { value: "line-left", source: "default" },
        workspaces: { value: 5, source: "default" },
        primary: { mode: "auto", value: "", currentName: "" },
        preferredSerial: "",
        layouts: ["line-left","line-right","line-top","line-bottom","split-lr","split-tb"],
        monitors: []
    })

    property string pendingLayout: "line-left"
    property int pendingWs: 5
    property string selectedPrimary: "auto"

    // =========================
    // PATH SCRIPT
    // =========================
    property string monitorScript: "~/.config/configHyprland/listeners/monitor-autogen-noctalia.sh"
    property string stateScript: "~/.config/hypr/conf/monitors/monitor-ui-state.sh"

    // =========================
    // PROCESSI
    // =========================
    Process {
    id: proc
}

    Process {
        id: stateProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text)
                    root.stateData = parsed
                    root.syncFromState()
                } catch(e) {
                    console.error("JSON parse error", e)
                }
            }
        }
    }

    // =========================
    // LOGICA
    // =========================
    function run(cmd) {
        proc.command = ["bash","-lc", cmd]
        proc.running = true
    }

    function refresh() {
        stateProc.command = ["bash","-lc", stateScript]
        stateProc.running = true
    }

    function syncFromState() {
        pendingLayout = stateData.layout.value
        pendingWs = stateData.workspaces.value

        const p = stateData.primary
        if (p.mode.includes("serial"))
            selectedPrimary = "serial:" + p.value
        else if (p.mode.includes("name"))
            selectedPrimary = "name:" + p.value
        else
            selectedPrimary = "auto"
    }

    function monitorKey(m) {
        if (m.serial && m.serial !== "")
            return "serial:" + m.serial
        return "name:" + m.name
    }

function setPrimary(m) {
    const ws = pendingWs

    if (m.serial && m.serial !== "") {
        selectedPrimary = "serial:" + m.serial

        run(`
            ${monitorScript} set-ws-per-monitor ${ws} &&
            ${monitorScript} clear-primary &&
            ${monitorScript} set-primary-serial ${m.serial}
        `)

    } else {
        selectedPrimary = "name:" + m.name

        run(`
            ${monitorScript} set-ws-per-monitor ${ws} &&
            ${monitorScript} clear-primary-serial &&
            ${monitorScript} set-primary ${m.name}
        `)
    }
}

    // =========================
    // PANEL CONTROL
    // =========================
    function openPanel(screen, sourceItem) {
        pluginApi.openPanel(screen, sourceItem)
    }

    function closePanel() {
        pluginApi.closePanel()
    }

    Component.onCompleted: refresh()

    // =========================
    // IPC
    // =========================
    IpcHandler {
        target: "plugin:hyprland-display-manager"

        function open() {
            root.openPanel()
        }
        

        function refresh() {
            root.refresh()
        }

        function stateUpdated(newState) {
            try {
                const parsed = JSON.parse(newState)
                root.stateData = parsed
                root.syncFromState()
            } catch(e) {
                console.error("JSON parse error", e)
            }
        }


    }
}